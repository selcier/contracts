// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Claim topic constants
/// @notice The topics Selcier contracts look up in the IdentityRegistry. Each constant is a left-aligned bytes32
///         string.
library Topics {
    /// @dev The holder has finished identity verification. This claim carries no data.
    bytes32 internal constant IDENTITY_VERIFIED = "IDENTITY_VERIFIED";
    /// @dev The investor's eligibility level, encoded as `abi.encode(uint8 tier)`.
    bytes32 internal constant INVESTOR_ELIGIBLE = "INVESTOR_ELIGIBLE";
    /// @dev Where the holder resides, encoded as `abi.encode(bytes2 iso3166Alpha2)`.
    bytes32 internal constant REGION = "REGION";
    /// @dev The holder's employer, encoded as `abi.encode(bytes32 companyId)`.
    bytes32 internal constant EMPLOYEE_OF = "EMPLOYEE_OF";
    /// @dev The holder cleared screening, with the time encoded as `abi.encode(uint64 lastScreenedAt)`.
    bytes32 internal constant SCREENED = "SCREENED";
    /// @dev Marks a contract as an approved venue, a permissioned pool for example. Its claim data holds the token
    ///      this approval covers, packed with `abi.encode(address shareToken)`.
    bytes32 internal constant VENUE = "VENUE";
}
