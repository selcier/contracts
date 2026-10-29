// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ISelcierFactory} from "../api/ISelcierFactory.sol";
import {SelcierShareToken} from "./SelcierShareToken.sol";
import {IdentityRegistry} from "../identity/IdentityRegistry.sol";
import {TrustedVerifiers} from "../identity/TrustedVerifiers.sol";
import {RuleEngine} from "../compliance/RuleEngine.sol";
import {BaseModule} from "../compliance/rules/BaseModule.sol";
import {OfferingVault} from "../markets/OfferingVault.sol";
import {LiquidityWindow} from "../markets/LiquidityWindow.sol";
import {RFQSettlement} from "../markets/RFQSettlement.sol";
import {DistributionVault} from "../shareholder/DistributionVault.sol";
import {Governance} from "../shareholder/Governance.sol";
import {DisclosureRegistry} from "../shareholder/DisclosureRegistry.sol";
import {IssuerTimelock} from "./IssuerTimelock.sol";
import {ValuationOracle} from "../shareholder/ValuationOracle.sol";
import {PoolGate} from "../markets/PoolGate.sol";

/// @title Company and share class deployment root
/// @notice Each network has one instance of this contract, and every Selcier deployment there starts from it.
///         `deployCompany` gives a company its own complete, isolated contract set. `deployShareClass` gives a share
///         class a token, a rule engine, modules, a valuation oracle and, when pools are enabled, a pool gate.
///         To enumerate the contracts, index this address: `CompanyDeployed` lists a company's set,
///         `ShareClassDeployed` adds each token with its engine and oracle, and `PoolGateDeployed` reports pool gates.
///         Module clones appear in no event, so read those from `RuleEngine.modules()`.
/// @dev Whatever is created here makes the company's IssuerTimelock its DEFAULT_ADMIN, with two exceptions: the
///      timelock governs itself, and modules have no roles because they answer to their RuleEngine. Once a deployment
///      finishes the factory keeps no role anywhere; company contracts retain its address only to look up share
///      classes. Tokens sit behind ERC1967 (UUPS) proxies, which lets a company upgrade its own token via its
///      timelock. Everything else, modules included, is an EIP-1167 clone of a registered implementation.
///      Selcier owns the factory. Ownership allows deploying contract sets and registering implementations for later
///      deployments, and offers no way to alter contracts a company already has. It does allow adding a further share
///      class under an existing company through `deployShareClass`.
contract SelcierFactory is ISelcierFactory, Ownable2Step {
    struct Implementations {
        address shareToken;
        address identityRegistry;
        address trustedVerifiers;
        address ruleEngine;
        address offeringVault;
        address liquidityWindow;
        address rfqSettlement;
        address distributionVault;
        address governance;
        address disclosureRegistry;
        address issuerTimelock;
        address valuationOracle;
        address poolGate;
    }

    struct Fees {
        address recipient;
        uint16 offeringBps;
        uint16 sellerBps;
        uint16 buyerBps;
    }

    struct CompanyParams {
        bytes32 companyId;
        address issuerAdmin;
        address registrar;
        address operator;
        address treasury;
        address[] timelockSigners;
        uint256 timelockThreshold;
        address[] verifiers; // leave empty to fall back on the factory's default verifiers and topics
        bytes32[][] verifierTopics;
    }

    struct ModuleInit {
        bytes32 moduleId;
        bytes config;
    }

    struct ShareClassParams {
        bytes32 companyId;
        bytes32 shareClass;
        string name;
        string symbol;
        bytes32 documentsRoot;
        ModuleInit[] modules;
        bool enablePools;
    }

    struct CompanyRoles {
        address issuerAdmin;
        address registrar;
        address operator;
    }

    event ImplementationsUpdated();
    event ModuleImplementationSet(bytes32 indexed moduleId, address implementation);
    event DefaultVerifiersSet(address[] verifiers);
    event FeesSet(address recipient, uint16 offeringBps, uint16 sellerBps, uint16 buyerBps);

    error CompanyExists();
    error UnknownCompany();
    error ShareClassExists();
    error UnknownModule(bytes32 moduleId);
    error InvalidParams();

    Implementations public implementations;
    Fees public fees;
    mapping(bytes32 => address) public moduleImplementation;

    address[] private _defaultVerifiers;
    bytes32[][] private _defaultTopics;

    mapping(bytes32 => CompanyContracts) private _companies;
    mapping(bytes32 => CompanyRoles) private _roles;
    mapping(bytes32 => address[]) private _shareTokens;
    mapping(address => ShareClassInfo) private _shareClasses;
    mapping(bytes32 => mapping(bytes32 => address)) public shareTokenOf;
    bytes32[] private _companyIds;

    constructor(address owner_, Implementations memory impls, Fees memory fees_) Ownable(owner_) {
        implementations = impls;
        fees = fees_;
        emit ImplementationsUpdated();
        emit FeesSet(fees_.recipient, fees_.offeringBps, fees_.sellerBps, fees_.buyerBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Settings under owner control, which only take effect for later deployments
    // ---------------------------------------------------------------------------------------------------------------

    function setImplementations(Implementations calldata impls) external onlyOwner {
        implementations = impls;
        emit ImplementationsUpdated();
    }

    function setModuleImplementation(bytes32 moduleId, address implementation) external onlyOwner {
        moduleImplementation[moduleId] = implementation;
        emit ModuleImplementationSet(moduleId, implementation);
    }

    function setDefaultVerifiers(address[] calldata verifiers, bytes32[][] calldata topics) external onlyOwner {
        if (verifiers.length != topics.length) revert InvalidParams();
        _defaultVerifiers = verifiers;
        delete _defaultTopics;
        for (uint256 i; i < topics.length; ++i) {
            _defaultTopics.push(topics[i]);
        }
        emit DefaultVerifiersSet(verifiers);
    }

    function setFees(Fees calldata fees_) external onlyOwner {
        fees = fees_;
        emit FeesSet(fees_.recipient, fees_.offeringBps, fees_.sellerBps, fees_.buyerBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Creating companies and share classes
    // ---------------------------------------------------------------------------------------------------------------

    function deployCompany(CompanyParams calldata p) external onlyOwner returns (CompanyContracts memory c) {
        if (p.companyId == bytes32(0) || p.issuerAdmin == address(0) || p.registrar == address(0)) {
            revert InvalidParams();
        }
        if (p.operator == address(0) || p.treasury == address(0)) revert InvalidParams();
        if (_companies[p.companyId].issuerTimelock != address(0)) revert CompanyExists();
        Implementations memory impl = implementations;
        Fees memory f = fees;

        c.issuerTimelock = Clones.clone(impl.issuerTimelock);
        IssuerTimelock(payable(c.issuerTimelock)).initialize(p.timelockSigners, p.timelockThreshold);
        address admin = c.issuerTimelock;

        c.trustedVerifiers = Clones.clone(impl.trustedVerifiers);
        if (p.verifiers.length != 0) {
            TrustedVerifiers(c.trustedVerifiers).initialize(admin, p.verifiers, p.verifierTopics);
        } else {
            TrustedVerifiers(c.trustedVerifiers).initialize(admin, _defaultVerifiers, _defaultTopics);
        }

        c.identityRegistry = Clones.clone(impl.identityRegistry);
        IdentityRegistry(c.identityRegistry).initialize(p.companyId, c.trustedVerifiers, admin, p.operator);

        c.offeringVault = Clones.clone(impl.offeringVault);
        OfferingVault(c.offeringVault)
            .initialize(p.companyId, address(this), admin, p.issuerAdmin, f.recipient, f.offeringBps);

        c.liquidityWindow = Clones.clone(impl.liquidityWindow);
        LiquidityWindow(c.liquidityWindow)
            .initialize(p.companyId, address(this), admin, p.issuerAdmin, f.recipient, f.sellerBps, f.buyerBps);

        c.rfqSettlement = Clones.clone(impl.rfqSettlement);
        RFQSettlement(c.rfqSettlement)
            .initialize(p.companyId, address(this), admin, p.issuerAdmin, f.recipient, f.sellerBps, f.buyerBps);

        c.distributionVault = Clones.clone(impl.distributionVault);
        DistributionVault(c.distributionVault).initialize(p.companyId, address(this), admin, p.issuerAdmin, p.treasury);

        c.governance = Clones.clone(impl.governance);
        Governance(c.governance).initialize(p.companyId, address(this), c.identityRegistry, admin, p.issuerAdmin);

        c.disclosureRegistry = Clones.clone(impl.disclosureRegistry);
        address[] memory anchorers = new address[](2);
        anchorers[0] = p.issuerAdmin;
        anchorers[1] = p.registrar;
        DisclosureRegistry(c.disclosureRegistry).initialize(p.companyId, admin, anchorers);

        _companies[p.companyId] = c;
        _roles[p.companyId] = CompanyRoles({issuerAdmin: p.issuerAdmin, registrar: p.registrar, operator: p.operator});
        _companyIds.push(p.companyId);

        emit CompanyDeployed(
            p.companyId,
            c.identityRegistry,
            c.trustedVerifiers,
            c.offeringVault,
            c.liquidityWindow,
            c.rfqSettlement,
            c.distributionVault,
            c.governance,
            c.disclosureRegistry,
            c.issuerTimelock
        );
    }

    function deployShareClass(ShareClassParams calldata p) external onlyOwner returns (address token) {
        CompanyContracts memory c = _companies[p.companyId];
        if (c.issuerTimelock == address(0)) revert UnknownCompany();
        if (shareTokenOf[p.companyId][p.shareClass] != address(0)) revert ShareClassExists();
        Implementations memory impl = implementations;
        CompanyRoles memory r = _roles[p.companyId];

        // Token and engine each need the other's address. Predicting the engine's clone address from a salt breaks
        // that cycle: the token is built against the prediction, and the engine is cloned there afterwards.
        bytes32 salt = keccak256(abi.encode(p.companyId, p.shareClass));
        address engine = Clones.predictDeterministicAddress(impl.ruleEngine, salt, address(this));

        token = _deployToken(p, c, r, engine);

        (address[] memory modules, bytes[] memory configs) = _deployModules(p.modules, engine, token);
        Clones.cloneDeterministic(impl.ruleEngine, salt);
        RuleEngine(engine).initialize(token, c.issuerTimelock, modules, configs);

        address oracle = Clones.clone(impl.valuationOracle);
        address[] memory publishers = new address[](3);
        publishers[0] = r.issuerAdmin;
        publishers[1] = c.offeringVault;
        publishers[2] = c.liquidityWindow;
        ValuationOracle(oracle).initialize(token, c.issuerTimelock, publishers);

        address gate;
        if (p.enablePools) {
            gate = Clones.clone(impl.poolGate);
            PoolGate(gate).initialize(token, c.issuerTimelock);
            emit PoolGateDeployed(p.companyId, token, gate);
        }

        _shareClasses[token] = ShareClassInfo({
            companyId: p.companyId,
            shareClass: p.shareClass,
            ruleEngine: engine,
            valuationOracle: oracle,
            poolGate: gate
        });
        _shareTokens[p.companyId].push(token);
        shareTokenOf[p.companyId][p.shareClass] = token;

        emit ShareClassDeployed(p.companyId, p.shareClass, token, engine, oracle);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Read-only lookups
    // ---------------------------------------------------------------------------------------------------------------

    function companyContracts(bytes32 companyId) external view returns (CompanyContracts memory) {
        return _companies[companyId];
    }

    function companyRoles(bytes32 companyId) external view returns (CompanyRoles memory) {
        return _roles[companyId];
    }

    function shareClassOf(address token) external view returns (ShareClassInfo memory) {
        return _shareClasses[token];
    }

    function shareTokens(bytes32 companyId) external view returns (address[] memory) {
        return _shareTokens[companyId];
    }

    function companyIds() external view returns (bytes32[] memory) {
        return _companyIds;
    }

    function defaultVerifiers() external view returns (address[] memory, bytes32[][] memory) {
        return (_defaultVerifiers, _defaultTopics);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Private deployment helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _deployToken(ShareClassParams calldata p, CompanyContracts memory c, CompanyRoles memory r, address engine)
        private
        returns (address)
    {
        address[] memory minters = new address[](1);
        minters[0] = c.offeringVault;
        address[] memory agents = new address[](1);
        agents[0] = c.liquidityWindow;

        SelcierShareToken.InitParams memory init = SelcierShareToken.InitParams({
            name: p.name,
            symbol: p.symbol,
            companyId: p.companyId,
            shareClass: p.shareClass,
            documentsRoot: p.documentsRoot,
            identityRegistry: c.identityRegistry,
            ruleEngine: engine,
            admin: c.issuerTimelock,
            issuerAdmin: r.issuerAdmin,
            registrar: r.registrar,
            operator: r.operator,
            minters: minters,
            agents: agents
        });
        return
            address(new ERC1967Proxy(implementations.shareToken, abi.encodeCall(SelcierShareToken.initialize, (init))));
    }

    function _deployModules(ModuleInit[] calldata inits, address engine, address token)
        private
        returns (address[] memory modules, bytes[] memory configs)
    {
        modules = new address[](inits.length);
        configs = new bytes[](inits.length);
        for (uint256 i; i < inits.length; ++i) {
            address impl = moduleImplementation[inits[i].moduleId];
            if (impl == address(0)) revert UnknownModule(inits[i].moduleId);
            modules[i] = Clones.clone(impl);
            BaseModule(modules[i]).initialize(engine, token);
            configs[i] = inits[i].config;
        }
    }
}
