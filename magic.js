const ethers = require('ethers');
const { FhenixClient, EncryptionTypes } = require('fhenixjs');
require('dotenv').config();

const {
  BATTLESHIP_ADDRESS,
  FHENIX_RPC_URL,
  BATTLESHIP_CHAIN_ID,
  BATTLESHIP_ABI,
  GALADRIEL_ADDRESS,
  GALADRIEL_RPC_URL,
  GALADRIEL_CHAIN_ID,
  GALADRIEL_ABI
} = require('./constants');

const BOARD_SIZE = 4;
const BOARD_CELLS = BOARD_SIZE * BOARD_SIZE;
const TOTAL_SHIP_CELLS = 5; // 2 for destroyer, 3 for submarine

let fhenixClient = null;

async function main() {
    console.log("Initializing...");
    
    // Set up providers and signers
    const fhenixProvider = new ethers.providers.JsonRpcProvider(FHENIX_RPC_URL);
    const galadrielProvider = new ethers.providers.JsonRpcProvider(GALADRIEL_RPC_URL);
    
    console.log("Providers set up. Checking network connection...");
    
    try {
        const fhenixNetwork = await fhenixProvider.getNetwork();
        console.log("Connected to Fhenix network:", fhenixNetwork.name, "Chain ID:", fhenixNetwork.chainId);
        
        const galadrielNetwork = await galadrielProvider.getNetwork();
        console.log("Connected to Galadriel network:", galadrielNetwork.name, "Chain ID:", galadrielNetwork.chainId);
    } catch (error) {
        console.error("Error connecting to networks:", error.message);
    }
    
    const mnemonic = process.env.MNEMONIC;
    const fhenixWallet = ethers.Wallet.fromMnemonic(mnemonic).connect(fhenixProvider);
    const galadrielWallet = ethers.Wallet.fromMnemonic(mnemonic).connect(galadrielProvider);

    console.log(`Using address: ${fhenixWallet.address}`);

    // Set up contracts
    const battleshipContract = new ethers.Contract(BATTLESHIP_ADDRESS, BATTLESHIP_ABI, fhenixWallet);
    const galadrielContract = new ethers.Contract(GALADRIEL_ADDRESS, GALADRIEL_ABI, galadrielWallet);

    // Set up FhenixClient with error handling
    try {
        fhenixClient = new FhenixClient({ provider: fhenixProvider });
        console.log("FhenixClient initialized successfully");
        
        // Test FhenixClient
        await testFhenixClient();
    } catch (error) {
        console.error("Error with FhenixClient:", error.message);
        console.log("Continuing without FhenixClient. Some functionality may be limited.");
    }

    // Set up event listeners
    setupEventListeners(battleshipContract, galadrielContract);

    console.log("Listening for new games...");

    // Listen for GameCreated events
    battleshipContract.on("GameCreated", async (gameId, player1) => {
        console.log(`New game created: ${gameId} by ${player1}`);
        
        try {
            // Join the game
            await joinGame(battleshipContract, gameId);
            await placeShips(battleshipContract, gameId);
            
            // Start playing
            await playGame(battleshipContract, galadrielContract, gameId);
        } catch (error) {
            console.error(`Error handling game ${gameId}:`, error.message);
        }
    });
}

async function testFhenixClient() {
    try {
        const testValue = 42;
        const encrypted = await fhenixClient.encrypt(testValue, 'uint8');
        console.log("FhenixClient encryption test successful");
    } catch (error) {
        throw new Error(`FhenixClient test failed: ${error.message}`);
    }
}

async function joinGame(contract, gameId) {
    try {
        const tx = await contract.joinGame(gameId);
        await tx.wait();
        console.log(`Joined game ${gameId}`);
    } catch (error) {
        console.error(`Error joining game: ${error.message}`);
        throw error;
    }
}

async function placeShips(contract, gameId) {
    try {
        const shipPositions = generateShipPositions();
        let encryptedPositions;
        
        if (fhenixClient) {
            encryptedPositions = await Promise.all(
                shipPositions.map(pos => fhenixClient.encrypt(pos, 'uint8'))
            );
        } else {
            console.log("Warning: Using unencrypted ship positions");
            encryptedPositions = shipPositions;
        }
        
        // Estimate the gas limit
        const estimatedGas = await contract.estimateGas.placeShips(gameId, encryptedPositions);
        
        // Increase the estimated gas by 50%
        const gasLimit = estimatedGas.mul(150).div(100);

        // Get the current gas price
        const gasPrice = await contract.provider.getGasPrice();

        // Increase the gas price by 20%
        const adjustedGasPrice = gasPrice.mul(120).div(100);

        console.log(`Estimated Gas: ${estimatedGas.toString()}`);
        console.log(`Gas Limit: ${gasLimit.toString()}`);
        console.log(`Gas Price: ${adjustedGasPrice.toString()}`);

        const tx = await contract.placeShips(gameId, encryptedPositions, {
            gasLimit: gasLimit,
            gasPrice: adjustedGasPrice
        });
        
        console.log(`Transaction hash: ${tx.hash}`);
        
        await tx.wait();
        console.log(`Ships placed for game ${gameId}`);
    } catch (error) {
        console.error(`Error placing ships: ${error.message}`);
        if (error.transaction) {
            console.error(`Transaction data: ${JSON.stringify(error.transaction)}`);
        }
        throw error;
    }
}

async function playGame(battleshipContract, galadrielContract, gameId) {
    try {
        let gameEnded = false;
        let shotsFired = new Set();
        let gameState = { hitBoard: [], missBoard: [] };

        while (!gameEnded) {
            // Check if it's our turn
            const game = await battleshipContract.games(gameId);
            if (game.player1sTurn === (game.player1 === await battleshipContract.signer.getAddress())) {
                // Update game state
                await updateGameState(battleshipContract, gameId, gameState);

                // Get shot suggestion from Galadriel
                const shotPosition = await getShotSuggestion(galadrielContract, battleshipContract, gameId, gameState, game.model);
                
                if (!shotsFired.has(shotPosition)) {
                    shotsFired.add(shotPosition);
                    
                    const tx = await battleshipContract.fireShot(gameId, shotPosition);
                    const receipt = await tx.wait();
                    
                    // Process events from the receipt
                    for (const event of receipt.events) {
                        if (event.event === 'ShotFired') {
                            const [, , position, hit] = event.args;
                            console.log(`Shot fired at position ${position}. Hit: ${hit}`);
                            if (hit) {
                                gameState.hitBoard.push(position);
                            } else {
                                gameState.missBoard.push(position);
                            }
                        } else if (event.event === 'GameEnded') {
                            gameEnded = true;
                            console.log(`Game ${gameId} ended. Winner: ${event.args.winner}`);
                        }
                    }
                }
            }
            
            // Wait before checking again
            await new Promise(resolve => setTimeout(resolve, 5000));
        }
    } catch (error) {
        console.error(`Error playing game: ${error.message}`);
        throw error;
    }
}

async function updateGameState(battleshipContract, gameId, gameState) {
    const hitBoard = await battleshipContract.getHitBoard(gameId, await                     battleshipContract.signer.getAddress());
    gameState.hitBoard = hitBoard.filter(cell => cell === 2).map((_, index) => index);
    gameState.missBoard = hitBoard.filter(cell => cell === 1).map((_, index) => index);
}

async function getShotSuggestion(galadrielContract, battleshipContract, gameId, gameState, model) {
    try {
        // Get the current game state to determine the opponent
        const game = await battleshipContract.games(gameId);
        const signerAddress = await battleshipContract.signer.getAddress();
        const opponentAddress = game.player1 === signerAddress ? game.player2 : game.player1;

        // Get the opponent's hit board
        const hitBoard = await battleshipContract.getHitBoard(gameId, opponentAddress);
        const otherHitBoard = await battleshipContract.getHitBoard(gameId, signerAddress);

        // Convert the hit board to a string representation
        const boardString = hitBoard.map(cell => cell === 0 ? '.' : cell === 1 ? 'O' : 'X').join('');
        const otherBoardString = otherHitBoard.map(cell => cell === 0 ? '.' : cell === 1 ? 'O' : 'X').join('');

        // Prepare the prompt for Galadriel
        const prompt = `You're playing battleship on a 4x4 grid. Here's the current board state of your shots against the opponent:
${boardString.slice(0, 4)}
${boardString.slice(4, 8)}
${boardString.slice(8, 12)}
${boardString.slice(12, 16)}
And here are the hit/misses made against you:
${otherBoardString.slice(0, 4)}
${otherBoardString.slice(4, 8)}
${otherBoardString.slice(8, 12)}
${otherBoardString.slice(12, 16)}
'.' represents an unknown cell, 'O' represents a miss, and 'X' represents a hit.
Please suggest the best position to fire next as a number from 0-15, where 0 is the top-left corner,
and we go across then down. Please format your answer as |PLACE|x| where x is the number you choose. Also give your betting odds you're willing to give to your opponent that they won't beat you, such as 150 if you're winning however if you're perhaps losing instead format it as less than 100 something like 80 or 50 because we need to only use uints. 500 if you're winning by a lot, 5 if you're close to losing. If the game is almost over make the odds 0. Formatted |ODDS|x|.`;

        console.log("Sending prompt to Galadriel:", prompt);

        // Start a chat with Galadriel and get the suggestion
        const chatId = await galadrielContract.chatRunsCount();
        // Set up the event listener before calling startChat
        const chat = await galadrielContract.startChat(prompt, model);
        const suggestion = await waitForGaladrielResponse(galadrielContract, parseInt(chatId));
        console.log("Waiting for Galadriel's response...");
        console.log(chatId);

        console.log(`Raw Galadriel response: ${suggestion}`);
        // Add this after your existing code to extract the shot position
const oddsMatch = suggestion.match(/\|ODDS\|(\d+)\|/);
if (oddsMatch) {
    const odds = parseInt(oddsMatch[1]);
    if (!isNaN(odds) && odds >= 0) {
        console.log(`Galadriel suggested odds: ${odds}`);
        let success = false;
        let retries = 0;
        const maxRetries = 3;

        while (!success && retries < maxRetries) {
            try {
                const nonce = await battleshipContract.signer.getTransactionCount();
                const tx = await battleshipContract.updateOdds(gameId, odds, { nonce });
                await tx.wait();
                success = true;
                console.log(`Odds updated successfully to ${odds}`);
            } catch (error) {
                console.error(`Error updating odds (attempt ${retries + 1}):`, error.message);
                retries++;
                if (retries < maxRetries) {
                    await new Promise(resolve => setTimeout(resolve, 1000 * retries)); // Simple backoff
                }
            }
        }

        if (!success) {
            console.error(`Failed to update odds after ${maxRetries} attempts`);
        }
    }
}
        console.log("Could not find |PLACE|x| format in Galadriel's response. Attempting to extract any number.");
        const numberMatch = suggestion.match(/\d+/);
        if (numberMatch) {
            const shot = parseInt(numberMatch[0]);
            if (!isNaN(shot) && shot >= 0 && shot <= 15) {
                console.log(`Extracted shot from Galadriel's response: ${shot}`);
                return shot;
            }
        }

        throw new Error("Could not extract a valid shot number from Galadriel's response");
        
 
    } catch (error) {
        console.error(`Error getting shot suggestion from Galadriel: ${error.message}`);
        // Fallback to random shot if Galadriel fails
        const randomShot = Math.floor(Math.random() * BOARD_CELLS);
        console.log(`Falling back to random shot: ${randomShot}`);
        return randomShot;
    }
}

function waitForGaladrielResponse(galadrielContract, chatId) {
    return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
            galadrielContract.removeAllListeners("LlmResponseReceived");
            reject(new Error("Timeout waiting for Galadriel's response"));
        }, 60000); // 60 second timeout

        function responseHandler(runId, content, functionName) {
            if (runId.toString() === chatId.toString()) {
                clearTimeout(timeout);
                galadrielContract.removeAllListeners("LlmResponseReceived");
                resolve(content);
            }
        }

        galadrielContract.on("LlmResponseReceived", responseHandler);
    });
}

function generateShipPositions() {
    const positions = [];
    const board = new Array(BOARD_CELLS).fill(false);

    // Place destroyer (size 2)
    placeShip(2, board, positions);

    // Place submarine (size 3)
    placeShip(3, board, positions);

    return positions;
}

function placeShip(size, board, positions) {
    let placed = false;
    while (!placed) {
        const isHorizontal = Math.random() < 0.5;
        const startPos = Math.floor(Math.random() * BOARD_CELLS);
        
        if (canPlaceShip(startPos, size, isHorizontal, board)) {
            for (let i = 0; i < size; i++) {
                const pos = isHorizontal ? startPos + i : startPos + i * BOARD_SIZE;
                board[pos] = true;
                positions.push(pos);
            }
            placed = true;
        }
    }
}

function canPlaceShip(startPos, size, isHorizontal, board) {
    for (let i = 0; i < size; i++) {
        const pos = isHorizontal ? startPos + i : startPos + i * BOARD_SIZE;
        if (pos >= BOARD_CELLS || board[pos]) return false;
        if (isHorizontal && Math.floor(pos / BOARD_SIZE) !== Math.floor(startPos / BOARD_SIZE)) return false;
    }
    return true;
}

function setupEventListeners(battleshipContract, galadrielContract) {
    battleshipContract.on("GameJoined", (gameId, player2) => {
        console.log(`Game ${gameId} joined by ${player2}`);
    });

    battleshipContract.on("GameStarted", (gameId, player1, player2) => {
        console.log(`Game ${gameId} started. Players: ${player1} vs ${player2}`);
    });

    battleshipContract.on("ShotFired", (gameId, player, position, hit) => {
        console.log(`Game ${gameId}: ${player} fired at position ${position}. Hit: ${hit}`);
    });

    battleshipContract.on("GameEnded", (gameId, winner) => {
        console.log(`Game ${gameId} ended. Winner: ${winner}`);
    });

    galadrielContract.on("LlmResponseReceived", (runId, content, functionName) => {
        console.log(`Received LLM response for chat ${runId}: ${content}`);
        // Additional handling can be added here if needed
    });
}

main().catch(error => {
    console.error("Fatal error:", error);
    process.exit(1);
});
