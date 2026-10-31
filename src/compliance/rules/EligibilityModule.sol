// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseModule} from "./BaseModule.sol";
import {ReasonCodes} from "../../shared/ReasonCodes.sol";
import {Topics} from "../../shared/Topics.sol";

/// @title Investor tier gate for recipients
/// @notice A recipient passes only with a valid INVESTOR_ELIGIBLE claim whose tier reaches the configured minimum.
/// @dev Encode the configuration as `abi.encode(uint8 minimumTier, bool exemptEmployees)`. Setting `exemptEmployees`
///      waives the tier requirement for anyone whose valid EMPLOYEE_OF claim names this company.
contract EligibilityModule is BaseModule {
    uint8 public minimumTier;
    bool public exemptEmployees;

    function moduleId() external pure returns (bytes32) {
        return "ELIGIBILITY";
    }

    function check(address, address to, uint256) external view returns (bytes32) {
        if (_isSystem(to)) return ReasonCodes.OK;
        if (exemptEmployees && registry.hasValidClaim(to, Topics.EMPLOYEE_OF)) {
            bytes32 employer = abi.decode(registry.claimData(to, Topics.EMPLOYEE_OF), (bytes32));
            if (employer == token.companyId()) return ReasonCodes.OK;
        }
        if (!registry.hasValidClaim(to, Topics.INVESTOR_ELIGIBLE)) return ReasonCodes.NOT_ELIGIBLE;
        uint8 tier = abi.decode(registry.claimData(to, Topics.INVESTOR_ELIGIBLE), (uint8));
        return tier >= minimumTier ? ReasonCodes.OK : ReasonCodes.NOT_ELIGIBLE;
    }

    function _configure(bytes calldata config) internal override {
        (minimumTier, exemptEmployees) = abi.decode(config, (uint8, bool));
    }
}
