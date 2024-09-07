// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IBenchmarket {
    // Place a bet on a game
    function placeBet(uint256 gameId) external payable;

    // Claim winnings from a bet
    function claimWinnings(uint256 gameId) external;

    // Get the current odds for a game
    function getOdds(uint256 gameId) external view returns (uint256);

    // Update the odds for a game
    function updateOdds(uint256 gameId, uint256 newOdds) external;

    // Get the total amount bet on a game
    function getTotalBet(uint256 gameId) external view returns (uint256);

    // Get the win rate for a specific model
    function getModelWins(string memory model) external view returns (uint256);
    function getModelLosses(string memory model) external view returns (uint256);

    // Update the win rate for a specific model
    function getModelWinRate(string memory model) external view returns(uint256);

    // Event emitted when a bet is placed
    event BetPlaced(uint256 indexed gameId, address indexed bettor, uint256 amount);

    // Event emitted when winnings are claimed
    event WinningsClaimed(uint256 indexed gameId, address indexed winner, uint256 amount);

    // Event emitted when odds are updated
    event OddsUpdated(uint256 indexed gameId, uint256 newOdds);

    // Event emitted when a model's win rate is updated
    event ModelWinRateUpdated(string model, uint256 newWinRate);
}
