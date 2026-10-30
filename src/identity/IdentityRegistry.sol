// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IIdentityRegistry} from "../api/IIdentityRegistry.sol";
import {ITrustedVerifiers} from "../api/ITrustedVerifiers.sol";
import {Topics} from "../shared/Topics.sol";
import {Roles} from "../shared/Roles.sol";

/// @title Wallet-to-identity directory and claim store for one company
/// @notice Links each holder wallet of a company to an identity, and keeps what trusted verifiers have claimed about
///         that identity. Personal data has no place here. A claim is just a topic, its verifier, an expiry and a
///         compact value meant for machines, for instance a tier, a country code or a company id. The contract never
///         inspects that value, so keeping it free of personal data falls to the verifiers.
/// @dev Identities are plain addresses, which may point at a dedicated identity contract or merely act as a stable
///      identifier assigned by Selcier. One identity may back several wallets. A verifier can submit a claim itself,
///      and any third party holding an EIP-712 signature from that verifier can relay one. Relayed signatures work
///      only once, which stops a revoked claim from being replayed with its old signature.
contract IdentityRegistry is IIdentityRegistry, AccessControl, Initializable, EIP712 {
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(address identity,bytes32 topic,bytes32 dataHash,uint64 expiry,bytes32 companyId,address registry)"
    );

    error InvalidAddress();
    error UntrustedVerifier();
    error InvalidSignature();
    error SignatureUsed();
    error ClaimExpired();
    error NotAuthorized();
    error UnknownIdentity();
    error NoClaim();

    bytes32 private _companyId;
    ITrustedVerifiers private _verifiers;

    mapping(address => address) private _identityOf;
    mapping(address => mapping(bytes32 => Claim)) private _claims;
    mapping(bytes32 => bool) public usedDigests;

    constructor() EIP712("Selcier", "1") {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address trustedVerifiers_, address admin, address operator)
        external
        initializer
    {
        if (trustedVerifiers_ == address(0) || admin == address(0)) revert InvalidAddress();
        _companyId = companyId_;
        _verifiers = ITrustedVerifiers(trustedVerifiers_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.OPERATOR, operator);
    }

    function companyId() external view returns (bytes32) {
        return _companyId;
    }

    function trustedVerifiers() external view returns (ITrustedVerifiers) {
        return _verifiers;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Linking wallets to identities
    // ---------------------------------------------------------------------------------------------------------------

    function registerIdentity(address wallet, address identity) external onlyRole(Roles.OPERATOR) {
        if (wallet == address(0) || identity == address(0)) revert InvalidAddress();
        _identityOf[wallet] = identity;
        emit IdentityRegistered(wallet, identity);
    }

    function removeIdentity(address wallet) external onlyRole(Roles.OPERATOR) {
        if (_identityOf[wallet] == address(0)) revert UnknownIdentity();
        delete _identityOf[wallet];
        emit IdentityRemoved(wallet);
    }

    function identityOf(address wallet) public view returns (address) {
        return _identityOf[wallet];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Adding and revoking claims
    // ---------------------------------------------------------------------------------------------------------------

    function claimDigest(address identity, bytes32 topic, bytes calldata data, uint64 expiry)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_TYPEHASH, identity, topic, keccak256(data), expiry, _companyId, address(this)))
        );
    }

    function addClaim(
        address identity,
        bytes32 topic,
        bytes calldata data,
        uint64 expiry,
        address verifier,
        bytes calldata signature
    ) external {
        if (identity == address(0)) revert InvalidAddress();
        if (expiry <= block.timestamp) revert ClaimExpired();
        if (!_verifiers.isTrusted(verifier, topic)) revert UntrustedVerifier();

        if (msg.sender != verifier) {
            bytes32 digest = claimDigest(identity, topic, data, expiry);
            if (usedDigests[digest]) revert SignatureUsed();
            if (!SignatureChecker.isValidSignatureNow(verifier, digest, signature)) revert InvalidSignature();
            usedDigests[digest] = true;
        }

        _claims[identity][topic] = Claim({verifier: verifier, expiry: expiry, data: data});
        emit ClaimAdded(identity, topic, verifier, expiry);
    }

    function revokeClaim(address identity, bytes32 topic) external {
        Claim storage c = _claims[identity][topic];
        if (c.verifier == address(0)) revert NoClaim();
        if (msg.sender != c.verifier && !hasRole(Roles.OPERATOR, msg.sender)) revert NotAuthorized();
        delete _claims[identity][topic];
        emit ClaimRevoked(identity, topic);
    }

    function claimOf(address identity, bytes32 topic) external view returns (Claim memory) {
        return _claims[identity][topic];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Verification queries
    // ---------------------------------------------------------------------------------------------------------------

    function isVerified(address wallet) external view returns (bool) {
        return status(wallet) == Status.VERIFIED;
    }

    /// @notice The check applied to each non-system party of a transfer. To pass, a wallet needs a linked identity
    ///         whose IDENTITY_VERIFIED and SCREENED claims are both valid. A missing link or claim gives NOT_VERIFIED,
    ///         which outranks any expiry. CLAIM_EXPIRED covers a claim that is present but past its expiry or from a
    ///         verifier no longer trusted, and it tells the holder that verifying again will fix the problem.
    function status(address wallet) public view returns (Status) {
        address identity = _identityOf[wallet];
        if (identity == address(0)) return Status.NOT_VERIFIED;
        Status a = _claimStatus(identity, Topics.IDENTITY_VERIFIED);
        if (a == Status.NOT_VERIFIED) return a;
        Status b = _claimStatus(identity, Topics.SCREENED);
        if (b == Status.NOT_VERIFIED) return b;
        if (a == Status.CLAIM_EXPIRED || b == Status.CLAIM_EXPIRED) return Status.CLAIM_EXPIRED;
        return Status.VERIFIED;
    }

    function hasValidClaim(address wallet, bytes32 topic) external view returns (bool) {
        address identity = _identityOf[wallet];
        return identity != address(0) && _claimStatus(identity, topic) == Status.VERIFIED;
    }

    function claimData(address wallet, bytes32 topic) external view returns (bytes memory) {
        return _claims[_identityOf[wallet]][topic].data;
    }

    function _claimStatus(address identity, bytes32 topic) private view returns (Status) {
        Claim storage c = _claims[identity][topic];
        if (c.verifier == address(0)) return Status.NOT_VERIFIED;
        if (c.expiry <= block.timestamp || !_verifiers.isTrusted(c.verifier, topic)) return Status.CLAIM_EXPIRED;
        return Status.VERIFIED;
    }
}
