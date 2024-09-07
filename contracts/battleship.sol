// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@fhenixprotocol/contracts/FHE.sol";
import "./interfaces/Permissioned.sol";
import "./IBenchmarket.sol";

contract Battleship is Permissioned, IBenchmarket {

    // Game board size
    uint8 private constant BOARD_SIZE = 4;
    uint8 private constant BOARD_CELLS = BOARD_SIZE * BOARD_SIZE;

    // Ship sizes
    uint8 private constant DESTROYER_SIZE = 2;
    uint8 private constant SUBMARINE_SIZE = 3;

    // Total number of ship cells
    uint8 private constant TOTAL_SHIP_CELLS = SUBMARINE_SIZE + DESTROYER_SIZE;

    // Game state
    enum GameState { Waiting, Playing, Finished }

    struct Game {
        GameState state;
        address player1;
        address player2;
        bool player1sTurn;
        mapping(address => euint8[TOTAL_SHIP_CELLS]) shipBoards;
        mapping(address => uint8[BOARD_CELLS]) hitBoards;
        mapping(address => uint8) hitCounters;
        uint256 lastActionTimestamp;
        string model;
        uint modelOdds;
        uint256 totalBet;
        mapping(address => uint256) bets;
        }

    // Mapping of game ID to Game struct
    mapping(uint256 => Game) public games;
    uint256 public gameCounter;

    // Events
    event GameCreated(uint256 gameId, address player1);
    event GameJoined(uint256 gameId, address player2);
    event GameStarted(uint256 gameId, address player1, address player2);
    event GameEnded(uint256 gameId, address winner);
    event ShotFired(uint256 gameId, address player, uint8 position, bool hit);

    // IBenchmarket implementation
    function placeBet(uint256 gameId) external payable override {
        Game storage game = games[gameId];
        require(game.state == GameState.Playing, "Game is not in playing state");
        require(msg.value > 0, "Bet amount must be greater than 0");
        require(tx.origin != game.player2, "Cannot bet against yourself");

        game.bets[msg.sender] += msg.value;
        // TODO: make this make sense betting needs to incur some porpotional output from a vault
        uint payment = 100 / game.modelOdds;
        game.totalBet += msg.value;
        emit BetPlaced(gameId, msg.sender, msg.value);
    }

    function claimWinnings(uint256 gameId) external {
        Game storage game = games[gameId];
        require(game.state == GameState.Finished, "Game is not finished");
        require(game.bets[msg.sender] > 0, "No bet placed by this address");

        address winner = game.hitCounters[game.player1] == TOTAL_SHIP_CELLS ? game.player2 : game.player1;
        require(msg.sender == winner, "Only the winner can claim winnings");

        uint256 winnings = (game.bets[msg.sender] * game.modelOdds) / 100;
        game.bets[msg.sender] = 0;
        payable(msg.sender).transfer(winnings);

        emit WinningsClaimed(gameId, msg.sender, winnings);
    }

    function getOdds(uint256 gameId) external view returns (uint256) {
        return games[gameId].modelOdds;
    }

    function updateOdds(uint256 gameId, uint256 newOdds) external {
        Game storage game = games[gameId];
        require(msg.sender == game.player2, "Only player 2 can update odds");
        require(game.state == GameState.Playing, "Game is not in playing state");

        game.modelOdds = newOdds;
        emit OddsUpdated(gameId, newOdds);
    }

    function getTotalBet(uint256 gameId) external view returns (uint256) {
        return games[gameId].totalBet;
    }
    // Timeout duration (in seconds)
    uint256 public constant TIMEOUT_DURATION = 5 minutes;

    function createGame(string memory model) external returns (uint256) {
        uint256 gameId = gameCounter++;
        Game storage game = games[gameId];
        game.state = GameState.Waiting;
        game.player1 = msg.sender;
        game.player1sTurn = true;
        game.lastActionTimestamp = block.timestamp;
        game.model = model;
        game.modelOdds = 100;
        emit GameCreated(gameId, msg.sender);
        return gameId;
    }

    function joinGame(uint256 gameId) external {
        Game storage game = games[gameId];
        require(game.player1 != address(0), "Game does not exist");
        require(game.state == GameState.Waiting, "Game is not in waiting state");
        require(game.player2 == address(0), "Game is already full");
        require(msg.sender != game.player1, "Cannot join your own game");

        game.player2 = msg.sender;
        game.state = GameState.Playing;
        game.lastActionTimestamp = block.timestamp;
        emit GameJoined(gameId, msg.sender);
        emit GameStarted(gameId, game.player1, game.player2);
    }

    function placeShips(uint256 gameId, inEuint8[TOTAL_SHIP_CELLS] calldata encryptedBoard) external payable{
        Game storage game = games[gameId];
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player in this game");
        require(game.state == GameState.Playing, "Game is not in playing state");
        require(encryptedBoard.length == TOTAL_SHIP_CELLS, "Invalid board size");
        // TODO: roll through the total ship cells and calculate if all the cells are valid, require all of them to be below TOTAL_SHIP CELLS in ID. waiting to do this because it's gas intensive in an already gas intensive function

        for (uint8 i = 0; i < TOTAL_SHIP_CELLS; i++) {
            game.shipBoards[msg.sender][i] = FHE.asEuint8(encryptedBoard[i]);
        }
        game.lastActionTimestamp = block.timestamp;
    }

    function fireShot(uint256 gameId, uint8 position) external {
        Game storage game = games[gameId];
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player in this game");
        require(game.state == GameState.Playing, "Game is not in playing state");
        require(position < BOARD_CELLS, "Invalid position");
        if(game.player1sTurn){
            require(msg.sender == game.player1, "Not your turn");
        } else{
            require(msg.sender == game.player2, "Not your turn");
        }
        address target = getOpponent(gameId, msg.sender);
        require(game.hitBoards[target][position] == 0, "Already played");

        bool isHit;
        for (uint8 i = 0; i < TOTAL_SHIP_CELLS && !isHit; i++) {
            isHit = FHE.decrypt(FHE.eq(game.shipBoards[target][i], FHE.asEuint8(position)));
        }

        // Update hit board and counter
        if(isHit){
            game.hitBoards[target][position] = 2;
            game.hitCounters[target] ++;
        }
        else {
            game.hitBoards[target][position] = 1;
        }
        game.player1sTurn = !game.player1sTurn;
        emit ShotFired(gameId, msg.sender, position, isHit);

        // Check if the game has ended
        if (game.hitCounters[target] == TOTAL_SHIP_CELLS) {
            game.state = GameState.Finished;
            if(msg.sender == game.player2){
                modelWins[game.model] ++;
            } else {
                modelLosses[game.model] ++;
            }
            emit GameEnded(gameId, msg.sender);
        }

        game.lastActionTimestamp = block.timestamp;
    }

    function getShips(uint256 gameId, Permission calldata perm) external view onlySender(perm) returns (uint8[] memory) {
        Game storage game = games[gameId];
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player in this game");

        uint8[] memory ships = new uint8[](TOTAL_SHIP_CELLS);
        for (uint8 i = 0; i < TOTAL_SHIP_CELLS; i++) {
            ships[i] = FHE.decrypt(game.shipBoards[msg.sender][i]);
        }
        return ships;
    }

    function getHitBoard(uint256 gameId, address player) external view returns (uint8[] memory) {
        Game storage game = games[gameId];
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player in this game");

        uint8[] memory board = new uint8[](BOARD_CELLS);
        for (uint8 i = 0; i < BOARD_CELLS; i++) {
            board[i] = game.hitBoards[player][i];
        }
        return board;
    }

    function getHitCounter(uint256 gameId, address player) external view returns (uint8) {
        Game storage game = games[gameId];
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player in this game");
        return game.hitCounters[player];
    }

    function getOpponent(uint256 gameId, address player) internal view returns (address) {
        Game storage game = games[gameId];
        return player == game.player1 ? game.player2 : game.player1;
    }

    function checkTimeout(uint256 gameId) external {
        Game storage game = games[gameId];
        require(game.state == GameState.Playing, "Game is not in playing state");
        require(block.timestamp > game.lastActionTimestamp + TIMEOUT_DURATION, "Timeout period has not elapsed");

        game.state = GameState.Finished;
        emit GameEnded(gameId, getOpponent(gameId, msg.sender));
    }
    // Mapping of model to win rate
    mapping(string => uint256) public modelWins;
    mapping(string => uint256) public modelLosses;
    function getModelWins(string memory model) external view returns (uint256) {
        return modelWins[model];
    }
    function getModelLosses(string memory model) external view returns (uint256) {
        return modelLosses[model];
    }


    function getModelWinRate(string memory model) external view returns (uint256){
        // Add access control here if needed
        return(modelWins[model] / modelLosses[model]);
    }
}
