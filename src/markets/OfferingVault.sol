// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISelcierShareToken} from "../api/ISelcierShareToken.sol";
import {ISelcierFactory} from "../api/ISelcierFactory.sol";
import {IValuationOracle} from "../api/IValuationOracle.sol";
import {IIdentityRegistry} from "../api/IIdentityRegistry.sol";
import {Roles} from "../shared/Roles.sol";

/// @title Escrowed primary share offerings for one company
/// @notice Company share sales run through here. Subscriptions are paid in a stablecoin that this contract holds until
///         the offering settles. When the minimum is met, a single transaction mints shares to each accepted
///         subscriber, pays the fee to the fee recipient and sends the rest of the accepted funds to the company's
///         treasury. An offering that misses its minimum lets each subscriber take back the whole subscription, and no
///         deadline ever applies to such a claim.
/// @dev Subscriptions beyond `maxRaise` are scaled down pro-rata, so subscribing earlier gives no priority. Close runs
///      the share class rules again for each subscriber. Anyone who no longer passes receives no shares and can reclaim
///      the money through `refund`; their pro-rata portion is not passed on to the others.
contract OfferingVault is AccessControl, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SUBSCRIBERS = 500;
    uint256 public constant MAX_REQUIRED_CLAIMS = 8;
    uint16 public constant MAX_FEE_BPS = 500;

    enum State {
        SCHEDULED,
        OPEN,
        CLOSED,
        FAILED
    }

    struct OfferingParams {
        address shareToken;
        uint256 pricePerShare; // quoted per whole share, which is 1e18 raw token units, in stablecoin units
        uint256 minRaise;
        uint256 maxRaise;
        uint256 minTicket;
        uint64 opensAt;
        uint64 closesAt;
        address stablecoin;
        bytes32[] requiredClaims;
        address treasury;
        uint256 documentId;
    }

    struct Offering {
        OfferingParams params;
        uint256 raised;
        uint256 accepted;
        uint256 sharesIssued;
        bool closed;
        bool failed;
    }

    event OfferingCreated(uint256 indexed offeringId);
    event Subscribed(uint256 indexed offeringId, address indexed investor, uint256 amount);
    event OfferingClosed(uint256 indexed offeringId, uint256 raised, uint256 sharesIssued);
    event OfferingFailed(uint256 indexed offeringId);
    event Refunded(uint256 indexed offeringId, address indexed investor, uint256 amount);
    event FeeUpdated(address recipient, uint16 feeBps);

    error InvalidParams();
    error NotCompanyToken();
    error NotOpen();
    error BelowMinimumTicket();
    error MissingClaim(bytes32 topic);
    error TooManySubscribers();
    error CannotClose();
    error AlreadyFinal();
    error NothingToRefund();
    error UnknownOffering();

    bytes32 public companyId;
    ISelcierFactory public factory;
    address public feeRecipient;
    uint16 public feeBps;

    Offering[] private _offerings;
    mapping(uint256 => address[]) private _subscribers;
    mapping(uint256 => mapping(address => uint256)) public subscriptionOf;
    mapping(uint256 => mapping(address => uint256)) public refundableOf;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        bytes32 companyId_,
        address factory_,
        address admin,
        address issuerAdmin,
        address feeRecipient_,
        uint16 feeBps_
    ) external initializer {
        companyId = companyId_;
        factory = ISelcierFactory(factory_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ISSUER_ADMIN, issuerAdmin);
        _setFee(feeRecipient_, feeBps_);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Issuer actions
    // ---------------------------------------------------------------------------------------------------------------

    function createOffering(OfferingParams calldata p)
        external
        onlyRole(Roles.ISSUER_ADMIN)
        returns (uint256 offeringId)
    {
        if (factory.shareClassOf(p.shareToken).companyId != companyId) {
            revert NotCompanyToken();
        }
        if (
            p.pricePerShare == 0 || p.maxRaise == 0 || p.minRaise > p.maxRaise || p.minTicket > p.maxRaise
                || p.closesAt <= p.opensAt || p.closesAt <= block.timestamp || p.stablecoin == address(0)
                || p.treasury == address(0) || p.requiredClaims.length > MAX_REQUIRED_CLAIMS
        ) revert InvalidParams();

        _offerings.push();
        offeringId = _offerings.length - 1;
        _offerings[offeringId].params = p;
        emit OfferingCreated(offeringId);
    }

    /// @notice Marks a not yet settled offering as failed, after which each subscriber can reclaim the entire
    ///         subscription.
    function cancelOffering(uint256 offeringId) external onlyRole(Roles.ISSUER_ADMIN) {
        Offering storage o = _get(offeringId);
        if (o.closed || o.failed) revert AlreadyFinal();
        o.failed = true;
        emit OfferingFailed(offeringId);
    }

    function setFee(address recipient, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFee(recipient, bps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Investor actions
    // ---------------------------------------------------------------------------------------------------------------

    function subscribe(uint256 offeringId, uint256 amount) external nonReentrant {
        Offering storage o = _get(offeringId);
        OfferingParams storage p = o.params;
        if (state(offeringId) != State.OPEN || block.timestamp >= p.closesAt) revert NotOpen();

        uint256 total = subscriptionOf[offeringId][msg.sender] + amount;
        if (amount == 0 || total < p.minTicket) revert BelowMinimumTicket();
        IIdentityRegistry registry = ISelcierShareToken(p.shareToken).identityRegistry();
        for (uint256 i; i < p.requiredClaims.length; ++i) {
            if (!registry.hasValidClaim(msg.sender, p.requiredClaims[i])) {
                revert MissingClaim(p.requiredClaims[i]);
            }
        }
        (bool ok, bytes32 code) =
            ISelcierShareToken(p.shareToken).canTransfer(address(0), msg.sender, _sharesFor(total, p.pricePerShare));
        if (!ok) revert ISelcierShareToken.TransferNotAllowed(code);

        if (subscriptionOf[offeringId][msg.sender] == 0) {
            if (_subscribers[offeringId].length >= MAX_SUBSCRIBERS) revert TooManySubscribers();
            _subscribers[offeringId].push(msg.sender);
        }
        subscriptionOf[offeringId][msg.sender] = total;
        o.raised += amount;
        IERC20(p.stablecoin).safeTransferFrom(msg.sender, address(this), amount);
        emit Subscribed(offeringId, msg.sender, amount);
    }

    /// @notice Finalises an offering. From `closesAt` onward the call is open to anyone. An ISSUER_ADMIN account can
    ///         make it earlier, provided `maxRaise` has been reached.
    function close(uint256 offeringId) external nonReentrant {
        Offering storage o = _get(offeringId);
        OfferingParams storage p = o.params;
        if (o.closed || o.failed) revert AlreadyFinal();
        bool ended = block.timestamp >= p.closesAt;
        bool earlyClose = hasRole(Roles.ISSUER_ADMIN, msg.sender) && o.raised >= p.maxRaise;
        if (!ended && !earlyClose) revert CannotClose();

        if (o.raised < p.minRaise || o.raised == 0) {
            o.failed = true;
            emit OfferingFailed(offeringId);
            return;
        }

        o.closed = true;
        ISelcierShareToken shareToken = ISelcierShareToken(p.shareToken);
        uint256 target = o.raised > p.maxRaise ? p.maxRaise : o.raised;
        address[] storage subs = _subscribers[offeringId];
        uint256 acceptedTotal;
        uint256 sharesTotal;

        for (uint256 i; i < subs.length; ++i) {
            address investor = subs[i];
            uint256 subscribed = subscriptionOf[offeringId][investor];
            uint256 allocation = (subscribed * target) / o.raised;
            uint256 shares = _sharesFor(allocation, p.pricePerShare);
            if (shares != 0) {
                (bool ok,) = shareToken.canTransfer(address(0), investor, shares);
                if (ok) {
                    // Recompute the cost from the shares minted, rounding down, so nobody pays for a partial raw unit.
                    allocation = (shares * p.pricePerShare) / 1e18;
                    shareToken.mint(investor, shares, bytes32(offeringId));
                    acceptedTotal += allocation;
                    sharesTotal += shares;
                } else {
                    allocation = 0;
                }
            } else {
                allocation = 0;
            }
            refundableOf[offeringId][investor] = subscribed - allocation;
        }

        o.accepted = acceptedTotal;
        o.sharesIssued = sharesTotal;

        uint256 fee = (acceptedTotal * feeBps) / 10_000;
        IERC20 stable = IERC20(p.stablecoin);
        if (fee != 0) stable.safeTransfer(feeRecipient, fee);
        stable.safeTransfer(p.treasury, acceptedTotal - fee);

        _publishValuation(p);
        emit OfferingClosed(offeringId, acceptedTotal, sharesTotal);
    }

    function refund(uint256 offeringId) external nonReentrant {
        Offering storage o = _get(offeringId);
        uint256 amount;
        if (o.failed) {
            amount = subscriptionOf[offeringId][msg.sender];
            subscriptionOf[offeringId][msg.sender] = 0;
        } else if (o.closed) {
            amount = refundableOf[offeringId][msg.sender];
            refundableOf[offeringId][msg.sender] = 0;
        }
        if (amount == 0) revert NothingToRefund();
        IERC20(o.params.stablecoin).safeTransfer(msg.sender, amount);
        emit Refunded(offeringId, msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Read access
    // ---------------------------------------------------------------------------------------------------------------

    function state(uint256 offeringId) public view returns (State) {
        Offering storage o = _get(offeringId);
        if (o.failed) return State.FAILED;
        if (o.closed) return State.CLOSED;
        if (block.timestamp < o.params.opensAt) return State.SCHEDULED;
        // closesAt is not consulted here. The state reads OPEN until close() runs, so subscribe() tests the deadline.
        return State.OPEN;
    }

    function offering(uint256 offeringId) external view returns (Offering memory) {
        return _get(offeringId);
    }

    function offeringCount() external view returns (uint256) {
        return _offerings.length;
    }

    function subscribers(uint256 offeringId) external view returns (address[] memory) {
        return _subscribers[offeringId];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _get(uint256 offeringId) private view returns (Offering storage) {
        if (offeringId >= _offerings.length) revert UnknownOffering();
        return _offerings[offeringId];
    }

    function _sharesFor(uint256 amount, uint256 pricePerShare) private pure returns (uint256) {
        return (amount * 1e18) / pricePerShare;
    }

    function _publishValuation(OfferingParams storage p) private {
        address oracle = factory.shareClassOf(p.shareToken).valuationOracle;
        uint8 stableDecimals = IERC20Metadata(p.stablecoin).decimals();
        int256 price = int256(_toOracleUnits(p.pricePerShare, stableDecimals));
        // Settlement must go through even if the oracle rejects this publish, as it does while the token is paused.
        try IValuationOracle(oracle)
            .publish(
                price, uint8(IValuationOracle.Source.PRICED_ROUND), uint64(block.timestamp), bytes32(p.documentId)
            ) {}
            catch {}
    }

    function _toOracleUnits(uint256 amount, uint8 stableDecimals) private pure returns (uint256) {
        if (stableDecimals == 8) return amount;
        if (stableDecimals < 8) return amount * 10 ** (8 - stableDecimals);
        return amount / 10 ** (stableDecimals - 8);
    }

    function _setFee(address recipient, uint16 bps) private {
        if (bps > MAX_FEE_BPS || (bps != 0 && recipient == address(0))) revert InvalidParams();
        feeRecipient = recipient;
        feeBps = bps;
        emit FeeUpdated(recipient, bps);
    }
}
