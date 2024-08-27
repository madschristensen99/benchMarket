// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@fhenixprotocol/contracts/FHE.sol";
import "./interfaces/Permissioned.sol";

contract Battleship is Permissioned {
    // Game board size
    uint8 private constant BOARD_SIZE = 10;
    uint8 private constant BOARD_CELLS = BOARD_SIZE * BOARD_SIZE;

    // Ship sizes
    uint8 private constant CARRIER_SIZE = 5;
    uint8 private constant BATTLESHIP_SIZE = 4;
    uint8 private constant CRUISER_SIZE = 3;
    uint8 private constant SUBMARINE_SIZE = 3;
    uint8 private constant DESTROYER_SIZE = 2;

    // Total number of ship cells
    uint8 private constant TOTAL_SHIP_CELLS = CARRIER_SIZE + BATTLESHIP_SIZE + CRUISER_SIZE + SUBMARINE_SIZE + DESTROYER_SIZE;

    // Game state
    enum GameState { Waiting, Playing, Finished }

    struct Game {
        GameState state;
        address player1;
        address player2;
        mapping(address => euint8[BOARD_CELLS]) shipBoards;
        mapping(address => euint8[BOARD_CELLS]) hitBoards;
        mapping(address => euint8) hitCounters;
        uint256 lastActionTimestamp;
    }

    // Mapping of game ID to Game struct
    mapping(uint256 => Game) public games;
    uint256 public gameCounter;

    // Events
    event GameCreated(uint256 gameId, address player1);
    event GameJoined(uint256 gameId, address player2);
    event GameStarted(uint256 gameId, address player1, address player2);
    event ShotFired(uint256 gameId, address player, uint8 position);
    event GameEnded(uint256 gameId, address winner);

    // Timeout duration (in seconds)
    uint256 public constant TIMEOUT_DURATION = 5 minutes;

    function createGame() external returns (uint256) {
        uint256 gameId = gameCounter++;
        Game storage game = games[gameId];
        game.state = GameState.Waiting;
        game.player1 = msg.sender;
        game.lastActionTimestamp = block.timestamp;
        emit GameCreated(gameId, msg.sender);
        return gameId;
    }

    function joinGame(uint256 gameId) external {
        Game storage game = games[gameId];
        require(game.state == GameState.Waiting, "Game is not in waiting state");
        require(game.player2 == address(0), "Game is already full");
        require(msg.sender != game.player1, "Cannot join your own game");

        game.player2 = msg.sender;
        game.state = GameState.Playing;
        game.lastActionTimestamp = block.timestamp;
        emit GameJoined(gameId, msg.sender);
        emit GameStarted(gameId, game.player1, game.player2);
    }

    function placeShips(uint256 gameId, inEuint8[] calldata encryptedBoard) external {
        Game storage game = games[gameId];
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player in this game");
        require(game.state == GameState.Playing, "Game is not in playing state");
        require(encryptedBoard.length == BOARD_CELLS, "Invalid board size");

        for (uint8 i = 0; i < BOARD_CELLS; i++) {
            game.shipBoards[msg.sender][i] = FHE.asEuint8(encryptedBoard[i]);
        }
        game.lastActionTimestamp = block.timestamp;
    }

    function fireShot(uint256 gameId, uint8 position) external {
        Game storage game = games[gameId];
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player in this game");
        require(game.state == GameState.Playing, "Game is not in playing state");
        require(position < BOARD_CELLS, "Invalid position");

        address target = getOpponent(gameId, msg.sender);
        emit ShotFired(gameId, msg.sender, position);

        euint8 cellValue = game.shipBoards[target][position];
        ebool isHit = cellValue.eq(FHE.asEuint8(1));

        // Update hit board and counter
        game.hitBoards[target][position] = FHE.asEuint8(isHit);
        game.hitCounters[target] = game.hitCounters[target] + FHE.asEuint8(isHit);

        // Check if the game has ended
        ebool gameEnded = game.hitCounters[target].eq(FHE.asEuint8(TOTAL_SHIP_CELLS));

        if (FHE.decrypt(gameEnded)) {
            game.state = GameState.Finished;
            emit GameEnded(gameId, msg.sender);
        }

        game.lastActionTimestamp = block.timestamp;
    }

    function getShipBoard(uint256 gameId, Permission calldata perm, address player) external view onlySender(perm) returns (uint8[] memory) {
        Game storage game = games[gameId];
        require(player == game.player1 || player == game.player2, "Not a player in this game");

        uint8[] memory board = new uint8[](BOARD_CELLS);
        for (uint8 i = 0; i < BOARD_CELLS; i++) {
            board[i] = FHE.decrypt(game.shipBoards[player][i]);
        }
        return board;
    }

    function getHitBoard(uint256 gameId, address player) external view returns (euint8[] memory) {
        Game storage game = games[gameId];
        require(msg.sender == player || msg.sender == getOpponent(gameId, player), "Not authorized");

        euint8[] memory board = new euint8[](BOARD_CELLS);
        for (uint8 i = 0; i < BOARD_CELLS; i++) {
            board[i] = game.hitBoards[player][i];
        }
        return board;
    }

    function getHitCounter(uint256 gameId, address player) external view returns (euint8) {
        Game storage game = games[gameId];
        require(msg.sender == player || msg.sender == getOpponent(gameId, player), "Not authorized");
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
}
