// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IdentityBalanceModule} from "./BaseModule.sol";
import {ReasonCodes} from "../../shared/ReasonCodes.sol";

/// @title Ceiling on distinct holders
/// @notice Limits how many separate identities can hold the share class at one time.
/// @dev Encode the configuration as `abi.encode(uint32 maxHolders)`. The count leaves out agents. A full register
///      never blocks a transfer that lands on an existing holder, one that moves shares between wallets of a single
///      identity, or one that empties the sender's entire position.
contract HolderCapModule is IdentityBalanceModule {
    uint32 public maxHolders;
    uint32 public holderCount;

    function moduleId() external pure returns (bytes32) {
        return "HOLDER_CAP";
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        if (_isSystem(to)) return ReasonCodes.OK;
        address toId = _identity(to);
        if (toId == address(0) || identityBalance[toId] != 0) return ReasonCodes.OK;
        if (!_isSystem(from)) {
            address fromId = _identity(from);
            if (fromId == toId || identityBalance[fromId] == amount) return ReasonCodes.OK;
        }
        return holderCount < maxHolders ? ReasonCodes.OK : ReasonCodes.HOLDER_CAP_REACHED;
    }

    function _onIdentityFunded(address) internal override {
        ++holderCount;
    }

    function _onIdentityEmptied(address) internal override {
        --holderCount;
    }

    function _configure(bytes calldata config) internal override {
        maxHolders = abi.decode(config, (uint32));
        if (maxHolders == 0) revert InvalidConfig();
    }
}
