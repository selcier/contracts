// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISelcierFactory} from "../api/ISelcierFactory.sol";
import {Roles} from "../shared/Roles.sol";

/// @title Atomic settlement of maker-signed quotes between share class holders
/// @notice Eligible holders of a company's share classes trade here on signed quotes, with delivery and payment
///         happening together. A trade starts off-chain with the maker's EIP-712 signature over a `Quote` (domain
///         "Selcier", version "1"). Any part of that quote, up to all of it, is then filled on-chain by a taker. Since
///         shares travel through `transferFrom`, the share class rules apply to each fill.
/// @dev `side` sets the direction: at 0 the maker sells shares to the taker, and at 1 the maker buys them from the
///      taker. Approvals must be in place first, on the share token from whoever delivers and on the stablecoin from
///      whoever pays. A price counts stablecoin units for one whole share. Buyers pay the value rounded up plus a
///      buyer fee, also rounded up. A seller gets the value rounded down less a seller fee, which rounds down too. The
///      difference goes to `feeRecipient`, so rounding dust can reach it even at zero fee rates, and a stablecoin
///      refusing transfers to the zero address would then revert a fill if `_setFees` left the recipient unset.
contract RFQSettlement is AccessControl, Initializable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 250;
    uint8 public constant MAKER_SELLS = 0;
    uint8 public constant MAKER_BUYS = 1;

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address maker,address shareToken,uint8 side,uint256 quantity,uint256 price,address stablecoin,address taker,uint256 nonce,uint64 expiry)"
    );

    struct Quote {
        address maker;
        address shareToken;
        uint8 side;
        uint256 quantity;
        uint256 price;
        address stablecoin;
        address taker; // the only address allowed to fill, or zero to accept any eligible taker
        uint256 nonce;
        uint64 expiry;
    }

    event QuoteFilled(
        bytes32 indexed quoteHash, address indexed maker, address indexed taker, uint256 quantity, uint256 price
    );
    event QuoteCancelled(address indexed maker, uint256 nonce);
    event NoncesInvalidated(address indexed maker, uint256 minNonce);
    event ShareClassEnabled(address indexed shareToken, bool enabled);
    event FeesUpdated(address recipient, uint16 sellerFeeBps, uint16 buyerFeeBps);

    error NotEnabled();
    error Expired();
    error QuoteCancelledError();
    error WrongTaker();
    error Overfill();
    error InvalidSignature();
    error InvalidParams();

    bytes32 public companyId;
    ISelcierFactory public factory;
    address public feeRecipient;
    uint16 public sellerFeeBps;
    uint16 public buyerFeeBps;

    mapping(address => bool) public enabled;
    mapping(bytes32 => uint256) public filled;
    mapping(address => mapping(uint256 => bool)) public cancelled;
    mapping(address => uint256) public minNonce;

    constructor() EIP712("Selcier", "1") {
        _disableInitializers();
    }

    function initialize(
        bytes32 companyId_,
        address factory_,
        address admin,
        address issuerAdmin,
        address feeRecipient_,
        uint16 sellerFeeBps_,
        uint16 buyerFeeBps_
    ) external initializer {
        companyId = companyId_;
        factory = ISelcierFactory(factory_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ISSUER_ADMIN, issuerAdmin);
        _setFees(feeRecipient_, sellerFeeBps_, buyerFeeBps_);
    }

    function setEnabled(address shareToken, bool on) external onlyRole(Roles.ISSUER_ADMIN) {
        if (factory.shareClassOf(shareToken).companyId != companyId) revert InvalidParams();
        enabled[shareToken] = on;
        emit ShareClassEnabled(shareToken, on);
    }

    function setFees(address recipient, uint16 sellerBps, uint16 buyerBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFees(recipient, sellerBps, buyerBps);
    }

    function hashQuote(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    q.maker,
                    q.shareToken,
                    q.side,
                    q.quantity,
                    q.price,
                    q.stablecoin,
                    q.taker,
                    q.nonce,
                    q.expiry
                )
            )
        );
    }

    /// @notice How much of a quote can still be filled, reading zero once it has expired or been cancelled. This is a
    ///         partial view: it looks at neither the signature, nor the party balances and approvals, nor whether the
    ///         share class is enabled.
    function remaining(Quote calldata q) external view returns (uint256) {
        if (block.timestamp >= q.expiry || cancelled[q.maker][q.nonce] || q.nonce < minNonce[q.maker]) return 0;
        return q.quantity - filled[hashQuote(q)];
    }

    function fill(Quote calldata q, bytes calldata signature, uint256 quantity) external nonReentrant {
        if (!enabled[q.shareToken]) revert NotEnabled();
        if (block.timestamp >= q.expiry) revert Expired();
        if (q.side > MAKER_BUYS || quantity == 0 || q.price == 0) revert InvalidParams();
        if (cancelled[q.maker][q.nonce] || q.nonce < minNonce[q.maker]) revert QuoteCancelledError();
        if (q.taker != address(0) && q.taker != msg.sender) revert WrongTaker();

        bytes32 quoteHash = hashQuote(q);
        uint256 total = filled[quoteHash] + quantity;
        if (total > q.quantity) revert Overfill();
        if (!SignatureChecker.isValidSignatureNow(q.maker, quoteHash, signature)) revert InvalidSignature();
        filled[quoteHash] = total;

        (address seller, address buyer) = q.side == MAKER_SELLS ? (q.maker, msg.sender) : (msg.sender, q.maker);
        uint256 buyerGross = Math.mulDiv(quantity, q.price, 1e18, Math.Rounding.Ceil);
        uint256 buyerFee = Math.mulDiv(buyerGross, buyerFeeBps, 10_000, Math.Rounding.Ceil);
        uint256 sellerGross = (quantity * q.price) / 1e18;
        uint256 sellerNet = sellerGross - (sellerGross * sellerFeeBps) / 10_000;

        IERC20(q.shareToken).safeTransferFrom(seller, buyer, quantity);
        IERC20 stable = IERC20(q.stablecoin);
        stable.safeTransferFrom(buyer, seller, sellerNet);
        uint256 toFees = buyerGross + buyerFee - sellerNet;
        if (toFees != 0) stable.safeTransferFrom(buyer, feeRecipient, toFees);

        emit QuoteFilled(quoteHash, q.maker, msg.sender, quantity, q.price);
    }

    function cancelQuote(uint256 nonce) external {
        _cancel(nonce);
    }

    /// @notice Batch form of `cancelQuote`, for a maker withdrawing particular quotes while leaving the min nonce where
    ///         it is.
    function cancelQuotes(uint256[] calldata nonces) external {
        for (uint256 i; i < nonces.length; ++i) {
            _cancel(nonces[i]);
        }
    }

    /// @notice Voids all of the caller's quotes whose nonce is under `newMinNonce`, which has to exceed the current
    ///         minimum.
    function invalidateNoncesBelow(uint256 newMinNonce) external {
        if (newMinNonce <= minNonce[msg.sender]) revert InvalidParams();
        minNonce[msg.sender] = newMinNonce;
        emit NoncesInvalidated(msg.sender, newMinNonce);
    }

    function _cancel(uint256 nonce) private {
        cancelled[msg.sender][nonce] = true;
        emit QuoteCancelled(msg.sender, nonce);
    }

    function _setFees(address recipient, uint16 sellerBps, uint16 buyerBps) private {
        if (sellerBps > MAX_FEE_BPS || buyerBps > MAX_FEE_BPS) revert InvalidParams();
        if ((sellerBps != 0 || buyerBps != 0) && recipient == address(0)) revert InvalidParams();
        feeRecipient = recipient;
        sellerFeeBps = sellerBps;
        buyerFeeBps = buyerBps;
        emit FeesUpdated(recipient, sellerBps, buyerBps);
    }
}
