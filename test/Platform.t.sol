// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {SelcierFactory} from "../src/core/SelcierFactory.sol";
import {ISelcierFactory} from "../src/api/ISelcierFactory.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {IssuerTimelock} from "../src/core/IssuerTimelock.sol";
import {DisclosureRegistry} from "../src/shareholder/DisclosureRegistry.sol";
import {ValuationOracle} from "../src/shareholder/ValuationOracle.sol";
import {PoolGate} from "../src/markets/PoolGate.sol";
import {RuleEngine} from "../src/compliance/RuleEngine.sol";
import {ReasonCodes} from "../src/shared/ReasonCodes.sol";
import {Topics} from "../src/shared/Topics.sol";

contract PlatformTest is Base {
    // Factory records, guards and events

    function test_FactoryRecordsEverything() public {
        SelcierShareToken token = _plainClass("COMMON");
        ISelcierFactory.ShareClassInfo memory info = factory.shareClassOf(address(token));
        assertEq(info.companyId, COMPANY);
        assertEq(info.ruleEngine, address(token.ruleEngine()));
        assertEq(factory.shareTokens(COMPANY).length, 1);
        assertEq(factory.shareTokenOf(COMPANY, "COMMON"), address(token));
        assertEq(factory.companyContracts(COMPANY).issuerTimelock, address(timelock));
    }

    function test_FactoryGuards() public {
        vm.expectRevert();
        factory.deployShareClass(_params("X", new SelcierFactory.ModuleInit[](0), false));

        _plainClass("COMMON");
        vm.prank(selcier);
        vm.expectRevert(SelcierFactory.ShareClassExists.selector);
        factory.deployShareClass(_params("COMMON", new SelcierFactory.ModuleInit[](0), false));

        vm.prank(selcier);
        vm.expectRevert(abi.encodeWithSelector(SelcierFactory.UnknownModule.selector, bytes32("NOPE")));
        factory.deployShareClass(_params("Y", _modules1("NOPE", ""), false));
    }

    function test_FactoryEmitsShareClassDeployed() public {
        vm.recordLogs();
        SelcierShareToken token = _plainClass("COMMON");
        bool seen;
        bytes32 sig = keccak256("ShareClassDeployed(bytes32,bytes32,address,address,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == sig) {
                (address t,,) = abi.decode(logs[i].data, (address, address, address));
                seen = t == address(token);
            }
        }
        assertTrue(seen);
    }

    // Timelock delays, thresholds and signer changes

    function test_TimelockDelaysBySelector() public view {
        assertEq(timelock.delayFor(bytes4(keccak256("upgradeToAndCall(address,bytes)"))), 7 days);
        assertEq(timelock.delayFor(RuleEngine.addModule.selector), 24 hours);
        assertEq(timelock.delayFor(bytes4(keccak256("grantRole(bytes32,address)"))), 48 hours);
    }

    function test_TimelockThresholdAndExecution() public {
        bytes memory data = abi.encodeCall(IssuerTimelock.setThreshold, (3));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "t");
        assertEq(timelock.approvalCount(id), 1);
        vm.expectRevert(IssuerTimelock.NotQueued.selector);
        timelock.execute(id);

        vm.prank(signer2);
        timelock.approve(id);
        assertEq(timelock.approvalCount(id), 2);
        assertFalse(timelock.isReady(id));
        vm.expectRevert(IssuerTimelock.TooEarly.selector);
        timelock.execute(id);
        vm.warp(T0 + 48 hours);
        assertTrue(timelock.isReady(id));
        timelock.execute(id);
        assertFalse(timelock.isReady(id));
        assertEq(timelock.threshold(), 3);
    }

    function test_RemovedSignerApprovalStopsCounting() public {
        bytes memory data = abi.encodeCall(IssuerTimelock.setDelay, (bytes4(0x12345678), 72 hours));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "d");

        _timelocked(address(timelock), abi.encodeCall(IssuerTimelock.removeSigner, (signer1)));
        vm.prank(signer2);
        timelock.approve(id); // not queued: signer1's approval is on record but stopped counting, leaving one of two
        assertEq(timelock.approvalCount(id), 1);
        vm.warp(block.timestamp + 72 hours);
        assertFalse(timelock.isReady(id));
        vm.expectRevert(IssuerTimelock.NotQueued.selector);
        timelock.execute(id);
    }

    function test_TimelockCannotGoBelowFloor() public {
        bytes memory data = abi.encodeCall(IssuerTimelock.setDelay, (RuleEngine.addModule.selector, 1 hours));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "floor");
        vm.prank(signer2);
        timelock.approve(id);
        vm.warp(T0 + 48 hours);
        vm.expectRevert();
        timelock.execute(id);

        vm.expectRevert(IssuerTimelock.OnlySelf.selector);
        timelock.addSigner(alice);
    }

    // Anchored documents and published valuations

    function test_DisclosureRegistry() public {
        bytes32 hash = sha256("board resolution v1");
        vm.prank(issuerAdmin);
        uint256 id = disclosures.anchor("BOARD_RESOLUTION", hash, "ipfs://doc");
        assertEq(id, 1);
        assertEq(disclosures.document(id).hash, hash);
        assertEq(disclosures.documentIdByHash(hash), 1);
        assertEq(disclosures.latestDocumentIdOfKind("BOARD_RESOLUTION"), 1);
        assertEq(disclosures.latestDocumentIdOfKind("COMPANY_UPDATE"), 0);

        bytes32 hash2 = sha256("board resolution v2");
        vm.prank(issuerAdmin);
        uint256 second = disclosures.anchor("BOARD_RESOLUTION", hash2, "ipfs://doc2");
        assertEq(disclosures.latestDocumentIdOfKind("BOARD_RESOLUTION"), second);

        vm.prank(issuerAdmin);
        vm.expectRevert(abi.encodeWithSelector(DisclosureRegistry.AlreadyAnchored.selector, 1));
        disclosures.anchor("COMPANY_UPDATE", hash, "ipfs://copy");

        vm.prank(issuerAdmin);
        vm.expectRevert(DisclosureRegistry.InvalidKind.selector);
        disclosures.anchor("MEME", hash, "");
        vm.prank(alice);
        vm.expectRevert();
        disclosures.anchor("COMPANY_UPDATE", hash, "");
    }

    function test_ValuationOracleAggregatorView() public {
        SelcierShareToken token = _plainClass("COMMON");
        ValuationOracle oracle = ValuationOracle(factory.shareClassOf(address(token)).valuationOracle);
        vm.expectRevert(ValuationOracle.NoData.selector);
        oracle.latestRoundData();

        vm.prank(issuerAdmin);
        oracle.publish(12.5e8, 1, uint64(T0 - 1 days), keccak256("409a"));
        (uint80 round, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(round, 1);
        assertEq(answer, 12.5e8);
        assertEq(updatedAt, T0 - 1 days);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "NWD / USD reference valuation");
        ValuationOracle.Round memory r = oracle.round(1);
        assertEq(r.source, 1);
        assertEq(r.documentHash, keccak256("409a"));
        assertEq(r.publishedAt, block.timestamp);
        vm.expectRevert(ValuationOracle.NoData.selector);
        oracle.round(2);

        vm.prank(issuerAdmin);
        vm.expectRevert(ValuationOracle.InvalidDate.selector);
        oracle.publish(11e8, 1, uint64(T0 - 2 days), 0);

        vm.prank(issuerAdmin);
        token.pause("split");
        vm.prank(issuerAdmin);
        vm.expectRevert(ValuationOracle.TokenPaused.selector);
        oracle.publish(1e8, 1, uint64(T0), 0);
    }

    // AMM pools behind PoolGate

    function test_PoolGateRequiresVenueClaimAndBlocksRofrClasses() public {
        vm.prank(selcier);
        SelcierShareToken token =
            SelcierShareToken(factory.deployShareClass(_params("POOLED", new SelcierFactory.ModuleInit[](0), true)));
        PoolGate gate = PoolGate(factory.shareClassOf(address(token)).poolGate);
        address pool = address(new PoolStub());

        vm.prank(address(timelock));
        vm.expectRevert(PoolGate.NotVenue.selector);
        gate.registerPool(pool);

        vm.prank(operator);
        registry.registerIdentity(pool, pool);
        _addClaim(pool, Topics.VENUE, abi.encode(address(token)));
        assertTrue(token.isAgent(pool));
        vm.prank(address(timelock));
        gate.registerPool(pool);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGate.PoolAlreadyRegistered.selector);
        gate.registerPool(pool);

        _verify(alice);
        _mint(token, pool, _shares(10)); // agent status, from the VENUE claim, is what lets a pool hold inventory
        assertEq(gate.checkSwap(pool, alice, 1), ReasonCodes.OK);
        assertEq(gate.checkSwap(pool, bob, 1), ReasonCodes.RECIPIENT_NOT_VERIFIED);
        vm.prank(pool);
        vm.expectRevert();
        gate.beforeAddLiquidity(bob);

        vm.prank(address(timelock));
        gate.removePool(pool);
        assertEq(gate.checkSwap(pool, alice, 1), ReasonCodes.NOT_ELIGIBLE);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGate.UnknownPool.selector);
        gate.removePool(pool);

        address[] memory venues = new address[](0);
        vm.prank(selcier);
        SelcierShareToken rofrToken = SelcierShareToken(
            factory.deployShareClass(_params("ROFR", _modules1("ROFR", abi.encode(treasury, uint32(1), venues)), true))
        );
        PoolGate rofrGate = PoolGate(factory.shareClassOf(address(rofrToken)).poolGate);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGate.ROFRIncompatible.selector);
        rofrGate.registerPool(pool);
    }

    function _params(bytes32 cls, SelcierFactory.ModuleInit[] memory modules, bool pools)
        internal
        pure
        returns (SelcierFactory.ShareClassParams memory)
    {
        return SelcierFactory.ShareClassParams({
            companyId: COMPANY,
            shareClass: cls,
            name: "Larkway",
            symbol: "NWD",
            documentsRoot: bytes32(0),
            modules: modules,
            enablePools: pools
        });
    }
}

contract PoolStub {}

import {Vm} from "forge-std/Vm.sol";
