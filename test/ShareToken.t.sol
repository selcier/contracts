// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {ISelcierShareToken, IERC8056} from "../src/api/ISelcierShareToken.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {TrustedVerifiers} from "../src/identity/TrustedVerifiers.sol";
import {ReasonCodes} from "../src/shared/ReasonCodes.sol";
import {Topics} from "../src/shared/Topics.sol";
import {Roles} from "../src/shared/Roles.sol";

contract ShareTokenTest is Base {
    SelcierShareToken internal token;

    function setUp() public override {
        super.setUp();
        token = _plainClass("COMMON");
        _verify(alice);
        _verify(bob);
        _mint(token, alice, _shares(1_000));
    }

    function test_Metadata() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.companyId(), COMPANY);
        assertEq(token.shareClass(), bytes32("COMMON"));
        assertEq(token.uiMultiplier(), 1e18);
        assertEq(address(token.identityRegistry()), address(registry));
        assertEq(token.compliance(), address(token.ruleEngine()));
    }

    function test_MintRequiresVerifiedRecipient() public {
        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(ISelcierShareToken.TransferNotAllowed.selector, ReasonCodes.RECIPIENT_NOT_VERIFIED)
        );
        token.mint(carol, 1e18, "x");
    }

    function test_OnlyRegistrarOrMinterMints() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1e18, "x");
    }

    function test_TransferBetweenVerifiedHolders() public {
        vm.prank(alice);
        token.transfer(bob, _shares(100));
        assertEq(token.balanceOf(bob), _shares(100));
        assertEq(token.balanceOf(alice), _shares(900));
    }

    function test_ReasonCodes() public {
        (bool ok, bytes32 code) = token.canTransfer(alice, carol, 1);
        assertFalse(ok);
        assertEq(code, ReasonCodes.RECIPIENT_NOT_VERIFIED);

        (, code) = token.canTransfer(alice, bob, _shares(2_000));
        assertEq(code, ReasonCodes.INSUFFICIENT_UNLOCKED_BALANCE);

        vm.prank(operator);
        registry.removeIdentity(alice);
        (, code) = token.canTransfer(alice, bob, 1);
        assertEq(code, ReasonCodes.SENDER_NOT_VERIFIED);

        vm.prank(operator);
        vm.expectRevert(IdentityRegistry.UnknownIdentity.selector);
        registry.removeIdentity(alice);
    }

    function test_ExpiredClaimReportsClaimExpired() public {
        vm.warp(T0 + CLAIM_TTL + 1);
        (, bytes32 code) = token.canTransfer(alice, bob, 1);
        assertEq(code, ReasonCodes.CLAIM_EXPIRED);
    }

    function test_RemovedVerifierInvalidatesClaims() public {
        _timelocked(c.trustedVerifiers, abi.encodeWithSignature("removeVerifier(address)", verifier));
        (, bytes32 code) = token.canTransfer(alice, bob, 1);
        assertEq(code, ReasonCodes.CLAIM_EXPIRED);

        vm.prank(address(timelock));
        vm.expectRevert(TrustedVerifiers.UnknownVerifier.selector);
        TrustedVerifiers(c.trustedVerifiers).removeVerifier(verifier);
    }

    function test_PauseBlocksEveryTransfer() public {
        vm.prank(issuerAdmin);
        token.pause("incident");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ISelcierShareToken.TransferNotAllowed.selector, ReasonCodes.TOKEN_PAUSED)
        );
        token.transfer(bob, 1);

        vm.prank(registrar);
        token.unpause();
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_FreezePartial() public {
        vm.prank(registrar);
        token.freezePartial(alice, _shares(600), "dispute");
        assertEq(token.getFrozenTokens(alice), _shares(600));
        assertEq(token.unlockedBalanceOf(alice), _shares(400));

        (, bytes32 code) = token.canTransfer(alice, bob, _shares(500));
        assertEq(code, ReasonCodes.FROZEN);
        vm.prank(alice);
        token.transfer(bob, _shares(400));

        vm.prank(registrar);
        token.unfreezePartial(alice, _shares(600));
        assertEq(token.unlockedBalanceOf(alice), _shares(600));
    }

    function test_BurnClampsFrozen() public {
        vm.startPrank(registrar);
        token.freezePartial(alice, _shares(600), "x");
        token.burn(alice, _shares(900), "redeem");
        vm.stopPrank();
        assertEq(token.getFrozenTokens(alice), _shares(100));
        assertEq(token.totalSupply(), _shares(100));
    }

    function test_MultiplierSchedule() public {
        uint64 at = uint64(block.timestamp + 48 hours);
        vm.prank(issuerAdmin);
        vm.expectRevert(SelcierShareToken.MultiplierTooSoon.selector);
        token.scheduleMultiplier(2e18, at - 1);

        vm.prank(issuerAdmin);
        token.scheduleMultiplier(2e18, at);
        assertEq(token.uiMultiplier(), 1e18);

        vm.warp(at);
        assertEq(token.uiMultiplier(), 2e18);
        vm.expectEmit(address(token));
        emit IERC8056.UIMultiplierUpdated(1e18, 2e18);
        token.applyMultiplier();
        // The multiplier is display-only: stored balances stay exactly as they were.
        assertEq(token.balanceOf(alice), _shares(1_000));
    }

    function test_RecoveryNeedsTwoPartiesAndTimelock() public {
        address replacement = makeAddr("replacement");
        _verify(replacement);

        vm.prank(issuerAdmin);
        token.approveRecovery(alice, replacement, "lost-key");
        vm.prank(issuerAdmin);
        vm.expectRevert(SelcierShareToken.AlreadyApproved.selector);
        token.approveRecovery(alice, replacement, "lost-key");
        assertFalse(token.isFrozen(alice));

        vm.prank(operator);
        token.approveRecovery(alice, replacement, "lost-key");
        assertTrue(token.isFrozen(alice));

        (, bytes32 code) = token.canTransfer(alice, bob, 1);
        assertEq(code, ReasonCodes.FROZEN);

        vm.prank(registrar);
        vm.expectRevert(SelcierShareToken.RecoveryNotReady.selector);
        token.recover(alice, replacement, "lost-key");

        vm.warp(T0 + 72 hours);
        vm.prank(registrar);
        token.recover(alice, replacement, "lost-key");
        assertEq(token.balanceOf(replacement), _shares(1_000));
        assertEq(token.balanceOf(alice), 0);
        assertFalse(token.isFrozen(alice));
    }

    function test_RecoveryCanBeCancelled() public {
        address replacement = makeAddr("replacement");
        _verify(replacement);
        vm.prank(issuerAdmin);
        token.approveRecovery(alice, replacement, "r");
        vm.prank(registrar);
        token.approveRecovery(alice, replacement, "r");
        vm.prank(operator);
        token.cancelRecovery(alice);
        assertFalse(token.isFrozen(alice));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_OnlyTimelockUpgrades() public {
        address next = address(new SelcierShareToken());
        vm.prank(issuerAdmin);
        vm.expectRevert();
        token.upgradeToAndCall(next, "");

        bytes32 salt = "upgrade";
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", next, "");
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(token), 0, data, salt);
        vm.prank(signer3);
        timelock.approve(id);
        assertEq(timelock.action(id).eta, T0 + 7 days);
        vm.warp(T0 + 7 days);
        timelock.execute(id);
        assertEq(token.balanceOf(alice), _shares(1_000));
    }

    function test_Checkpoints() public {
        uint48 before = token.clock();
        vm.roll(block.number + 5);
        vm.prank(alice);
        token.transfer(bob, _shares(250));
        vm.roll(block.number + 1);
        assertEq(token.balanceOfAt(alice, before), _shares(1_000));
        assertEq(token.balanceOfAt(bob, before), 0);
        assertEq(token.balanceOfAt(bob, token.clock() - 1), _shares(250));
        assertEq(token.totalSupplyAt(before), _shares(1_000));
    }

    function test_SignedClaimsAreRelayableOnce() public {
        vm.prank(operator);
        registry.registerIdentity(carol, carol);
        uint64 expiry = uint64(block.timestamp + 30 days);
        bytes32 digest = registry.claimDigest(carol, Topics.IDENTITY_VERIFIED, "", expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(dave); // relaying a signed claim needs no special role
        registry.addClaim(carol, Topics.IDENTITY_VERIFIED, "", expiry, verifier, sig);
        assertEq(registry.claimOf(carol, Topics.IDENTITY_VERIFIED).verifier, verifier);

        vm.prank(verifier);
        registry.revokeClaim(carol, Topics.IDENTITY_VERIFIED);
        vm.prank(operator);
        vm.expectRevert(IdentityRegistry.NoClaim.selector);
        registry.revokeClaim(carol, Topics.IDENTITY_VERIFIED);
        vm.expectRevert(IdentityRegistry.SignatureUsed.selector);
        registry.addClaim(carol, Topics.IDENTITY_VERIFIED, "", expiry, verifier, sig);
    }

    function test_UntrustedVerifierRejected() public {
        address rogue = makeAddr("rogue");
        vm.prank(rogue);
        vm.expectRevert(IdentityRegistry.UntrustedVerifier.selector);
        registry.addClaim(carol, Topics.IDENTITY_VERIFIED, "", uint64(block.timestamp + 1 days), rogue, "");
    }

    function test_RolesAssignedByFactory() public view {
        assertTrue(token.hasRole(0x00, address(timelock)));
        assertTrue(token.hasRole(Roles.REGISTRAR, registrar));
        assertTrue(token.hasRole(Roles.MINTER, address(offerings)));
        assertTrue(token.hasRole(Roles.PAUSER, issuerAdmin));
        assertFalse(token.hasRole(0x00, address(factory)));
        assertTrue(token.isAgent(address(windows)));
    }
}
