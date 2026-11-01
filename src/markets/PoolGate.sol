// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {ISelcierShareToken} from "../api/ISelcierShareToken.sol";
import {ReasonCodes} from "../shared/ReasonCodes.sol";

/// @title Eligibility hook for permissioned AMM pools on one share class
/// @notice A permissioned AMM pool calls this hook ahead of swaps, liquidity additions and position transfers. Through
///         it, the share class rules reach the final recipient of shares and each liquidity provider.
/// @dev Registering a pool requires the token to count it as an agent, typically through a VENUE claim for this token
///      in the company's IdentityRegistry. Agents are pass-through for the token, so its rules land on the people on
///      either side. Recipient rules would be enforced by the token in any case once the pool sends shares. What this
///      gate adds is an early failure with a clear reason code, along with a restriction on LP positions, which are not
///      share tokens.
///      A right of first refusal cannot be exercised against an instant swap, so `registerPool` turns away share
///      classes that use that rule. The test happens only at registration.
contract PoolGate is AccessControl, Initializable {
    event PoolRegistered(address indexed pool);
    event PoolRemoved(address indexed pool);

    error ROFRIncompatible();
    error NotVenue();
    error UnknownPool();
    error PoolAlreadyRegistered();

    ISelcierShareToken public token;
    mapping(address => bool) public isPool;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin) external initializer {
        token = ISelcierShareToken(token_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function registerPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (isPool[pool]) revert PoolAlreadyRegistered();
        if (token.ruleEngine().hasModule("ROFR")) revert ROFRIncompatible();
        if (!token.isAgent(pool)) revert NotVenue();
        isPool[pool] = true;
        emit PoolRegistered(pool);
    }

    function removePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isPool[pool]) revert UnknownPool();
        isPool[pool] = false;
        emit PoolRemoved(pool);
    }

    /// @notice Gives the rules' verdict on `pool` sending `amount` shares to `recipient`, or NOT_ELIGIBLE for an
    ///         unregistered pool.
    function checkSwap(address pool, address recipient, uint256 amount) public view returns (bytes32) {
        if (!isPool[pool]) return ReasonCodes.NOT_ELIGIBLE;
        (, bytes32 code) = token.canTransfer(pool, recipient, amount);
        return code;
    }

    /// @notice Gives the rules' verdict on `provider` holding a liquidity position, or NOT_ELIGIBLE for an unregistered
    ///         pool. The provider is tested on every recipient-side rule as a recipient from the pool, using an amount
    ///         of zero, so limits based on size see no shares.
    function checkLiquidityProvider(address pool, address provider) public view returns (bytes32) {
        if (!isPool[pool]) return ReasonCodes.NOT_ELIGIBLE;
        (, bytes32 code) = token.canTransfer(pool, provider, 0);
        return code;
    }

    function beforeSwap(address recipient, uint256 sharesOut) external view {
        _require(checkSwap(msg.sender, recipient, sharesOut));
    }

    function beforeAddLiquidity(address provider) external view {
        _require(checkLiquidityProvider(msg.sender, provider));
    }

    function beforeTransferPosition(address, address to) external view {
        _require(checkLiquidityProvider(msg.sender, to));
    }

    function _require(bytes32 code) private pure {
        if (code != ReasonCodes.OK) revert ISelcierShareToken.TransferNotAllowed(code);
    }
}
