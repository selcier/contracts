// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Transfer rejection reason codes
/// @notice Possible results from `canTransfer`. Because every value is a left-aligned bytes32 string, an ordinary
///         bytes32-to-string conversion is all off-chain tooling needs to read one.
library ReasonCodes {
    bytes32 internal constant OK = "OK";

    // From the token's own checks
    bytes32 internal constant TOKEN_PAUSED = "TOKEN_PAUSED";
    bytes32 internal constant FROZEN = "FROZEN";
    bytes32 internal constant INSUFFICIENT_UNLOCKED_BALANCE = "INSUFFICIENT_UNLOCKED_BALANCE";

    // From identity checks
    bytes32 internal constant SENDER_NOT_VERIFIED = "SENDER_NOT_VERIFIED";
    bytes32 internal constant RECIPIENT_NOT_VERIFIED = "RECIPIENT_NOT_VERIFIED";
    bytes32 internal constant CLAIM_EXPIRED = "CLAIM_EXPIRED";

    // From transfer rule modules
    bytes32 internal constant REGION_BLOCKED = "REGION_BLOCKED";
    bytes32 internal constant NOT_ELIGIBLE = "NOT_ELIGIBLE";
    bytes32 internal constant HOLDING_PERIOD_ACTIVE = "HOLDING_PERIOD_ACTIVE";
    bytes32 internal constant HOLDER_CAP_REACHED = "HOLDER_CAP_REACHED";
    bytes32 internal constant WINDOW_CLOSED = "WINDOW_CLOSED";
    bytes32 internal constant ROFR_PENDING = "ROFR_PENDING";
    bytes32 internal constant MAX_OWNERSHIP_EXCEEDED = "MAX_OWNERSHIP_EXCEEDED";
    bytes32 internal constant UNVESTED = "UNVESTED";
    bytes32 internal constant STALE_SCREENING = "STALE_SCREENING";
}
