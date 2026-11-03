// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

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

/// @dev Common setup for the suite. It registers every implementation with a factory and deploys one company,
///      "LARKWAY", whose timelock needs 2 of 3 signers. Helpers cover holder verification, share class deployment
///      and actions routed through the timelock.
abstract contract Base is Test {
    bytes32 internal constant COMPANY = "LARKWAY";
    bytes2 internal constant US = "US";
    bytes2 internal constant GB = "GB";
    bytes2 internal constant SG = "SG";
    bytes2 internal constant KP = "KP";

    SelcierFactory internal factory;
    MockStablecoin internal usdg;
    ISelcierFactory.CompanyContracts internal c;
    IdentityRegistry internal registry;
    IssuerTimelock internal timelock;
    OfferingVault internal offerings;
    LiquidityWindow internal windows;
    RFQSettlement internal rfq;
    DistributionVault internal distributions;
    Governance internal governance;
    DisclosureRegistry internal disclosures;

    address internal selcier = makeAddr("selcier");
    address internal issuerAdmin = makeAddr("issuerAdmin");
    address internal registrar = makeAddr("registrar");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal signer1 = makeAddr("signer1");
    address internal signer2 = makeAddr("signer2");
    address internal signer3 = makeAddr("signer3");

    address internal verifier;
    uint256 internal verifierKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint64 internal constant ONE_YEAR = 365 days;
    uint64 internal constant CLAIM_TTL = 5 * 365 days;
    uint256 internal constant T0 = 1_760_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        vm.roll(1_000);
        (verifier, verifierKey) = makeAddrAndKey("verifier");
        usdg = new MockStablecoin();

        SelcierFactory.Implementations memory impls = SelcierFactory.Implementations({
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
        factory = new SelcierFactory(
            selcier,
            impls,
            SelcierFactory.Fees({recipient: feeRecipient, offeringBps: 100, sellerBps: 25, buyerBps: 25})
        );

        vm.startPrank(selcier);
        factory.setModuleImplementation("REGION", address(new RegionModule()));
        factory.setModuleImplementation("ELIGIBILITY", address(new EligibilityModule()));
        factory.setModuleImplementation("HOLDING_PERIOD", address(new HoldingPeriodModule()));
        factory.setModuleImplementation("HOLDER_CAP", address(new HolderCapModule()));
        factory.setModuleImplementation("TRANSFER_WINDOW", address(new TransferWindowModule()));
        factory.setModuleImplementation("ROFR", address(new ROFRModule()));
        factory.setModuleImplementation("MAX_OWNERSHIP", address(new MaxOwnershipModule()));
        factory.setModuleImplementation("EMPLOYEE_VESTING", address(new EmployeeVestingModule()));

        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier;
        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = _allTopics();
        factory.setDefaultVerifiers(verifiers, topics);

        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        c = factory.deployCompany(
            SelcierFactory.CompanyParams({
                companyId: COMPANY,
                issuerAdmin: issuerAdmin,
                registrar: registrar,
                operator: operator,
                treasury: treasury,
                timelockSigners: signers,
                timelockThreshold: 2,
                verifiers: new address[](0),
                verifierTopics: new bytes32[][](0)
            })
        );
        vm.stopPrank();

        registry = IdentityRegistry(c.identityRegistry);
        timelock = IssuerTimelock(payable(c.issuerTimelock));
        offerings = OfferingVault(c.offeringVault);
        windows = LiquidityWindow(c.liquidityWindow);
        rfq = RFQSettlement(c.rfqSettlement);
        distributions = DistributionVault(c.distributionVault);
        governance = Governance(c.governance);
        disclosures = DisclosureRegistry(c.disclosureRegistry);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deploying share classes and building module lists
    // ---------------------------------------------------------------------------------------------------------------

    function _deployClass(bytes32 shareClass, SelcierFactory.ModuleInit[] memory modules)
        internal
        returns (SelcierShareToken token)
    {
        vm.prank(selcier);
        token = SelcierShareToken(
            factory.deployShareClass(
                SelcierFactory.ShareClassParams({
                    companyId: COMPANY,
                    shareClass: shareClass,
                    name: string(abi.encodePacked("Larkway ", shareClass)),
                    symbol: "NWD",
                    documentsRoot: keccak256("terms"),
                    modules: modules,
                    enablePools: false
                })
            )
        );
    }

    function _plainClass(bytes32 shareClass) internal returns (SelcierShareToken) {
        return _deployClass(shareClass, new SelcierFactory.ModuleInit[](0));
    }

    function _modules1(bytes32 id, bytes memory config) internal pure returns (SelcierFactory.ModuleInit[] memory m) {
        m = new SelcierFactory.ModuleInit[](1);
        m[0] = SelcierFactory.ModuleInit({moduleId: id, config: config});
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Verifying holders, adding claims and minting
    // ---------------------------------------------------------------------------------------------------------------

    function _verify(address wallet) internal {
        _verify(wallet, US, 1);
    }

    function _verify(address wallet, bytes2 region, uint8 tier) internal {
        vm.prank(operator);
        registry.registerIdentity(wallet, wallet);
        uint64 expiry = uint64(block.timestamp) + CLAIM_TTL;
        vm.startPrank(verifier);
        registry.addClaim(wallet, Topics.IDENTITY_VERIFIED, "", expiry, verifier, "");
        registry.addClaim(wallet, Topics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, verifier, "");
        registry.addClaim(wallet, Topics.REGION, abi.encode(region), expiry, verifier, "");
        registry.addClaim(wallet, Topics.INVESTOR_ELIGIBLE, abi.encode(tier), expiry, verifier, "");
        vm.stopPrank();
    }

    function _addClaim(address identity, bytes32 topic, bytes memory data) internal {
        vm.prank(verifier);
        registry.addClaim(identity, topic, data, uint64(block.timestamp) + CLAIM_TTL, verifier, "");
    }

    function _mint(SelcierShareToken token, address to, uint256 shares) internal {
        vm.prank(registrar);
        token.mint(to, shares, "cap-table");
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

    // ---------------------------------------------------------------------------------------------------------------
    // Timelocked actions, plus funding and unit helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _timelocked(address target, bytes memory data) internal returns (bytes memory) {
        bytes32 salt = keccak256(abi.encode(target, data, block.timestamp, gasleft()));
        vm.prank(signer1);
        bytes32 id = timelock.propose(target, 0, data, salt);
        vm.prank(signer2);
        timelock.approve(id);
        vm.warp(timelock.action(id).eta);
        return timelock.execute(id);
    }

    function _fund(address who, uint256 amount, address spender) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(spender, type(uint256).max);
    }

    function _usdg(uint256 whole) internal pure returns (uint256) {
        return whole * 1e6;
    }

    function _shares(uint256 whole) internal pure returns (uint256) {
        return whole * 1e18;
    }
}
