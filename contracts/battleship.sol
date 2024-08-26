// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@fhenixprotocol/contracts/FHE.sol";

contract Battleship {
    // Game board size
    uint8 private constant BOARD_SIZE = 10;
    uint8 private constant BOARD_CELLS = BOARD_SIZE * BOARD_SIZE;

    // Total number of ship cells
    uint8 private constant TOTAL_SHIP_CELLS = 17; // 5 + 4 + 3 + 3 + 2

    // Game state
    enum GameState { Waiting, Playing, Finished }
    GameState public gameState;

    // Player addresses
    address public player1;
    address public player2;

    // Encrypted game boards (1 for ship placement, 1 for hits)
    mapping(address => euint8[BOARD_CELLS]) private shipBoards;
    mapping(address => euint8[BOARD_CELLS]) private hitBoards;

    // Encrypted hit counters
    mapping(address => euint8) private hitCounters;

    // Events
    event GameStarted(address player1, address player2);
    event ShotFired(address player, uint8 position);
    event GameEnded(address winner);

    constructor() {
        gameState = GameState.Waiting;
    }

    function joinGame() external {
        require(gameState == GameState.Waiting, "Game is not in waiting state");
        
        if (player1 == address(0)) {
            player1 = msg.sender;
        } else if (player2 == address(0)) {
            player2 = msg.sender;
            gameState = GameState.Playing;
            emit GameStarted(player1, player2);
        } else {
            revert("Game is full");
        }
    }

    function placeShips(inEuint8[] calldata encryptedBoard) external {
        require(msg.sender == player1 || msg.sender == player2, "Not a player");
        require(gameState == GameState.Playing, "Game is not in playing state");
        require(encryptedBoard.length == BOARD_CELLS, "Invalid board size");

        for (uint8 i = 0; i < BOARD_CELLS; i++) {
            shipBoards[msg.sender][i] = FHE.asEuint8(encryptedBoard[i]);
        }
    }

    function fireShot(address target, uint8 position) external {
        require(msg.sender == player1 || msg.sender == player2, "Not a player");
        require(msg.sender != target, "Cannot shoot at your own board");
        require(gameState == GameState.Playing, "Game is not in playing state");
        require(position < BOARD_CELLS, "Invalid position");

        emit ShotFired(msg.sender, position);

        euint8 cellValue = shipBoards[target][position];
        ebool isHit = cellValue.eq(FHE.asEuint8(1));
        
        // Update hit board and counter
        hitBoards[target][position] = FHE.asEuint8(isHit);
        hitCounters[target] = hitCounters[target] + FHE.asEuint8(isHit);

        // Check if the game has ended
        ebool gameEnded = hitCounters[target].eq(FHE.asEuint8(TOTAL_SHIP_CELLS));
        
        if (FHE.decrypt(gameEnded)) {
            gameState = GameState.Finished;
            emit GameEnded(msg.sender);
        }
    }

    function getShipBoard(address player) external view returns (euint8[] memory) {
        require(msg.sender == player, "Can only view your own board");
        euint8[] memory board = new euint8[](BOARD_CELLS);
        for (uint8 i = 0; i < BOARD_CELLS; i++) {
            board[i] = shipBoards[player][i];
        }
        return board;
    }

    function getHitBoard(address player) external view returns (euint8[] memory) {
        require(msg.sender == player || msg.sender == getOpponent(player), "Not authorized");
        euint8[] memory board = new euint8[](BOARD_CELLS);
        for (uint8 i = 0; i < BOARD_CELLS; i++) {
            board[i] = hitBoards[player][i];
        }
        return board;
    }

    function getHitCounter(address player) external view returns (euint8) {
        require(msg.sender == player || msg.sender == getOpponent(player), "Not authorized");
        return hitCounters[player];
    }

    function getOpponent(address player) internal view returns (address) {
        return player == player1 ? player2 : player1;
    }
}
