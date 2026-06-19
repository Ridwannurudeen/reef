// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

interface IReefGuardAction {
    struct Action {
        address target;
        uint256 value;
        bytes data;
        address asset;
        uint256 portfolioValue;
    }

    function canExecuteAction(uint256 agentId, Action calldata action)
        external
        view
        returns (bool allowed, string memory reason, uint256 amount, uint256 sizeBps);
}

interface ITransactionGuard {
    enum Operation {
        Call,
        DelegateCall
    }

    function checkTransaction(
        address to,
        uint256 value,
        bytes memory data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures,
        address msgSender
    ) external;

    function checkAfterExecution(bytes32 txHash, bool success) external;
}

/// @title ReefSafeGuard
/// @notice Safe transaction guard that routes every configured Safe transaction through ReefGuard.
contract ReefSafeGuard is ITransactionGuard {
    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;

    IReefGuardAction public immutable reefGuard;
    address public governor;
    mapping(address => uint256) public safeAgent;

    event SafeAgentSet(address indexed safe, uint256 indexed agentId);
    event SafeAgentCleared(address indexed safe);
    event GovernorTransferred(address indexed governor);

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor(address reefGuard_, address governor_) {
        require(reefGuard_ != address(0) && governor_ != address(0), "zero addr");
        reefGuard = IReefGuardAction(reefGuard_);
        governor = governor_;
    }

    function setSafeAgent(address safe, uint256 agentId) external onlyGovernor {
        require(safe != address(0), "zero safe");
        require(agentId != 0, "zero agent");
        safeAgent[safe] = agentId;
        emit SafeAgentSet(safe, agentId);
    }

    function clearSafeAgent(address safe) external onlyGovernor {
        require(safeAgent[safe] != 0, "unknown safe");
        delete safeAgent[safe];
        emit SafeAgentCleared(safe);
    }

    function transferGovernor(address governor_) external onlyGovernor {
        require(governor_ != address(0), "zero addr");
        governor = governor_;
        emit GovernorTransferred(governor_);
    }

    function checkTransaction(
        address to,
        uint256 value,
        bytes memory data,
        Operation operation,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory,
        address
    ) external view override {
        require(operation == Operation.Call, "delegatecall blocked");
        _checkAction(msg.sender, to, value, data);
    }

    function checkAfterExecution(bytes32, bool) external pure override {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == ERC165_INTERFACE_ID || interfaceId == type(ITransactionGuard).interfaceId;
    }

    function _checkAction(address safe, address to, uint256 value, bytes memory data) private view {
        uint256 agentId = safeAgent[safe];
        require(agentId != 0, "safe not registered");
        address asset = data.length == 0 ? address(0) : to;
        uint256 portfolioValue = _portfolioValue(safe, asset);
        (bool allowed, string memory reason,,) = reefGuard.canExecuteAction(
            agentId,
            IReefGuardAction.Action({
                target: to,
                value: value,
                data: data,
                asset: asset,
                portfolioValue: portfolioValue
            })
        );
        require(allowed, reason);
    }

    function _portfolioValue(address safe, address asset) private view returns (uint256) {
        if (asset == address(0)) return safe.balance;
        return IERC20Balance(asset).balanceOf(safe);
    }
}
