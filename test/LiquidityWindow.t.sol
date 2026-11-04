// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {LiquidityWindow} from "../src/markets/LiquidityWindow.sol";
import {ValuationOracle} from "../src/shareholder/ValuationOracle.sol";

contract LiquidityWindowTest is Base {
    SelcierShareToken internal token;
    ValuationOracle internal oracle;

    address internal sellerA = makeAddr("sellerA");
    address internal sellerB = makeAddr("sellerB");
    address internal sellerC = makeAddr("sellerC");
    address internal sellerD = makeAddr("sellerD");
    address internal buyerX = makeAddr("buyerX");
    address internal buyerY = makeAddr("buyerY");
    address internal buyerZ = makeAddr("buyerZ");

    function setUp() public override {
        super.setUp();
        // The documented figures assume a fee-free window, so both rates go to zero and the assertions can reuse them.
        vm.prank(address(timelock));
        windows.setFees(address(0), 0, 0);

        token = _plainClass("SERIES_B");
        oracle = ValuationOracle(factory.shareClassOf(address(token)).valuationOracle);
        address[7] memory people = [sellerA, sellerB, sellerC, sellerD, buyerX, buyerY, buyerZ];
        for (uint256 i; i < people.length; ++i) {
            _verify(people[i]);
            _fund(people[i], _usdg(1_000_000), address(windows));
            vm.prank(people[i]);
            token.approve(address(windows), type(uint256).max);
        }
        _mint(token, sellerA, _shares(4_000));
        _mint(token, sellerB, _shares(3_000));
        _mint(token, sellerC, _shares(5_000));
        _mint(token, sellerD, _shares(2_000));
    }

    function _open(uint8 mode, uint256 reserve, uint256 tenderPrice, address rofrHolder, uint32 rofrPeriod)
        internal
        returns (uint256 id)
    {
        vm.prank(issuerAdmin);
        id = windows.openWindow(
            LiquidityWindow.WindowParams({
                shareToken: address(token),
                mode: mode,
                opensAt: uint64(T0),
                closesAt: uint64(T0 + 7 days),
                stablecoin: address(usdg),
                reservePrice: reserve,
                tenderPrice: tenderPrice,
                maxVolume: 0,
                perSellerCap: 0,
                rofrHolder: rofrHolder,
                rofrPeriod: rofrPeriod,
                sellerClaims: new bytes32[](0),
                buyerClaims: new bytes32[](0)
            })
        );
    }

    function _order(address who, uint256 id, uint8 side, uint256 qty, uint256 price) internal returns (uint256) {
        vm.prank(who);
        return windows.placeOrder(id, side, _shares(qty), price);
    }

    function _documentedBook(uint256 id) internal {
        _order(sellerA, id, 0, 4_000, 18e6);
        _order(sellerB, id, 0, 3_000, 20e6);
        _order(sellerC, id, 0, 5_000, 22e6);
        _order(sellerD, id, 0, 2_000, 25e6);
        _order(buyerX, id, 1, 6_000, 24e6);
        _order(buyerY, id, 1, 4_000, 21e6);
        _order(buyerZ, id, 1, 3_000, 19e6);
    }

    /// Reproduces the auction walked through step by step in docs/markets/scheduled-windows.md.
    function test_DocumentedAuctionExample() public {
        vm.prank(issuerAdmin);
        oracle.publish(20.4e8, 1, uint64(T0), bytes32(0));

        uint256 id = _open(0, 0, 0, address(0), 0);
        _documentedBook(id);

        (uint256 price, uint256 volume) = windows.previewClearing(id);
        assertEq(price, 20.4e6);
        assertEq(volume, _shares(7_000));

        vm.warp(T0 + 7 days);
        windows.clear(id);

        assertEq(token.balanceOf(buyerX), _shares(6_000));
        assertEq(token.balanceOf(buyerY), _shares(1_000));
        assertEq(token.balanceOf(buyerZ), 0);
        assertEq(token.balanceOf(sellerC), _shares(5_000));
        assertEq(token.balanceOf(sellerD), _shares(2_000));
        assertEq(usdg.balanceOf(sellerA), _usdg(1_000_000) + 81_600e6);
        assertEq(usdg.balanceOf(sellerB), _usdg(1_000_000) + 61_200e6);
        assertEq(usdg.balanceOf(buyerX), _usdg(1_000_000) - 122_400e6);
        assertEq(usdg.balanceOf(buyerY), _usdg(1_000_000) - 20_400e6);
        assertEq(usdg.balanceOf(buyerZ), _usdg(1_000_000));
        assertEq(usdg.balanceOf(address(windows)), 0);
        assertEq(token.balanceOf(address(windows)), 0);

        (int256 published, uint8 source,,) = oracle.latestValuation();
        assertEq(published, 20.4e8);
        assertEq(source, 2); // Source.WINDOW_CLEARING
    }

    function test_NoReferenceUsesMidpointAndReserveRaisesPrice() public {
        uint256 id = _open(0, 0, 0, address(0), 0);
        _documentedBook(id);
        (uint256 price,) = windows.previewClearing(id);
        assertEq(price, 21e6); // 21 sits halfway between ask 18 and bid 24, and within the max-volume range

        uint256 id2 = _open(0, 23e6, 0, address(0), 0);
        _mint(token, sellerA, _shares(100));
        _order(sellerA, id2, 0, 100, 18e6);
        _order(buyerX, id2, 1, 100, 24e6);
        (price,) = windows.previewClearing(id2);
        assertEq(price, 23e6);
    }

    function test_TenderIsProRata() public {
        uint256 id = _open(1, 0, 20e6, address(0), 0);
        _order(sellerA, id, 0, 3_000, 0);
        _order(sellerB, id, 0, 1_000, 0);
        _order(buyerX, id, 1, 2_000, 0);
        vm.warp(T0 + 7 days);
        windows.clear(id);
        assertEq(token.balanceOf(buyerX), _shares(2_000));
        assertEq(token.balanceOf(sellerA), _shares(4_000 - 1_500));
        assertEq(token.balanceOf(sellerB), _shares(3_000 - 500));
    }

    function test_CancelOrderAndWindow() public {
        uint256 id = _open(0, 0, 0, address(0), 0);
        uint256 o = _order(sellerA, id, 0, 1_000, 18e6);
        _order(buyerX, id, 1, 1_000, 24e6);
        assertEq(token.balanceOf(sellerA), _shares(3_000));

        vm.prank(sellerA);
        windows.cancelOrder(id, o);
        assertEq(token.balanceOf(sellerA), _shares(4_000));

        vm.prank(issuerAdmin);
        windows.cancelWindow(id);
        assertEq(usdg.balanceOf(buyerX), _usdg(1_000_000));
        vm.prank(buyerX);
        vm.expectRevert(LiquidityWindow.NotOpen.selector);
        windows.placeOrder(id, 1, 1, 1);
    }

    function test_RofrIsFilledFirst() public {
        _verify(treasury);
        _fund(treasury, _usdg(1_000_000), address(windows));
        uint256 id = _open(0, 0, 0, treasury, 2 days);
        _order(sellerA, id, 0, 1_000, 20e6);
        _order(buyerX, id, 1, 1_000, 20e6);

        vm.warp(T0 + 7 days);
        vm.expectRevert(LiquidityWindow.TooEarly.selector);
        windows.clear(id);

        vm.prank(treasury);
        windows.exerciseRofr(id, _shares(600));
        vm.warp(T0 + 9 days);
        windows.clear(id);

        assertEq(token.balanceOf(treasury), _shares(600));
        assertEq(token.balanceOf(buyerX), _shares(400));
        assertEq(usdg.balanceOf(buyerX), _usdg(1_000_000) - _usdg(8_000));
    }

    function test_FailedDeliveryIsDeferredNotReverted() public {
        uint256 id = _open(0, 0, 0, address(0), 0);
        _order(sellerA, id, 0, 1_000, 30e6); // priced too high to fill, so the tokens have to go back
        _order(sellerB, id, 0, 1_000, 18e6);
        _order(buyerX, id, 1, 1_000, 24e6);
        vm.prank(operator);
        registry.removeIdentity(sellerA); // with no identity left, returned tokens cannot reach sellerA

        vm.warp(T0 + 7 days);
        windows.clear(id);
        assertEq(token.balanceOf(buyerX), _shares(1_000));
        assertEq(windows.deferredTokens(address(token), sellerA), _shares(1_000));

        _verify(sellerA);
        vm.prank(sellerA);
        windows.claimDeferred(address(token));
        assertEq(token.balanceOf(sellerA), _shares(4_000));
    }

    function test_FeesAndDustGoToRecipient() public {
        vm.prank(address(timelock));
        windows.setFees(feeRecipient, 25, 25);
        uint256 id = _open(0, 0, 0, address(0), 0);
        _order(sellerA, id, 0, 1_000, 20e6);
        _order(buyerX, id, 1, 1_000, 20e6);
        vm.warp(T0 + 7 days);
        windows.clear(id);
        assertEq(usdg.balanceOf(sellerA), _usdg(1_000_000) + _usdg(20_000) - _usdg(50));
        assertEq(usdg.balanceOf(buyerX), _usdg(1_000_000) - _usdg(20_000) - _usdg(50));
        assertEq(usdg.balanceOf(feeRecipient), _usdg(100));
        assertEq(usdg.balanceOf(address(windows)), 0);
    }
}
