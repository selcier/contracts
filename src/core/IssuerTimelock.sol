// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Timelocked multi-sig for company administration
/// @notice Serves as DEFAULT_ADMIN_ROLE holder across a company's contract set. Sensitive changes, such as rule
///         changes, upgrades, verifier changes and role grants, first collect M-of-N signer approvals and then sit
///         through a delay chosen by the function being called. Anyone can see the pending action for as long as
///         the delay runs.
/// @dev The delay lookup uses the function selector. Going through the timelock itself, a company can adjust a
///      selector's delay, but never to less than that selector's floor. Execution recounts approvals against whoever
///      is a signer at that moment, so a removed signer's pending approvals stop counting (and count again if that
///      signer returns).
contract IssuerTimelock is Initializable, ReentrancyGuard {
    uint256 public constant MAX_SIGNERS = 20;
    uint64 public constant DEFAULT_DELAY = 48 hours;
    uint64 public constant MODULE_DELAY = 24 hours;
    uint64 public constant UPGRADE_DELAY = 7 days;

    // Functions whose delay floor differs from DEFAULT_DELAY.
    bytes4 internal constant ADD_MODULE = bytes4(keccak256("addModule(address,bytes)"));
    bytes4 internal constant REMOVE_MODULE = bytes4(keccak256("removeModule(address)"));
    bytes4 internal constant CONFIGURE_MODULE = bytes4(keccak256("configureModule(address,bytes)"));
    bytes4 internal constant UPGRADE_TO_AND_CALL = bytes4(keccak256("upgradeToAndCall(address,bytes)"));

    struct Action {
        address target;
        uint256 value;
        bytes data;
        uint64 eta;
        bool executed;
        bool cancelled;
        address[] approvers;
    }

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 threshold);
    event DelayChanged(bytes4 indexed selector, uint64 delay);
    event ActionProposed(bytes32 indexed id, address indexed proposer, address target, uint256 value, bytes data);
    event ActionApproved(bytes32 indexed id, address indexed signer);
    event ActionQueued(bytes32 indexed id, uint64 eta);
    event ActionExecuted(bytes32 indexed id);
    event ActionCancelled(bytes32 indexed id);

    error NotSigner();
    error OnlySelf();
    error InvalidSigners();
    error InvalidThreshold();
    error UnknownAction();
    error ActionExists();
    error AlreadyApproved();
    error NotQueued();
    error TooEarly();
    error ActionClosed();
    error DelayBelowMinimum();
    error CallFailed(bytes returndata);

    address[] private _signers;
    mapping(address => bool) public isSigner;
    uint256 public threshold;
    mapping(bytes4 => uint64) private _delayOverride;
    mapping(bytes32 => Action) private _actions;

    constructor() {
        _disableInitializers();
    }

    function initialize(address[] calldata signers_, uint256 threshold_) external initializer {
        if (signers_.length == 0 || signers_.length > MAX_SIGNERS) revert InvalidSigners();
        for (uint256 i; i < signers_.length; ++i) {
            _addSigner(signers_[i]);
        }
        _setThreshold(threshold_);
    }

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Proposing, approving and executing actions
    // ---------------------------------------------------------------------------------------------------------------

    function hashAction(address target, uint256 value, bytes calldata data, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, salt));
    }

    function propose(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        onlySigner
        returns (bytes32 id)
    {
        id = hashAction(target, value, data, salt);
        Action storage a = _actions[id];
        if (a.target != address(0)) revert ActionExists();
        a.target = target;
        a.value = value;
        a.data = data;
        emit ActionProposed(id, msg.sender, target, value, data);
        _approve(id, a);
    }

    function approve(bytes32 id) external onlySigner {
        Action storage a = _actions[id];
        if (a.target == address(0)) revert UnknownAction();
        _approve(id, a);
    }

    function execute(bytes32 id) external payable nonReentrant returns (bytes memory) {
        Action storage a = _actions[id];
        if (a.target == address(0)) revert UnknownAction();
        if (a.executed || a.cancelled) revert ActionClosed();
        if (a.eta == 0 || _validApprovals(a) < threshold) revert NotQueued();
        if (block.timestamp < a.eta) revert TooEarly();
        a.executed = true;
        (bool ok, bytes memory ret) = a.target.call{value: a.value}(a.data);
        if (!ok) revert CallFailed(ret);
        emit ActionExecuted(id);
        return ret;
    }

    function cancel(bytes32 id) external onlySigner {
        Action storage a = _actions[id];
        if (a.target == address(0)) revert UnknownAction();
        if (a.executed || a.cancelled) revert ActionClosed();
        a.cancelled = true;
        emit ActionCancelled(id);
    }

    function action(bytes32 id) external view returns (Action memory) {
        return _actions[id];
    }

    /// @notice Counts the approvals `execute` would accept right now, leaving out anyone no longer a signer.
    function approvalCount(bytes32 id) external view returns (uint256) {
        return _validApprovals(_actions[id]);
    }

    /// @notice Reports whether `execute` would proceed at this moment. The action has to be open and queued, with its
    ///         delay elapsed and enough approvals from current signers. The target call could still revert afterwards.
    function isReady(bytes32 id) external view returns (bool) {
        Action storage a = _actions[id];
        return a.target != address(0) && !a.executed && !a.cancelled && a.eta != 0 && block.timestamp >= a.eta
            && _validApprovals(a) >= threshold;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Delay lookup and configuration
    // ---------------------------------------------------------------------------------------------------------------

    function minDelay(bytes4 selector) public pure returns (uint64) {
        if (selector == UPGRADE_TO_AND_CALL) return UPGRADE_DELAY;
        if (selector == ADD_MODULE || selector == REMOVE_MODULE || selector == CONFIGURE_MODULE) return MODULE_DELAY;
        return DEFAULT_DELAY;
    }

    function delayFor(bytes4 selector) public view returns (uint64) {
        uint64 custom = _delayOverride[selector];
        uint64 floor = minDelay(selector);
        return custom > floor ? custom : floor;
    }

    function setDelay(bytes4 selector, uint64 delay) external onlySelf {
        if (delay < minDelay(selector)) revert DelayBelowMinimum();
        _delayOverride[selector] = delay;
        emit DelayChanged(selector, delay);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Signer set, which can only change through an action run by this timelock
    // ---------------------------------------------------------------------------------------------------------------

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function addSigner(address signer) external onlySelf {
        _addSigner(signer);
    }

    function removeSigner(address signer) external onlySelf {
        if (!isSigner[signer]) revert InvalidSigners();
        isSigner[signer] = false;
        uint256 n = _signers.length;
        for (uint256 i; i < n; ++i) {
            if (_signers[i] == signer) {
                _signers[i] = _signers[n - 1];
                _signers.pop();
                break;
            }
        }
        if (threshold > _signers.length) revert InvalidThreshold();
        emit SignerRemoved(signer);
    }

    function setThreshold(uint256 threshold_) external onlySelf {
        _setThreshold(threshold_);
    }

    receive() external payable {}

    // ---------------------------------------------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _approve(bytes32 id, Action storage a) private {
        if (a.executed || a.cancelled) revert ActionClosed();
        for (uint256 i; i < a.approvers.length; ++i) {
            if (a.approvers[i] == msg.sender) revert AlreadyApproved();
        }
        a.approvers.push(msg.sender);
        emit ActionApproved(id, msg.sender);
        if (a.eta == 0 && _validApprovals(a) >= threshold) {
            a.eta = uint64(block.timestamp) + delayFor(_selector(a.data));
            emit ActionQueued(id, a.eta);
        }
    }

    function _validApprovals(Action storage a) private view returns (uint256 n) {
        for (uint256 i; i < a.approvers.length; ++i) {
            if (isSigner[a.approvers[i]]) ++n;
        }
    }

    function _selector(bytes memory data) private pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }

    function _addSigner(address signer) private {
        if (signer == address(0) || isSigner[signer] || _signers.length >= MAX_SIGNERS) revert InvalidSigners();
        isSigner[signer] = true;
        _signers.push(signer);
        emit SignerAdded(signer);
    }

    function _setThreshold(uint256 threshold_) private {
        if (threshold_ == 0 || threshold_ > _signers.length) revert InvalidThreshold();
        threshold = threshold_;
        emit ThresholdChanged(threshold_);
    }
}
