// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A single condition transfers must meet. An instance is tied to one RuleEngine, and through it to one share
///         class.
interface IRuleModule {
    /// @notice Names the module type with a value that never varies, for example "REGION" or "ROFR".
    function moduleId() external pure returns (bytes32);
    function engine() external view returns (address);

    /// @notice Gives the module's own reason code when a transfer breaks the rule, and `OK` when it does not.
    function check(address from, address to, uint256 amount) external view returns (bytes32 reasonCode);

    /// @notice Lets the module update its state. The engine calls this once balances have moved.
    function onTransfer(address from, address to, uint256 amount, address operator) external;

    /// @notice Restricted to the engine. Depending on the module, this overwrites or adds to the current configuration.
    function configure(bytes calldata config) external;

    /// @notice How much of `holder`'s balance this module is blocking from transfer right now.
    function lockedBalance(address holder) external view returns (uint256);
}
