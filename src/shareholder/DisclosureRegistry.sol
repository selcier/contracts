// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {Roles} from "../shared/Roles.sol";

/// @title On-chain fingerprint registry for company documents
/// @notice The company records a fingerprint of each of its documents here, while the contents remain off-chain under
///         their own access control. To check a copy, compute its SHA-256 hash and compare it with the anchored value.
///         SHA-256 is a convention for anchorers to follow: this contract only rejects a zero hash.
contract DisclosureRegistry is AccessControl, Initializable {
    bytes32 public constant SHARE_CLASS_TERMS = "SHARE_CLASS_TERMS";
    bytes32 public constant OFFERING_DOCUMENT = "OFFERING_DOCUMENT";
    bytes32 public constant FINANCIAL_STATEMENT = "FINANCIAL_STATEMENT";
    bytes32 public constant COMPANY_UPDATE = "COMPANY_UPDATE";
    bytes32 public constant BOARD_RESOLUTION = "BOARD_RESOLUTION";
    bytes32 public constant VALUATION_REPORT = "VALUATION_REPORT";
    bytes32 public constant LEGAL_OPINION = "LEGAL_OPINION";

    struct Document {
        bytes32 kind;
        bytes32 hash;
        string uri;
        uint64 timestamp;
    }

    event DocumentAnchored(uint256 indexed documentId, bytes32 indexed kind, bytes32 hash, string uri);

    error InvalidKind();
    error InvalidHash();
    error UnknownDocument();
    error AlreadyAnchored(uint256 documentId);

    bytes32 private _companyId;
    Document[] private _documents;
    mapping(bytes32 => uint256) public documentIdByHash;
    /// @notice Id of the newest document anchored under a given kind; 0 while that kind has no documents.
    mapping(bytes32 => uint256) public latestDocumentIdOfKind;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address admin, address[] calldata anchorers) external initializer {
        _companyId = companyId_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < anchorers.length; ++i) {
            _grantRole(Roles.ANCHORER, anchorers[i]);
        }
    }

    function companyId() external view returns (bytes32) {
        return _companyId;
    }

    /// @notice Rejects a hash seen before, which keeps `documentIdByHash` pointing at the first record of that hash.
    /// @return documentId The first id issued is 1, reserving 0 as the "no document" value.
    function anchor(bytes32 kind, bytes32 hash, string calldata uri)
        external
        onlyRole(Roles.ANCHORER)
        returns (uint256 documentId)
    {
        if (!isKnownKind(kind)) revert InvalidKind();
        if (hash == bytes32(0)) revert InvalidHash();
        if (documentIdByHash[hash] != 0) revert AlreadyAnchored(documentIdByHash[hash]);
        _documents.push(Document({kind: kind, hash: hash, uri: uri, timestamp: uint64(block.timestamp)}));
        documentId = _documents.length;
        documentIdByHash[hash] = documentId;
        latestDocumentIdOfKind[kind] = documentId;
        emit DocumentAnchored(documentId, kind, hash, uri);
    }

    function document(uint256 documentId) external view returns (Document memory) {
        if (documentId == 0 || documentId > _documents.length) revert UnknownDocument();
        return _documents[documentId - 1];
    }

    function documentCount() external view returns (uint256) {
        return _documents.length;
    }

    function isKnownKind(bytes32 kind) public pure returns (bool) {
        return kind == SHARE_CLASS_TERMS || kind == OFFERING_DOCUMENT || kind == FINANCIAL_STATEMENT
            || kind == COMPANY_UPDATE || kind == BOARD_RESOLUTION || kind == VALUATION_REPORT || kind == LEGAL_OPINION;
    }
}
