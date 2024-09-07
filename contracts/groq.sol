// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "../IOracle.sol";

// @title GroqChatGptMultichat
// @notice multichat mode!
contract GroqChatGptMultichat {

    struct ChatRun {
        address owner;
        IOracle.Message[] messages;
        uint messagesCount;
        string model;
    }

    // @notice Mapping from chat ID to ChatRun
    mapping(uint => ChatRun) public chatRuns;
    uint public chatRunsCount;

    // @notice Event emitted when a new chat is created
    event ChatCreated(address indexed owner, uint indexed chatId, string model);

    // @notice Address of the contract owner
    address private owner;

    // @notice Address of the oracle contract
    address public oracleAddress;

    // @notice Event emitted when the oracle address is updated
    event OracleAddressUpdated(address indexed newOracleAddress);

    // @notice Array of valid model names
    string[] private validModels;

    constructor(address initialOracleAddress) {
        owner = msg.sender;
        oracleAddress = initialOracleAddress;
        chatRunsCount = 0;

        // Initialize valid models
        validModels = [
            "llama-3.1-70b-versatile",
            "llama-3.1-8b-instant",
            "llama3-8b-8192",
            "llama3-70b-8192",
            "mixtral-8x7b-32768",
            "gemma-7b-it"
        ];
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not owner");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracleAddress, "Caller is not oracle");
        _;
    }

    function setOracleAddress(address newOracleAddress) public onlyOwner {
        oracleAddress = newOracleAddress;
        emit OracleAddressUpdated(newOracleAddress);
    }

    // @notice Starts a new chat
    // @param message The initial message to start the chat with
    // @param model The name of the model to use for this chat
    // @return The ID of the newly created chat
    function startChat(string memory message, string memory model) public returns (uint) {
        require(isValidModel(model), "Invalid model name");

        ChatRun storage run = chatRuns[chatRunsCount];

        run.owner = msg.sender;
        run.model = model;
        IOracle.Message memory newMessage = createTextMessage("user", message);
        run.messages.push(newMessage);
        run.messagesCount = 1;

        uint currentId = chatRunsCount;
        chatRunsCount = chatRunsCount + 1;

        IOracle.GroqRequest memory config = createGroqConfig(model);
        IOracle(oracleAddress).createGroqLlmCall(currentId, config);
        emit ChatCreated(msg.sender, currentId, model);

        return currentId;
    }
    event LlmResponseReceived(uint256 indexed runId, string content, string modelName);
    function onOracleGroqLlmResponse(
        uint runId,
        IOracle.GroqResponse memory response,
        string memory errorMessage
    ) public onlyOracle {
        ChatRun storage run = chatRuns[runId];
        require(
            keccak256(abi.encodePacked(run.messages[run.messagesCount - 1].role)) == keccak256(abi.encodePacked("user")),
            "No message to respond to"
        );
        if (!compareStrings(errorMessage, "")) {
            IOracle.Message memory newMessage = createTextMessage("assistant", errorMessage);
            run.messages.push(newMessage);
            run.messagesCount++;
        } else {
            IOracle.Message memory newMessage = createTextMessage("assistant", response.content);
            run.messages.push(newMessage);
            run.messagesCount++;
        }
        emit LlmResponseReceived(runId, response.content, run.model);
    }

    function addMessage(string memory message, uint runId) public {
        ChatRun storage run = chatRuns[runId];
        require(
            keccak256(abi.encodePacked(run.messages[run.messagesCount - 1].role)) == keccak256(abi.encodePacked("assistant")),
            "No response to previous message"
        );
        require(
            run.owner == msg.sender, "Only chat owner can add messages"
        );

        IOracle.Message memory newMessage = createTextMessage("user", message);
        run.messages.push(newMessage);
        run.messagesCount++;

        IOracle.GroqRequest memory config = createGroqConfig(run.model);
        IOracle(oracleAddress).createGroqLlmCall(runId, config);
    }

    function getMessageHistory(uint chatId) public view returns (IOracle.Message[] memory) {
        return chatRuns[chatId].messages;
    }

    function createTextMessage(string memory role, string memory content) private pure returns (IOracle.Message memory) {
        IOracle.Message memory newMessage = IOracle.Message({
            role: role,
            content: new IOracle.Content[](1)
        });
        newMessage.content[0].contentType = "text";
        newMessage.content[0].value = content;
        return newMessage;
    }

    function compareStrings(string memory a, string memory b) private pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    // @notice Checks if the given model name is valid
    // @param model The model name to check
    // @return True if the model is valid, false otherwise
    function isValidModel(string memory model) private view returns (bool) {
        for (uint i = 0; i < validModels.length; i++) {
            if (compareStrings(model, validModels[i])) {
                return true;
            }
        }
        return false;
    }

    // @notice Creates a GroqRequest configuration based on the model
    // @param model The name of the model to configure
    // @return The GroqRequest configuration
    function createGroqConfig(string memory model) private pure returns (IOracle.GroqRequest memory) {
        return IOracle.GroqRequest({
            model: model,
            frequencyPenalty: 21, // > 20 for null
            logitBias: "", // empty str for null
            maxTokens: 1000, // 0 for null
            presencePenalty: 21, // > 20 for null
            responseFormat: "{\"type\":\"text\"}",
            seed: 0, // null
            stop: "", // null
            temperature: 10, // Example temperature (scaled up, 10 means 1.0), > 20 means null
            topP: 101, // Percentage 0-100, > 100 means null
            user: "" // null
        });
    }


}