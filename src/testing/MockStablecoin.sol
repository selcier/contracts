// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Freely mintable 6-decimal test stablecoin
/// @notice Takes the place of USDG on testnet and in the test suite. Because minting is open to every caller, this
///         contract must never be deployed to mainnet.
contract MockStablecoin is ERC20 {
    constructor() ERC20("Test USDG", "tUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
