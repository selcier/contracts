// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IRuleModule} from "../../api/IRuleModule.sol";
import {ISelcierShareToken} from "../../api/ISelcierShareToken.sol";
import {IIdentityRegistry} from "../../api/IIdentityRegistry.sol";

/// @title Common base for transfer rule modules
/// @notice Holds the plumbing every rule needs. Each module instance serves exactly one engine and one token.
/// @dev Two kinds of party count as "system": the zero address, which marks a mint or burn, and agents, meaning escrow
///      contracts and approved venues. A rule on the recipient side ignores system recipients and a rule on the sender
///      side ignores system senders. The effect is that rules land on the real holders at either end of a trade.
abstract contract BaseModule is IRuleModule, Initializable {
    error OnlyEngine();
    error InvalidConfig();

    address public engine;
    ISelcierShareToken public token;
    IIdentityRegistry public registry;

    constructor() {
        _disableInitializers();
    }

    function initialize(address engine_, address token_) external initializer {
        if (engine_ == address(0) || token_ == address(0)) revert InvalidConfig();
        engine = engine_;
        token = ISelcierShareToken(token_);
        registry = ISelcierShareToken(token_).identityRegistry();
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    function configure(bytes calldata config) external onlyEngine {
        _configure(config);
    }

    function onTransfer(address from, address to, uint256 amount, address operator) external onlyEngine {
        _onTransfer(from, to, amount, operator);
    }

    function lockedBalance(address) external view virtual returns (uint256) {
        return 0;
    }

    function _configure(bytes calldata config) internal virtual;

    function _onTransfer(address from, address to, uint256 amount, address operator) internal virtual {}

    function _isSystem(address account) internal view returns (bool) {
        return account == address(0) || token.isAgent(account);
    }

    function _identity(address wallet) internal view returns (address) {
        return registry.identityOf(wallet);
    }
}

/// @title Identity-level balance tracking for rule modules
/// @notice Holder caps, ownership caps and vesting all care about what an identity holds across its wallets, so their
///         modules inherit from this contract. Tracking begins only once a module is added, which is why a share
///         class should receive these modules at deployment, ahead of the first mint.
abstract contract IdentityBalanceModule is BaseModule {
    mapping(address => uint256) public identityBalance;

    function _onTransfer(address from, address to, uint256 amount, address) internal virtual override {
        address fromId = _isSystem(from) ? address(0) : _identity(from);
        address toId = _isSystem(to) ? address(0) : _identity(to);
        if (fromId == toId) return;
        if (fromId != address(0)) {
            uint256 before = identityBalance[fromId];
            uint256 next = before > amount ? before - amount : 0;
            identityBalance[fromId] = next;
            if (before != 0 && next == 0) _onIdentityEmptied(fromId);
        }
        if (toId != address(0)) {
            uint256 before = identityBalance[toId];
            identityBalance[toId] = before + amount;
            if (before == 0 && amount != 0) _onIdentityFunded(toId);
        }
    }

    function _onIdentityEmptied(address identity) internal virtual {}

    function _onIdentityFunded(address identity) internal virtual {}
}
