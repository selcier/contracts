// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SelcierFactory} from "../src/core/SelcierFactory.sol";
import {ISelcierFactory} from "../src/api/ISelcierFactory.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {TrustedVerifiers} from "../src/identity/TrustedVerifiers.sol";
import {RuleEngine} from "../src/compliance/RuleEngine.sol";
import {OfferingVault} from "../src/markets/OfferingVault.sol";
import {LiquidityWindow} from "../src/markets/LiquidityWindow.sol";
import {RFQSettlement} from "../src/markets/RFQSettlement.sol";
import {DistributionVault} from "../src/shareholder/DistributionVault.sol";
import {Governance} from "../src/shareholder/Governance.sol";
import {DisclosureRegistry} from "../src/shareholder/DisclosureRegistry.sol";
import {IssuerTimelock} from "../src/core/IssuerTimelock.sol";
import {ValuationOracle} from "../src/shareholder/ValuationOracle.sol";
import {PoolGate} from "../src/markets/PoolGate.sol";
import {RegionModule} from "../src/compliance/rules/RegionModule.sol";
import {EligibilityModule} from "../src/compliance/rules/EligibilityModule.sol";
import {HoldingPeriodModule} from "../src/compliance/rules/HoldingPeriodModule.sol";
import {HolderCapModule} from "../src/compliance/rules/HolderCapModule.sol";
import {TransferWindowModule} from "../src/compliance/rules/TransferWindowModule.sol";
import {ROFRModule} from "../src/compliance/rules/ROFRModule.sol";
import {MaxOwnershipModule} from "../src/compliance/rules/MaxOwnershipModule.sol";
import {EmployeeVestingModule} from "../src/compliance/rules/EmployeeVestingModule.sol";
import {MockStablecoin} from "../src/testing/MockStablecoin.sol";
import {Topics} from "../src/shared/Topics.sol";

/// @title Network launch script for the Selcier contracts
/// @notice Puts Selcier on any EVM network, with Robinhood Chain testnet (46630) as the usual target. The resulting
///         addresses land in `deployments/<chainId>.json`: the factory, the stablecoin and, when a demo company was
///         deployed, its main contracts and share classes.
///
///         forge script script/Deploy.s.sol --broadcast --verify --rpc-url robinhood_testnet
///
///         Read from the environment, as documented in .env.example:
///         - PRIVATE_KEY        the deployer and factory owner; by default also the fee recipient and default
///                              verifier
///         - USDG               address of the stablecoin; required on mainnet, while a blank value elsewhere
///                              deploys a 6-decimal test stablecoin
///         - FEE_RECIPIENT      optional override, defaulting to the deployer
///         - DEFAULT_VERIFIER   optional override, defaulting to the deployer; this identity provider key is
///                              trusted for every claim topic
///         - DEPLOY_DEMO        optional; true by default off mainnet and false on it. Adds a demo company with
///                              two share classes. When the deployer is also the verifier, it gets verified
///                              too, and the demo gains a cap table plus an offering left open
contract Deploy is Script {
    uint256 internal constant MAINNET = 4663;
    bytes32 internal constant DEMO_COMPANY = "LARKWAY_LABS";

    struct Deployed {
        SelcierFactory factory;
        address stablecoin;
        ISelcierFactory.CompanyContracts company;
        address common;
        address seriesB;
        uint256 offeringId;
    }

    function run() external returns (Deployed memory d) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        bool isMainnet = block.chainid == MAINNET;
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address verifier = vm.envOr("DEFAULT_VERIFIER", deployer);
        bool demo = vm.envOr("DEPLOY_DEMO", !isMainnet);

        vm.startBroadcast(key);

        d.stablecoin = vm.envOr("USDG", address(0));
        if (d.stablecoin == address(0)) {
            require(!isMainnet, "USDG must be set on mainnet");
            d.stablecoin = address(new MockStablecoin());
        }

        d.factory = new SelcierFactory(
            deployer,
            _implementations(),
            SelcierFactory.Fees({recipient: feeRecipient, offeringBps: 100, sellerBps: 25, buyerBps: 25})
        );
        _registerModules(d.factory);

        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier;
        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = _allTopics();
        d.factory.setDefaultVerifiers(verifiers, topics);

        if (demo) _demo(d, deployer, verifier == deployer);

        vm.stopBroadcast();
        _write(d);
    }

    // ---------------------------------------------------------------------------------------------------------------

    function _implementations() internal returns (SelcierFactory.Implementations memory) {
        return SelcierFactory.Implementations({
            shareToken: address(new SelcierShareToken()),
            identityRegistry: address(new IdentityRegistry()),
            trustedVerifiers: address(new TrustedVerifiers()),
            ruleEngine: address(new RuleEngine()),
            offeringVault: address(new OfferingVault()),
            liquidityWindow: address(new LiquidityWindow()),
            rfqSettlement: address(new RFQSettlement()),
            distributionVault: address(new DistributionVault()),
            governance: address(new Governance()),
            disclosureRegistry: address(new DisclosureRegistry()),
            issuerTimelock: address(new IssuerTimelock()),
            valuationOracle: address(new ValuationOracle()),
            poolGate: address(new PoolGate())
        });
    }

    function _registerModules(SelcierFactory f) internal {
        f.setModuleImplementation("REGION", address(new RegionModule()));
        f.setModuleImplementation("ELIGIBILITY", address(new EligibilityModule()));
        f.setModuleImplementation("HOLDING_PERIOD", address(new HoldingPeriodModule()));
        f.setModuleImplementation("HOLDER_CAP", address(new HolderCapModule()));
        f.setModuleImplementation("TRANSFER_WINDOW", address(new TransferWindowModule()));
        f.setModuleImplementation("ROFR", address(new ROFRModule()));
        f.setModuleImplementation("MAX_OWNERSHIP", address(new MaxOwnershipModule()));
        f.setModuleImplementation("EMPLOYEE_VESTING", address(new EmployeeVestingModule()));
    }

    /// @dev Builds a demo that needs only one key, so every flow can be tried from it. To allow that, the deployer
    ///      acts as issuer admin, registrar, operator, treasury and lone timelock signer. Outside a demo, a company
    ///      uses separate keys and a timelock with several signers.
    function _demo(Deployed memory d, address deployer, bool deployerIsVerifier) internal {
        address[] memory signers = new address[](1);
        signers[0] = deployer;
        d.company = d.factory
            .deployCompany(
                SelcierFactory.CompanyParams({
                    companyId: DEMO_COMPANY,
                    issuerAdmin: deployer,
                    registrar: deployer,
                    operator: deployer,
                    treasury: deployer,
                    timelockSigners: signers,
                    timelockThreshold: 1,
                    verifiers: new address[](0),
                    verifierTopics: new bytes32[][](0)
                })
            );

        // Common admits eligible investors plus the company's employees, blocks sanctioned regions and caps the
        // number of holders. Shares bought in an offering carry a 90-day lockup.
        bytes2[] memory blocked = new bytes2[](4);
        blocked[0] = "KP";
        blocked[1] = "IR";
        blocked[2] = "CU";
        blocked[3] = "SY";
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = "OFFERING";
        uint32[] memory periods = new uint32[](1);
        periods[0] = 90 days;
        address[] memory ops = new address[](2);
        ops[0] = d.company.offeringVault;
        ops[1] = d.company.liquidityWindow;
        bytes32[] memory opSources = new bytes32[](2);
        opSources[0] = "OFFERING";
        opSources[1] = "WINDOW";

        SelcierFactory.ModuleInit[] memory commonRules = new SelcierFactory.ModuleInit[](4);
        commonRules[0] = SelcierFactory.ModuleInit("REGION", abi.encode(uint8(1), blocked));
        commonRules[1] = SelcierFactory.ModuleInit("ELIGIBILITY", abi.encode(uint8(1), true));
        commonRules[2] = SelcierFactory.ModuleInit("HOLDER_CAP", abi.encode(uint32(2_000)));
        commonRules[3] =
            SelcierFactory.ModuleInit("HOLDING_PERIOD", abi.encode(uint32(0), sources, periods, ops, opSources));
        d.common = d.factory
            .deployShareClass(
                SelcierFactory.ShareClassParams({
                    companyId: DEMO_COMPANY,
                    shareClass: "COMMON",
                    name: "Larkway Labs Common",
                    symbol: "LKW-C",
                    documentsRoot: keccak256("larkway-common-terms-v1"),
                    modules: commonRules,
                    enablePools: false
                })
            );

        // Series B Preferred demands a higher eligibility tier than Common, and transfers face a 25% concentration cap.
        SelcierFactory.ModuleInit[] memory prefRules = new SelcierFactory.ModuleInit[](3);
        prefRules[0] = SelcierFactory.ModuleInit("REGION", abi.encode(uint8(1), blocked));
        prefRules[1] = SelcierFactory.ModuleInit("ELIGIBILITY", abi.encode(uint8(2), false));
        prefRules[2] = SelcierFactory.ModuleInit("MAX_OWNERSHIP", abi.encode(uint16(2_500), false, new address[](0)));
        d.seriesB = d.factory
            .deployShareClass(
                SelcierFactory.ShareClassParams({
                    companyId: DEMO_COMPANY,
                    shareClass: "SERIES_B",
                    name: "Larkway Labs Series B Preferred",
                    symbol: "LKW-B",
                    documentsRoot: keccak256("larkway-series-b-terms-v1"),
                    modules: prefRules,
                    enablePools: false
                })
            );

        if (!deployerIsVerifier) return; // only the configured verifier can issue the claims below

        // Next the deployer is verified, receives a small imported cap table, and opens a Series B offering.
        IdentityRegistry registry = IdentityRegistry(d.company.identityRegistry);
        registry.registerIdentity(deployer, deployer);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(deployer, Topics.IDENTITY_VERIFIED, "", expiry, deployer, "");
        registry.addClaim(deployer, Topics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, deployer, "");
        registry.addClaim(deployer, Topics.REGION, abi.encode(bytes2("US")), expiry, deployer, "");
        registry.addClaim(deployer, Topics.INVESTOR_ELIGIBLE, abi.encode(uint8(2)), expiry, deployer, "");

        SelcierShareToken(d.common).mint(deployer, 1_000_000e18, "cap-table-import");
        SelcierShareToken(d.seriesB).mint(deployer, 250_000e18, "cap-table-import");

        DisclosureRegistry(d.company.disclosureRegistry)
            .anchor("OFFERING_DOCUMENT", sha256("Larkway Labs Series B extension"), "https://selcier.xyz/demo");
        ValuationOracle(d.factory.shareClassOf(d.seriesB).valuationOracle)
            .publish(24e8, 1, uint64(block.timestamp), bytes32(0));

        bytes32[] memory claims = new bytes32[](1);
        claims[0] = Topics.INVESTOR_ELIGIBLE;
        d.offeringId = OfferingVault(d.company.offeringVault)
            .createOffering(
                OfferingVault.OfferingParams({
                shareToken: d.seriesB,
                pricePerShare: 25e6,
                minRaise: 50_000e6,
                maxRaise: 2_000_000e6,
                minTicket: 1_000e6,
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp + 30 days),
                stablecoin: d.stablecoin,
                requiredClaims: claims,
                treasury: deployer,
                documentId: 1
            })
            );
    }

    function _allTopics() internal pure returns (bytes32[] memory t) {
        t = new bytes32[](6);
        t[0] = Topics.IDENTITY_VERIFIED;
        t[1] = Topics.INVESTOR_ELIGIBLE;
        t[2] = Topics.REGION;
        t[3] = Topics.EMPLOYEE_OF;
        t[4] = Topics.SCREENED;
        t[5] = Topics.VENUE;
    }

    function _write(Deployed memory d) internal {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "factory", address(d.factory));
        string memory json = vm.serializeAddress(root, "stablecoin", d.stablecoin);

        if (d.company.issuerTimelock != address(0)) {
            string memory demo = "demo";
            vm.serializeString(demo, "companyId", "LARKWAY_LABS");
            vm.serializeAddress(demo, "identityRegistry", d.company.identityRegistry);
            vm.serializeAddress(demo, "trustedVerifiers", d.company.trustedVerifiers);
            vm.serializeAddress(demo, "offeringVault", d.company.offeringVault);
            vm.serializeAddress(demo, "liquidityWindow", d.company.liquidityWindow);
            vm.serializeAddress(demo, "rfqSettlement", d.company.rfqSettlement);
            vm.serializeAddress(demo, "distributionVault", d.company.distributionVault);
            vm.serializeAddress(demo, "governance", d.company.governance);
            vm.serializeAddress(demo, "disclosureRegistry", d.company.disclosureRegistry);
            vm.serializeAddress(demo, "issuerTimelock", d.company.issuerTimelock);
            vm.serializeAddress(demo, "common", d.common);
            string memory demoJson = vm.serializeAddress(demo, "seriesB", d.seriesB);
            json = vm.serializeString(root, "demo", demoJson);
        }

        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Factory:", address(d.factory));
        console2.log("Written to", path);
    }
}
