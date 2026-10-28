// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Role identifiers for access control
/// @notice Selcier contracts take their role identifiers from this list. `DEFAULT_ADMIN_ROLE` (0x00) goes to the
///         company's IssuerTimelock at deployment, which puts anything gated on it behind both signer approval and a
///         delay.
library Roles {
    /// @dev Meant for the company's operational multi-sig, which runs offerings, windows, distributions, votes and
    ///      documents.
    bytes32 internal constant ISSUER_ADMIN = keccak256("selcier.role.ISSUER_ADMIN");
    /// @dev Keeper of the authoritative cap table, with the power to mint, burn, freeze and carry out recoveries.
    bytes32 internal constant REGISTRAR = keccak256("selcier.role.REGISTRAR");
    /// @dev A relayer Selcier runs for each company. It registers identities and co-signs recoveries.
    bytes32 internal constant OPERATOR = keccak256("selcier.role.OPERATOR");
    /// @dev Can stop or resume a share token with no delay.
    bytes32 internal constant PAUSER = keccak256("selcier.role.PAUSER");
    /// @dev Lets a contract like the OfferingVault mint even though it lacks REGISTRAR.
    bytes32 internal constant MINTER = keccak256("selcier.role.MINTER");
    /// @dev Required to publish a Reference Valuation.
    bytes32 internal constant PUBLISHER = keccak256("selcier.role.PUBLISHER");
    /// @dev Required to anchor a document.
    bytes32 internal constant ANCHORER = keccak256("selcier.role.ANCHORER");
}
