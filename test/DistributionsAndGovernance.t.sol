// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {DistributionVault} from "../src/shareholder/DistributionVault.sol";
import {Governance} from "../src/shareholder/Governance.sol";

contract DistributionsAndGovernanceTest is Base {
    SelcierShareToken internal common;
    SelcierShareToken internal preferred;
    uint48 internal snapshot;

    function setUp() public override {
        super.setUp();
        common = _plainClass("COMMON");
        preferred = _plainClass("PREFERRED");
        _verify(alice);
        _verify(bob);
        _verify(carol);
        _verify(treasury);
        _mint(common, alice, _shares(600));
        _mint(common, bob, _shares(300));
        _mint(common, treasury, _shares(100));
        _mint(preferred, carol, _shares(500));
        snapshot = common.clock(); // the clock reads block 1000 here
        vm.roll(1_010);
        // Entitlements are fixed at the record block, so this later transfer has no effect on them.
        vm.prank(alice);
        common.transfer(bob, _shares(600));
        vm.roll(1_011);
    }

    // Funding and claiming distributions

    function _distribute(uint256 amount, uint64 deadline) internal returns (uint256 id) {
        _fund(issuerAdmin, amount, address(distributions));
        address[] memory excluded = new address[](1);
        excluded[0] = treasury;
        vm.prank(issuerAdmin);
        id = distributions.fund(address(common), address(usdg), amount, snapshot, deadline, excluded);
    }

    function test_ProRataAtRecordBlock() public {
        uint256 id = _distribute(_usdg(9_000), 0);
        assertEq(distributions.claimable(id, alice), _usdg(6_000));
        assertEq(distributions.claimable(id, bob), _usdg(3_000));
        assertEq(distributions.claimable(id, treasury), 0);

        vm.prank(alice);
        distributions.claim(id);
        distributions.claimFor(id, bob); // bob's share needs no action from bob; a relayer collects it for him
        assertEq(usdg.balanceOf(alice), _usdg(6_000));
        assertEq(usdg.balanceOf(bob), _usdg(3_000));

        vm.prank(alice);
        vm.expectRevert(DistributionVault.NothingToClaim.selector);
        distributions.claim(id);
    }

    function test_DeadlineAndSweep() public {
        vm.prank(issuerAdmin);
        vm.expectRevert(DistributionVault.InvalidParams.selector);
        distributions.fund(address(common), address(usdg), 1, snapshot, uint64(T0 + 30 days), new address[](0));

        uint256 id = _distribute(_usdg(9_000), uint64(T0 + 400 days));
        vm.prank(alice);
        distributions.claim(id);
        vm.warp(T0 + 400 days);
        assertEq(distributions.claimable(id, bob), 0);
        vm.prank(bob);
        vm.expectRevert(DistributionVault.DeadlinePassed.selector);
        distributions.claim(id);
        vm.prank(issuerAdmin);
        distributions.sweep(id);
        assertEq(usdg.balanceOf(treasury), _usdg(3_000));
    }

    function test_ClaimMany() public {
        uint256 first = _distribute(_usdg(9_000), 0);
        uint256 second = _distribute(_usdg(3_000), 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        vm.prank(alice);
        distributions.claimMany(ids);
        assertEq(usdg.balanceOf(alice), _usdg(8_000));
        assertTrue(distributions.hasClaimed(second, alice));
    }

    function test_UnknownDistribution() public {
        vm.expectRevert(DistributionVault.UnknownDistribution.selector);
        distributions.claimable(0, alice);
        vm.prank(alice);
        vm.expectRevert(DistributionVault.UnknownDistribution.selector);
        distributions.claim(0);
    }

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(address(distributions));
        emit DistributionVault.TreasuryUpdated(newTreasury);
        vm.prank(address(timelock));
        distributions.setTreasury(newTreasury);
        assertEq(distributions.treasury(), newTreasury);

        vm.prank(address(timelock));
        vm.expectRevert(DistributionVault.InvalidParams.selector);
        distributions.setTreasury(address(0));
    }

    function test_RecordBlockMustBeInThePast() public {
        uint48 future = common.clock();
        vm.prank(issuerAdmin);
        vm.expectRevert(DistributionVault.InvalidParams.selector);
        distributions.fund(address(common), address(usdg), 1, future, 0, new address[](0));
    }

    // Proposals and voting

    function _propose(uint16 quorumBps) internal returns (uint256 id) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(common);
        tokens[1] = address(preferred);
        vm.prank(issuerAdmin);
        id = governance.propose(
            Governance.ProposalParams({
                shareTokens: tokens,
                snapshotBlock: snapshot,
                endsAt: uint64(T0 + 7 days),
                quorumBps: quorumBps,
                options: 2,
                binding: true,
                documentHash: keccak256("proposal")
            })
        );
    }

    function test_UnknownProposal() public {
        vm.prank(alice);
        vm.expectRevert(Governance.UnknownProposal.selector);
        governance.castVote(0, 1);
        vm.expectRevert(Governance.UnknownProposal.selector);
        governance.finalize(0);
        vm.expectRevert(Governance.UnknownProposal.selector);
        governance.weightOf(0, alice);
    }

    function test_VoteAcrossClasses() public {
        uint256 id = _propose(5_000);
        vm.prank(alice);
        governance.castVote(id, 1); // alice's 600 common
        vm.prank(carol);
        governance.castVote(id, 0); // 500 preferred shares from carol
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Governance.AlreadyVoted.selector, alice));
        governance.castVote(id, 0);

        vm.expectRevert(Governance.VotingOpen.selector);
        governance.finalize(id);
        vm.warp(T0 + 7 days);
        governance.finalize(id);
        assertEq(governance.proposal(id).result, 1);
    }

    function test_QuorumNotMet() public {
        uint256 id = _propose(9_000);
        vm.prank(bob);
        governance.castVote(id, 0);
        vm.warp(T0 + 7 days);
        governance.finalize(id);
        assertEq(governance.proposal(id).result, governance.NO_QUORUM());
    }

    function test_DelegationIsJudgedAtSnapshot() public {
        vm.prank(bob);
        governance.delegate(carol);
        vm.roll(1_012);
        snapshot = 1_012; // at this block bob's common balance is 900
        vm.roll(1_013);

        uint256 id = _propose(0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Governance.NotDelegate.selector, bob));
        governance.castVote(id, 0);

        address[] memory delegators = new address[](1);
        delegators[0] = bob;
        vm.prank(carol);
        governance.castVoteFor(id, 1, delegators);
        vm.prank(carol);
        governance.castVote(id, 1); // carol adds her own preferred weight of 500
        assertEq(governance.proposal(id).totalWeight, _shares(1_400));

        // This proposal already took its snapshot, so undoing the delegation now has no effect on it.
        vm.prank(bob);
        governance.delegate(address(0));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Governance.AlreadyVoted.selector, bob));
        governance.castVoteFor(id, 1, delegators);
    }
}
