// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRuleEngine {
    event ModuleAdded(address indexed module);
    event ModuleRemoved(address indexed module);
    event ModuleConfigured(address indexed module, bytes32 configHash);

    function token() external view returns (address);
    function modules() external view returns (address[] memory);
    function hasModule(bytes32 moduleId) external view returns (bool);

    /// @notice Walks the enabled modules in order and stops at the first failure, returning that module's reason
    ///         code. The result is `OK` only when all of them pass.
    function check(address from, address to, uint256 amount) external view returns (bytes32 reasonCode);

    /// @notice The token invokes this hook once balances have moved, giving stateful modules a chance to update.
    /// @param operator Whoever moved the tokens: the token's caller, or the token itself for a recovery. Lots take
    ///        their acquisition source label from this value.
    function transferred(address from, address to, uint256 amount, address operator) external;

    /// @notice Adds up what each module holds back, such as holding periods and vesting. This errs on the
    ///         conservative side, because overlapping locks accumulate instead of resolving to the largest one.
    function lockedBalance(address holder) external view returns (uint256);

    function addModule(address module, bytes calldata config) external;
    function removeModule(address module) external;
    function configureModule(address module, bytes calldata config) external;
}
