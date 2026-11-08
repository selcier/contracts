// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IdentityBalanceModule} from "./BaseModule.sol";
import {ReasonCodes} from "../../shared/ReasonCodes.sol";

/// @title Per-identity ownership ceiling
/// @notice No single identity may hold more of the class than a limit expressed in basis points of total supply.
/// @dev The module expects a basis point limit, a mint flag and an exempt list, laid out as
///      `abi.encode(uint16 maxBps, bool applyToMints, address[] exemptIdentities)`. Clearing `applyToMints` restricts
///      the limit to transfers, and the registrar can then import a cap table in whatever order suits it.
contract MaxOwnershipModule is IdentityBalanceModule {
    event CeilingUpdated(uint16 maxBps, bool applyToMints, uint256 exemptCount);
    uint256 public constant MAX_EXEMPT = 32;

    uint16 public maxBps;
    bool public applyToMints;
    address[] private _exempt;
    mapping(address => bool) public isExempt;

    function moduleId() external pure returns (bytes32) {
        return "MAX_OWNERSHIP";
    }

    function exemptIdentities() external view returns (address[] memory) {
        return _exempt;
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        if (_isSystem(to)) return ReasonCodes.OK;
        if (from == address(0) && !applyToMints) return ReasonCodes.OK;
        address toId = _identity(to);
        if (toId == address(0) || isExempt[toId]) return ReasonCodes.OK;
        if (from != address(0) && !_isSystem(from) && _identity(from) == toId) return ReasonCodes.OK;
        uint256 supply = token.totalSupply() + (from == address(0) ? amount : 0);
        if (supply == 0) return ReasonCodes.OK;
        uint256 next = identityBalance[toId] + amount;
        return next * 10_000 > uint256(maxBps) * supply ? ReasonCodes.MAX_OWNERSHIP_EXCEEDED : ReasonCodes.OK;
    }

    function _configure(bytes calldata config) internal override {
        (uint16 bps, bool mints, address[] memory exempt) = abi.decode(config, (uint16, bool, address[]));
        if (bps == 0 || bps > 10_000 || exempt.length > MAX_EXEMPT) revert InvalidConfig();
        maxBps = bps;
        applyToMints = mints;
        for (uint256 i; i < _exempt.length; ++i) {
            isExempt[_exempt[i]] = false;
        }
        delete _exempt;
        for (uint256 i; i < exempt.length; ++i) {
            isExempt[exempt[i]] = true;
            _exempt.push(exempt[i]);
        }
        emit CeilingUpdated(bps, mints, exempt.length);
    }
}
