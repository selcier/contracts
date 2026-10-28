// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IIdentityRegistry {
    /// @notice Outcome of the identity check that `canTransfer` applies to each non-system party.
    enum Status {
        NOT_VERIFIED,
        CLAIM_EXPIRED,
        VERIFIED
    }

    struct Claim {
        address verifier;
        uint64 expiry;
        bytes data;
    }

    event IdentityRegistered(address indexed wallet, address indexed identity);
    event IdentityRemoved(address indexed wallet);
    event ClaimAdded(address indexed identity, bytes32 indexed topic, address verifier, uint64 expiry);
    event ClaimRevoked(address indexed identity, bytes32 indexed topic);

    function companyId() external view returns (bytes32);
    function registerIdentity(address wallet, address identity) external;
    function removeIdentity(address wallet) external;
    function identityOf(address wallet) external view returns (address);
    function addClaim(
        address identity,
        bytes32 topic,
        bytes calldata data,
        uint64 expiry,
        address verifier,
        bytes calldata signature
    ) external;
    function revokeClaim(address identity, bytes32 topic) external;
    function claimOf(address identity, bytes32 topic) external view returns (Claim memory);
    function isVerified(address wallet) external view returns (bool);
    function status(address wallet) external view returns (Status);
    function hasValidClaim(address wallet, bytes32 topic) external view returns (bool);
    function claimData(address wallet, bytes32 topic) external view returns (bytes memory);
}
