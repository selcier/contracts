// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title Chain-aware snapshot clock
/// @notice Supplies the timepoint that balance snapshots are measured in, for both record blocks and vote snapshots.
/// @dev `block.number` is the wrong source on Arbitrum chains, Robinhood Chain among them. There it only approximates
///      the L1 block number, and that moves far more slowly than L2 blocks. Reading the ArbSys precompile yields the
///      real L2 block number instead. Since Nitro puts a one-byte stub at every precompile address, checking the code
///      size is enough to detect Arbitrum. Other environments, such as local Anvil and Foundry tests, get
///      `block.number`.
///
///      A local EVM forking an Arbitrum chain can see the stub without implementing the precompile, and then the read
///      fails. Foundry simulations, which precede every `forge script` broadcast, are one such case. For that reason
///      ArbSys is read through a gas-capped staticcall that has a fallback.
library Clock {
    address internal constant ARB_SYS = address(100);
    uint256 private constant CALL_GAS = 20_000;

    function now48() internal view returns (uint48) {
        if (ARB_SYS.code.length > 0) {
            (bool ok, bytes memory ret) = ARB_SYS.staticcall{gas: CALL_GAS}(abi.encodeCall(IArbSys.arbBlockNumber, ()));
            if (ok && ret.length == 32) return uint48(abi.decode(ret, (uint256)));
        }
        return uint48(block.number);
    }
}
