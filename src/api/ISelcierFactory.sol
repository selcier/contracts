// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ISelcierFactory {
    struct CompanyContracts {
        address identityRegistry;
        address trustedVerifiers;
        address offeringVault;
        address liquidityWindow;
        address rfqSettlement;
        address distributionVault;
        address governance;
        address disclosureRegistry;
        address issuerTimelock;
    }

    struct ShareClassInfo {
        bytes32 companyId;
        bytes32 shareClass;
        address ruleEngine;
        address valuationOracle;
        address poolGate;
    }

    event CompanyDeployed(
        bytes32 indexed companyId,
        address identityRegistry,
        address trustedVerifiers,
        address offeringVault,
        address liquidityWindow,
        address rfqSettlement,
        address distributionVault,
        address governance,
        address disclosureRegistry,
        address issuerTimelock
    );
    event ShareClassDeployed(
        bytes32 indexed companyId,
        bytes32 indexed shareClass,
        address token,
        address ruleEngine,
        address valuationOracle
    );
    event PoolGateDeployed(bytes32 indexed companyId, address indexed token, address poolGate);

    function companyContracts(bytes32 companyId) external view returns (CompanyContracts memory);
    function shareClassOf(address token) external view returns (ShareClassInfo memory);
    function shareTokens(bytes32 companyId) external view returns (address[] memory);
}
