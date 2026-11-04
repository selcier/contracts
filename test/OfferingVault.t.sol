// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {OfferingVault} from "../src/markets/OfferingVault.sol";
import {ValuationOracle} from "../src/shareholder/ValuationOracle.sol";
import {ISelcierShareToken} from "../src/api/ISelcierShareToken.sol";
import {ReasonCodes} from "../src/shared/ReasonCodes.sol";
import {Topics} from "../src/shared/Topics.sol";

contract OfferingVaultTest is Base {
    SelcierShareToken internal token;
    uint256 internal constant PRICE = 25e6; // 25e6 is 25 USDG a share at 6 decimals

    function setUp() public override {
        super.setUp();
        token = _plainClass("SERIES_B");
        _verify(alice);
        _verify(bob);
        _verify(carol);
        _fund(alice, _usdg(1_000_000), address(offerings));
        _fund(bob, _usdg(1_000_000), address(offerings));
        _fund(carol, _usdg(1_000_000), address(offerings));
        _fund(dave, _usdg(1_000_000), address(offerings));
    }

    function _create(uint256 minRaise, uint256 maxRaise) internal returns (uint256 id) {
        bytes32[] memory claims = new bytes32[](1);
        claims[0] = Topics.INVESTOR_ELIGIBLE;
        vm.prank(issuerAdmin);
        id = offerings.createOffering(
            OfferingVault.OfferingParams({
                shareToken: address(token),
                pricePerShare: PRICE,
                minRaise: minRaise,
                maxRaise: maxRaise,
                minTicket: _usdg(1_000),
                opensAt: uint64(T0),
                closesAt: uint64(T0 + 14 days),
                stablecoin: address(usdg),
                requiredClaims: claims,
                treasury: treasury,
                documentId: 1
            })
        );
    }

    function _sub(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        offerings.subscribe(id, amount);
    }

    function test_SuccessfulOffering() public {
        uint256 id = _create(_usdg(100_000), _usdg(500_000));
        _sub(alice, id, _usdg(100_000));
        _sub(bob, id, _usdg(50_000));

        vm.warp(T0 + 14 days);
        offerings.close(id);

        assertEq(token.balanceOf(alice), _shares(4_000));
        assertEq(token.balanceOf(bob), _shares(2_000));
        assertEq(usdg.balanceOf(feeRecipient), _usdg(1_500)); // 1,500 is the 1% offering fee on 150,000 raised
        assertEq(usdg.balanceOf(treasury), _usdg(148_500));
        assertEq(uint8(offerings.state(id)), uint8(OfferingVault.State.CLOSED));

        ValuationOracle oracle = ValuationOracle(factory.shareClassOf(address(token)).valuationOracle);
        (int256 price, uint8 source,,) = oracle.latestValuation();
        assertEq(price, 25e8);
        assertEq(source, 0); // Source.PRICED_ROUND
    }

    function test_OversubscribedIsProRata() public {
        uint256 id = _create(_usdg(10_000), _usdg(100_000));
        _sub(alice, id, _usdg(150_000));
        _sub(bob, id, _usdg(50_000));
        vm.warp(T0 + 14 days);
        offerings.close(id);

        // Demand of 200,000 against a 100,000 cap scales each subscriber down by half.
        assertEq(token.balanceOf(alice), _shares(3_000));
        assertEq(token.balanceOf(bob), _shares(1_000));
        assertEq(offerings.refundableOf(id, alice), _usdg(75_000));

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        offerings.refund(id);
        assertEq(usdg.balanceOf(alice) - before, _usdg(75_000));
    }

    function test_FailedOfferingRefundsInFull() public {
        uint256 id = _create(_usdg(500_000), _usdg(1_000_000));
        _sub(alice, id, _usdg(20_000));
        vm.warp(T0 + 14 days);
        offerings.close(id);
        assertEq(uint8(offerings.state(id)), uint8(OfferingVault.State.FAILED));
        assertEq(token.totalSupply(), 0);

        vm.prank(alice);
        offerings.refund(id);
        assertEq(usdg.balanceOf(alice), _usdg(1_000_000));
        vm.prank(alice);
        vm.expectRevert(OfferingVault.NothingToRefund.selector);
        offerings.refund(id);
    }

    function test_SubscriberWhoStopsPassingIsRefunded() public {
        uint256 id = _create(_usdg(10_000), _usdg(500_000));
        _sub(alice, id, _usdg(20_000));
        _sub(bob, id, _usdg(20_000));
        vm.prank(operator);
        registry.removeIdentity(bob);
        vm.warp(T0 + 14 days);
        offerings.close(id);
        assertEq(token.balanceOf(bob), 0);
        assertEq(offerings.refundableOf(id, bob), _usdg(20_000));
        assertEq(usdg.balanceOf(treasury), _usdg(19_800));
    }

    function test_Guards() public {
        uint256 id = _create(_usdg(10_000), _usdg(500_000));
        vm.prank(dave); // dave was never verified, so he holds no eligibility claim
        vm.expectRevert(abi.encodeWithSelector(OfferingVault.MissingClaim.selector, Topics.INVESTOR_ELIGIBLE));
        offerings.subscribe(id, _usdg(5_000));

        vm.prank(alice);
        vm.expectRevert(OfferingVault.BelowMinimumTicket.selector);
        offerings.subscribe(id, _usdg(500));

        vm.expectRevert(OfferingVault.CannotClose.selector);
        offerings.close(id);

        vm.warp(T0 + 14 days);
        vm.prank(alice);
        vm.expectRevert(OfferingVault.NotOpen.selector);
        offerings.subscribe(id, _usdg(5_000));
    }

    function test_EarlyCloseOnceMaxReached() public {
        uint256 id = _create(_usdg(10_000), _usdg(50_000));
        _sub(alice, id, _usdg(50_000));
        vm.prank(issuerAdmin);
        offerings.close(id);
        assertEq(token.balanceOf(alice), _shares(2_000));
    }

    function test_CancelledOfferingRefunds() public {
        uint256 id = _create(_usdg(10_000), _usdg(50_000));
        _sub(alice, id, _usdg(10_000));
        vm.prank(issuerAdmin);
        offerings.cancelOffering(id);
        vm.prank(alice);
        offerings.refund(id);
        assertEq(usdg.balanceOf(alice), _usdg(1_000_000));
    }

    function test_RejectsOtherCompanyTokens() public {
        vm.prank(issuerAdmin);
        vm.expectRevert(OfferingVault.NotCompanyToken.selector);
        offerings.createOffering(
            OfferingVault.OfferingParams({
                shareToken: address(usdg),
                pricePerShare: PRICE,
                minRaise: 0,
                maxRaise: 1,
                minTicket: 0,
                opensAt: uint64(T0),
                closesAt: uint64(T0 + 1 days),
                stablecoin: address(usdg),
                requiredClaims: new bytes32[](0),
                treasury: treasury,
                documentId: 0
            })
        );
    }

    function test_RejectsBadParams() public {
        OfferingVault.OfferingParams memory p = OfferingVault.OfferingParams({
            shareToken: address(token),
            pricePerShare: PRICE,
            minRaise: 0,
            maxRaise: _usdg(10_000),
            minTicket: _usdg(20_000),
            opensAt: uint64(T0),
            closesAt: uint64(T0 + 1 days),
            stablecoin: address(usdg),
            requiredClaims: new bytes32[](0),
            treasury: treasury,
            documentId: 0
        });
        vm.prank(issuerAdmin);
        vm.expectRevert(OfferingVault.InvalidParams.selector);
        offerings.createOffering(p);

        p.minTicket = 0;
        p.requiredClaims = new bytes32[](offerings.MAX_REQUIRED_CLAIMS() + 1);
        vm.prank(issuerAdmin);
        vm.expectRevert(OfferingVault.InvalidParams.selector);
        offerings.createOffering(p);
    }

    function test_UnknownOffering() public {
        vm.expectRevert(OfferingVault.UnknownOffering.selector);
        offerings.state(0);
        vm.prank(alice);
        vm.expectRevert(OfferingVault.UnknownOffering.selector);
        offerings.subscribe(0, _usdg(1_000));
        vm.expectRevert(OfferingVault.UnknownOffering.selector);
        offerings.close(0);
    }
}
