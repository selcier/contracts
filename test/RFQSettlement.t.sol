// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {RFQSettlement} from "../src/markets/RFQSettlement.sol";
import {ISelcierShareToken} from "../src/api/ISelcierShareToken.sol";
import {ReasonCodes} from "../src/shared/ReasonCodes.sol";

contract RFQSettlementTest is Base {
    SelcierShareToken internal token;
    address internal maker;
    uint256 internal makerKey;

    function setUp() public override {
        super.setUp();
        (maker, makerKey) = makeAddrAndKey("maker");
        token = _plainClass("COMMON");
        _verify(maker);
        _verify(bob);
        _mint(token, maker, _shares(1_000));
        _mint(token, bob, _shares(1_000));
        _fund(maker, _usdg(100_000), address(rfq));
        _fund(bob, _usdg(100_000), address(rfq));
        vm.prank(maker);
        token.approve(address(rfq), type(uint256).max);
        vm.prank(bob);
        token.approve(address(rfq), type(uint256).max);
        vm.prank(issuerAdmin);
        rfq.setEnabled(address(token), true);
    }

    function _quote(uint8 side, uint256 qty, uint256 price, uint256 nonce)
        internal
        view
        returns (RFQSettlement.Quote memory q, bytes memory sig)
    {
        q = RFQSettlement.Quote({
            maker: maker,
            shareToken: address(token),
            side: side,
            quantity: _shares(qty),
            price: price,
            stablecoin: address(usdg),
            taker: address(0),
            nonce: nonce,
            expiry: uint64(T0 + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, rfq.hashQuote(q));
        sig = abi.encodePacked(r, s, v);
    }

    function test_MakerSellsWithFees() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _quote(0, 100, 30e6, 1);
        vm.prank(bob);
        rfq.fill(q, sig, _shares(100));
        assertEq(token.balanceOf(bob), _shares(1_100));
        // Notional is 3,000 USDG, and each side pays a 0.25% fee on it.
        assertEq(usdg.balanceOf(maker), _usdg(100_000) + _usdg(3_000) - 7.5e6);
        assertEq(usdg.balanceOf(bob), _usdg(100_000) - _usdg(3_000) - 7.5e6);
        assertEq(usdg.balanceOf(feeRecipient), 15e6);
    }

    function test_MakerBuysPartialFills() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _quote(1, 100, 30e6, 1);
        vm.startPrank(bob);
        rfq.fill(q, sig, _shares(40));
        assertEq(rfq.remaining(q), _shares(60));
        rfq.fill(q, sig, _shares(60));
        assertEq(rfq.remaining(q), 0);
        vm.expectRevert(RFQSettlement.Overfill.selector);
        rfq.fill(q, sig, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(maker), _shares(1_100));
    }

    function test_CancelAndInvalidate() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 5);
        vm.prank(maker);
        rfq.cancelQuote(5);
        vm.prank(bob);
        vm.expectRevert(RFQSettlement.QuoteCancelledError.selector);
        rfq.fill(q, sig, 1);

        assertEq(rfq.remaining(q), 0);

        (q, sig) = _quote(0, 10, 30e6, 6);
        assertEq(rfq.remaining(q), _shares(10));
        vm.expectEmit(address(rfq));
        emit RFQSettlement.NoncesInvalidated(maker, 7);
        vm.prank(maker);
        rfq.invalidateNoncesBelow(7);
        assertEq(rfq.remaining(q), 0);
        vm.prank(bob);
        vm.expectRevert(RFQSettlement.QuoteCancelledError.selector);
        rfq.fill(q, sig, 1);
    }

    function test_CancelQuotesInBatch() public {
        (RFQSettlement.Quote memory a, bytes memory sigA) = _quote(0, 10, 30e6, 3);
        (RFQSettlement.Quote memory b,) = _quote(0, 10, 30e6, 4);
        (RFQSettlement.Quote memory keep,) = _quote(0, 10, 30e6, 9);
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 3;
        nonces[1] = 4;
        vm.prank(maker);
        rfq.cancelQuotes(nonces);
        assertEq(rfq.remaining(a), 0);
        assertEq(rfq.remaining(b), 0);
        assertEq(rfq.remaining(keep), _shares(10));
        vm.prank(bob);
        vm.expectRevert(RFQSettlement.QuoteCancelledError.selector);
        rfq.fill(a, sigA, 1);
    }

    function test_ExpiryAndSignature() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 1);
        q.price = 1e6; // no longer the price the maker signed
        vm.prank(bob);
        vm.expectRevert(RFQSettlement.InvalidSignature.selector);
        rfq.fill(q, sig, 1);

        (q, sig) = _quote(0, 10, 30e6, 2);
        vm.warp(T0 + 1 days);
        vm.prank(bob);
        vm.expectRevert(RFQSettlement.Expired.selector);
        rfq.fill(q, sig, 1);
    }

    function test_RulesRunOnEveryFill() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 1);
        _fund(carol, _usdg(1_000), address(rfq)); // funded with USDG, yet carol has no verified identity
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ISelcierShareToken.TransferNotAllowed.selector, ReasonCodes.RECIPIENT_NOT_VERIFIED)
        );
        rfq.fill(q, sig, _shares(1));
    }

    function test_DisabledClass() public {
        vm.prank(issuerAdmin);
        rfq.setEnabled(address(token), false);
        (RFQSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 1);
        vm.prank(bob);
        vm.expectRevert(RFQSettlement.NotEnabled.selector);
        rfq.fill(q, sig, 1);
    }
}
