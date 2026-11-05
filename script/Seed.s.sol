// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SelcierFactory} from "../src/core/SelcierFactory.sol";
import {SelcierShareToken} from "../src/core/SelcierShareToken.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {OfferingVault} from "../src/markets/OfferingVault.sol";
import {LiquidityWindow} from "../src/markets/LiquidityWindow.sol";
import {RFQSettlement} from "../src/markets/RFQSettlement.sol";
import {DistributionVault} from "../src/shareholder/DistributionVault.sol";
import {Governance} from "../src/shareholder/Governance.sol";
import {DisclosureRegistry} from "../src/shareholder/DisclosureRegistry.sol";
import {ValuationOracle} from "../src/shareholder/ValuationOracle.sol";
import {MockStablecoin} from "../src/testing/MockStablecoin.sol";
import {Topics} from "../src/shared/Topics.sol";

/// @title Demo activity generator for the Larkway Labs company
/// @notice Builds a believable on-chain history for the Larkway Labs demo company set up by Deploy.s.sol.
///         That history covers six verified investors, secondary transfers, subscriptions to two offerings, an
///         auction in a liquidity window, RFQ fills, a dividend and two shareholder votes. Windows, offerings and
///         votes settle only after their close time has passed on chain, so the work splits into three stages:
///
///           forge script script/Seed.s.sol --broadcast --slow --rpc-url robinhood_testnet --sig "open()"
///           # once SETTLE_DELAY (10 minutes) has passed
///           forge script script/Seed.s.sol --broadcast --slow --rpc-url robinhood_testnet --sig "settle()"
///           # once VOTE_PERIOD (10 minutes) has passed
///           forge script script/Seed.s.sol --broadcast --slow --rpc-url robinhood_testnet --sig "finalize()"
///
/// @dev PRIVATE_KEY is the seed for the investor keys, which means every stage, and anyone who has the deployer key,
///      can act for those investors. Their gas and test USDG come from the deployer. Investor addresses go to
///      `<chainId>.seed.json` under `deployments/`. Never run this script on mainnet: it relies on the test stablecoin.
contract Seed is Script {
    uint256 internal constant INVESTORS = 6;
    uint256 internal constant GAS_PER_INVESTOR = 0.0002 ether;
    uint64 internal constant SETTLE_DELAY = 10 minutes;
    uint64 internal constant VOTE_PERIOD = 10 minutes;
    bytes32 internal constant COMPANY = "LARKWAY_LABS";

    // Order of the investor arrays from index 0: Ava, Ben, Chen, Dana, Eli (the employee), then Fay.
    uint256 internal constant AVA = 0;
    uint256 internal constant BEN = 1;
    uint256 internal constant CHEN = 2;
    uint256 internal constant DANA = 3;
    uint256 internal constant ELI = 4;
    uint256 internal constant FAY = 5;

    uint256 internal deployerKey;
    address internal deployer;
    uint256[INVESTORS] internal keys;
    address[INVESTORS] internal investors;

    MockStablecoin internal usdg;
    SelcierShareToken internal common;
    SelcierShareToken internal seriesB;
    IdentityRegistry internal registry;
    OfferingVault internal offerings;
    LiquidityWindow internal windows;
    RFQSettlement internal rfq;
    DistributionVault internal distributions;
    Governance internal governance;
    DisclosureRegistry internal disclosures;
    SelcierFactory internal factory;

    // ---------------------------------------------------------------------------------------------------------------
    // Stage 1: onboard investors, move shares, take subscriptions, open a window and fill RFQ quotes
    // ---------------------------------------------------------------------------------------------------------------

    function open() external {
        _load();
        require(block.chainid != 4663, "Seed is testnet only");

        vm.startBroadcast(deployerKey);
        usdg.mint(deployer, 5_000_000e6);
        _onboard(AVA, "US", 2);
        _onboard(BEN, "GB", 2);
        _onboard(CHEN, "SG", 1);
        _onboard(DANA, "DE", 2);
        _onboardEmployee(ELI, "US");
        _onboard(FAY, "CA", 1);

        // The founder's imported cap table supplies these secondary transfers. Each Series B recipient ends up below
        // the 25% ownership cap.
        common.transfer(investors[AVA], 120_000e18);
        common.transfer(investors[BEN], 80_000e18);
        common.transfer(investors[CHEN], 50_000e18);
        common.transfer(investors[DANA], 60_000e18);
        common.transfer(investors[ELI], 40_000e18);
        common.transfer(investors[FAY], 30_000e18);
        seriesB.transfer(investors[AVA], 40_000e18);
        seriesB.transfer(investors[BEN], 30_000e18);
        seriesB.transfer(investors[DANA], 25_000e18);

        // Anchor the disclosure documents, then publish a 409A valuation of 8.50 USD for Common.
        disclosures.anchor(
            "FINANCIAL_STATEMENT", sha256("Larkway Labs FY2025 audited financials"), "https://selcier.xyz/demo/fy2025"
        );
        disclosures.anchor(
            "BOARD_RESOLUTION",
            sha256("Larkway Labs board: approve Q4 liquidity window"),
            "https://selcier.xyz/demo/board-q4"
        );
        disclosures.anchor(
            "VALUATION_REPORT", sha256("Larkway Labs 409A, October 2026"), "https://selcier.xyz/demo/409a"
        );
        uint256 commonOfferingDoc = disclosures.anchor(
            "OFFERING_DOCUMENT",
            sha256("Larkway Labs Common employee and friends round"),
            "https://selcier.xyz/demo/common-round"
        );
        ValuationOracle(factory.shareClassOf(address(common)).valuationOracle)
            .publish(8_50_000_000, 1, uint64(block.timestamp), sha256("Larkway Labs 409A, October 2026"));

        // Common round priced at 8 USDG per share. It runs for only SETTLE_DELAY.
        bytes32[] memory verified = new bytes32[](1);
        verified[0] = Topics.IDENTITY_VERIFIED;
        uint256 commonRound = offerings.createOffering(
            OfferingVault.OfferingParams({
                shareToken: address(common),
                pricePerShare: 8e6,
                minRaise: 20_000e6,
                maxRaise: 200_000e6,
                minTicket: 500e6,
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp) + SETTLE_DELAY,
                stablecoin: address(usdg),
                requiredClaims: verified,
                treasury: deployer,
                documentId: commonOfferingDoc
            })
        );

        // The Common auction clears at a single uniform price and also closes after SETTLE_DELAY.
        uint256 windowId = windows.openWindow(
            LiquidityWindow.WindowParams({
                shareToken: address(common),
                mode: windows.AUCTION(),
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp) + SETTLE_DELAY,
                stablecoin: address(usdg),
                reservePrice: 7e6,
                tenderPrice: 0,
                maxVolume: 0,
                perSellerCap: 50_000e18,
                rofrHolder: address(0),
                rofrPeriod: 0,
                sellerClaims: verified,
                buyerClaims: verified
            })
        );

        rfq.setEnabled(address(common), true);
        rfq.setEnabled(address(seriesB), true);
        usdg.approve(address(windows), type(uint256).max);
        vm.stopBroadcast();

        // Each investor grants its token approvals a single time.
        for (uint256 i; i < INVESTORS; ++i) {
            vm.startBroadcast(keys[i]);
            usdg.approve(address(offerings), type(uint256).max);
            usdg.approve(address(windows), type(uint256).max);
            usdg.approve(address(rfq), type(uint256).max);
            common.approve(address(windows), type(uint256).max);
            common.approve(address(rfq), type(uint256).max);
            seriesB.approve(address(rfq), type(uint256).max);
            vm.stopBroadcast();
        }

        // Subscribe to Series B offering 0, which Deploy.s.sol opened at 25 USDG per share for tier 2 investors.
        _subscribe(AVA, 0, 25_000e6);
        _subscribe(BEN, 0, 40_000e6);
        _subscribe(DANA, 0, 30_000e6);

        // Subscribe to the Common round as well.
        _subscribe(CHEN, commonRound, 12_000e6);
        _subscribe(FAY, commonRound, 6_000e6);
        _subscribe(ELI, commonRound, 3_000e6);
        _subscribe(BEN, commonRound, 9_000e6);

        // Asks at 8.00, 8.40 and 9.25 enter the window first, because a bid is rejected unless the window could
        // deliver the shares from its own balance, and that balance is the escrowed asks. The company then places a
        // small buyback bid at 8.00, followed by investor bids at 9.00, 8.60 and 8.20.
        _order(AVA, windowId, windows.SELL(), 20_000e18, 8e6);
        _order(ELI, windowId, windows.SELL(), 10_000e18, 8_40e4);
        _order(BEN, windowId, windows.SELL(), 15_000e18, 9_25e4);
        uint8 buy = windows.BUY();
        vm.broadcast(deployerKey);
        windows.placeOrder(windowId, buy, 5_000e18, 8e6);
        _order(CHEN, windowId, windows.BUY(), 12_000e18, 9e6);
        _order(FAY, windowId, windows.BUY(), 8_000e18, 8_60e4);
        _order(DANA, windowId, windows.BUY(), 10_000e18, 8_20e4);

        // Two RFQ fills: Dana takes 3,000 of the 5,000 Common that Ava offers at 8.75, and Ben sells 2,000 Series B
        // into Dana's bid at 26. Fay then cancels nonce 1, although no quote with that nonce was ever signed.
        RFQSettlement.Quote memory q = _quote(AVA, address(common), rfq.MAKER_SELLS(), 5_000e18, 8_75e4, 1);
        _fill(DANA, q, _signQuote(AVA, q), 3_000e18);
        q = _quote(DANA, address(seriesB), rfq.MAKER_BUYS(), 2_000e18, 26e6, 1);
        _fill(BEN, q, _signQuote(DANA, q), 2_000e18);
        vm.broadcast(keys[FAY]);
        rfq.cancelQuote(1);

        // Ava receives Eli's votes by delegation before stage 2 opens the proposals.
        vm.broadcast(keys[ELI]);
        governance.delegate(investors[AVA]);

        _writeInvestors();
        console2.log("Common round:", commonRound);
        console2.log("Window:", windowId);
        console2.log("Run settle() after", block.timestamp + SETTLE_DELAY);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Stage 2: settle the window and the round, then pay a dividend and start two votes
    // ---------------------------------------------------------------------------------------------------------------

    function settle() external {
        _load();
        uint256 windowId = windows.windowCount() - 1;
        uint256 commonRound = offerings.offeringCount() - 1;

        vm.startBroadcast(deployerKey);
        windows.clear(windowId);
        offerings.close(commonRound);
        vm.stopBroadcast();

        // Over RFQ, Ava sells 1,500 Common into a bid from Chen.
        RFQSettlement.Quote memory q = _quote(CHEN, address(common), rfq.MAKER_BUYS(), 1_500e18, 8_90e4, 2);
        _fill(AVA, q, _signQuote(CHEN, q), 1_500e18);

        // Common holders receive a 100,000 USDG dividend based on balances at the previous block. Dana leaves hers
        // unclaimed, every other holder claims, and the deployer relays the claim for Eli.
        uint48 recordBlock = common.clock() - 1;
        vm.startBroadcast(deployerKey);
        usdg.approve(address(distributions), type(uint256).max);
        uint256 dividend =
            distributions.fund(address(common), address(usdg), 100_000e6, recordBlock, 0, new address[](0));
        distributions.claimFor(dividend, investors[ELI]);
        distributions.claim(dividend);
        disclosures.anchor(
            "COMPANY_UPDATE", sha256("Larkway Labs Q3 2026 shareholder letter"), "https://selcier.xyz/demo/q3-letter"
        );
        vm.stopBroadcast();
        _claim(AVA, dividend);
        _claim(BEN, dividend);
        _claim(CHEN, dividend);
        _claim(FAY, dividend);

        // Each proposal spans the two classes. The short one runs for VOTE_PERIOD and stage 3 finalizes it, while
        // two weeks pass before the long one ends.
        address[] memory classes = new address[](2);
        classes[0] = address(common);
        classes[1] = address(seriesB);
        vm.startBroadcast(deployerKey);
        uint256 shortVote = governance.propose(
            Governance.ProposalParams({
                shareTokens: classes,
                snapshotBlock: recordBlock,
                endsAt: uint64(block.timestamp) + VOTE_PERIOD,
                quorumBps: 2_000,
                options: 3,
                binding: false,
                documentHash: sha256("Ratify the 2026 equity incentive plan")
            })
        );
        uint256 longVote = governance.propose(
            Governance.ProposalParams({
                shareTokens: classes,
                snapshotBlock: recordBlock,
                endsAt: uint64(block.timestamp) + 14 days,
                quorumBps: 5_000,
                options: 2,
                binding: true,
                documentHash: sha256("Elect the 2027 board of directors")
            })
        );
        governance.castVote(shortVote, 0);
        vm.stopBroadcast();

        // Option 0 is for, 1 is against and 2 is abstain, which the long vote does not offer. Ava casts her own weight,
        // then the weight Eli delegated to her.
        address[] memory delegators = new address[](1);
        delegators[0] = investors[ELI];
        vm.startBroadcast(keys[AVA]);
        governance.castVote(shortVote, 0);
        governance.castVoteFor(shortVote, 0, delegators);
        governance.castVote(longVote, 0);
        vm.stopBroadcast();
        _vote(BEN, shortVote, 1);
        _vote(CHEN, shortVote, 0);
        _vote(DANA, shortVote, 2);
        _vote(BEN, longVote, 0);
        _vote(DANA, longVote, 1);

        console2.log("Dividend:", dividend);
        console2.log("Proposals:", shortVote, longVote);
        console2.log("Run finalize() after", block.timestamp + VOTE_PERIOD);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Stage 3: the short vote gets finalized
    // ---------------------------------------------------------------------------------------------------------------

    function finalize() external {
        _load();
        uint256 shortVote = governance.proposalCount() - 2;
        vm.broadcast(deployerKey);
        governance.finalize(shortVote);
    }

    // ---------------------------------------------------------------------------------------------------------------

    function _load() internal {
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        for (uint256 i; i < INVESTORS; ++i) {
            keys[i] = uint256(keccak256(abi.encode(deployerKey, "selcier-seed", i)))
                % 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
            investors[i] = vm.addr(keys[i]);
        }

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        factory = SelcierFactory(vm.parseJsonAddress(json, ".factory"));
        usdg = MockStablecoin(vm.parseJsonAddress(json, ".stablecoin"));
        common = SelcierShareToken(vm.parseJsonAddress(json, ".demo.common"));
        seriesB = SelcierShareToken(vm.parseJsonAddress(json, ".demo.seriesB"));
        registry = IdentityRegistry(vm.parseJsonAddress(json, ".demo.identityRegistry"));
        offerings = OfferingVault(vm.parseJsonAddress(json, ".demo.offeringVault"));
        windows = LiquidityWindow(vm.parseJsonAddress(json, ".demo.liquidityWindow"));
        rfq = RFQSettlement(vm.parseJsonAddress(json, ".demo.rfqSettlement"));
        distributions = DistributionVault(vm.parseJsonAddress(json, ".demo.distributionVault"));
        governance = Governance(vm.parseJsonAddress(json, ".demo.governance"));
        disclosures = DisclosureRegistry(vm.parseJsonAddress(json, ".demo.disclosureRegistry"));
    }

    /// @dev Runs within the deployer's broadcast. The investor receives gas, test USDG, an identity, and claims
    ///      issued by the deployer.
    function _onboard(uint256 i, bytes2 region, uint8 tier) internal {
        address a = _fund(i);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(a, Topics.REGION, abi.encode(region), expiry, deployer, "");
        registry.addClaim(a, Topics.INVESTOR_ELIGIBLE, abi.encode(tier), expiry, deployer, "");
    }

    function _onboardEmployee(uint256 i, bytes2 region) internal {
        address a = _fund(i);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(a, Topics.REGION, abi.encode(region), expiry, deployer, "");
        registry.addClaim(a, Topics.EMPLOYEE_OF, abi.encode(COMPANY), expiry, deployer, "");
    }

    function _fund(uint256 i) internal returns (address a) {
        a = investors[i];
        payable(a).transfer(GAS_PER_INVESTOR);
        usdg.mint(a, 250_000e6);
        registry.registerIdentity(a, a);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(a, Topics.IDENTITY_VERIFIED, "", expiry, deployer, "");
        registry.addClaim(a, Topics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, deployer, "");
    }

    function _subscribe(uint256 i, uint256 offeringId, uint256 amount) internal {
        vm.broadcast(keys[i]);
        offerings.subscribe(offeringId, amount);
    }

    function _order(uint256 i, uint256 windowId, uint8 side, uint256 quantity, uint256 price) internal {
        vm.broadcast(keys[i]);
        windows.placeOrder(windowId, side, quantity, price);
    }

    function _quote(uint256 maker, address token, uint8 side, uint256 quantity, uint256 price, uint256 nonce)
        internal
        view
        returns (RFQSettlement.Quote memory)
    {
        return RFQSettlement.Quote({
            maker: investors[maker],
            shareToken: token,
            side: side,
            quantity: quantity,
            price: price,
            stablecoin: address(usdg),
            taker: address(0),
            nonce: nonce,
            expiry: uint64(block.timestamp + 7 days)
        });
    }

    function _signQuote(uint256 maker, RFQSettlement.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[maker], rfq.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _fill(uint256 taker, RFQSettlement.Quote memory q, bytes memory signature, uint256 quantity) internal {
        vm.broadcast(keys[taker]);
        rfq.fill(q, signature, quantity);
    }

    function _claim(uint256 i, uint256 distributionId) internal {
        vm.broadcast(keys[i]);
        distributions.claim(distributionId);
    }

    function _vote(uint256 i, uint256 proposalId, uint8 option) internal {
        vm.broadcast(keys[i]);
        governance.castVote(proposalId, option);
    }

    function _writeInvestors() internal {
        string[INVESTORS] memory names = ["ava", "ben", "chen", "dana", "eli", "fay"];
        string memory root = "seed";
        string memory json;
        for (uint256 i; i < INVESTORS; ++i) {
            json = vm.serializeAddress(root, names[i], investors[i]);
        }
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".seed.json"));
    }
}
