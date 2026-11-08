// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {ITrustedVerifiers} from "../api/ITrustedVerifiers.sol";

/// @title Per-company allowlist of claim verifiers
/// @notice Records, for one company, the verifier keys allowed to sign each claim topic. The starting list comes in
///         at deployment, and Selcier's default identity providers fill it when the company names none. From then
///         on, the company's IssuerTimelock adds and removes verifiers.
contract TrustedVerifiers is ITrustedVerifiers, AccessControl, Initializable {
    uint256 public constant MAX_TOPICS = 16;

    error InvalidVerifier();
    error TooManyTopics();
    error UnknownVerifier();
    error LengthMismatch();

    mapping(address => mapping(bytes32 => bool)) private _trusted;
    mapping(address => bytes32[]) private _topics;
    uint256 private _verifierCount;

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address[] calldata verifiers, bytes32[][] calldata topics) external initializer {
        if (verifiers.length != topics.length) revert LengthMismatch();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < verifiers.length; ++i) {
            _add(verifiers[i], topics[i]);
        }
    }

    function addVerifier(address verifier, bytes32[] calldata topics) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _remove(verifier);
        _add(verifier, topics);
    }

    function removeVerifier(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_topics[verifier].length == 0) revert UnknownVerifier();
        _remove(verifier);
        emit VerifierRemoved(verifier);
    }

    function isTrusted(address verifier, bytes32 topic) external view returns (bool) {
        return _trusted[verifier][topic];
    }

    function topicsOf(address verifier) external view returns (bytes32[] memory) {
        return _topics[verifier];
    }

    function verifierCount() external view returns (uint256) {
        return _verifierCount;
    }

    function _add(address verifier, bytes32[] calldata topics) private {
        if (verifier == address(0)) revert InvalidVerifier();
        if (topics.length > MAX_TOPICS) revert TooManyTopics();
        for (uint256 i; i < topics.length; ++i) {
            if (!_trusted[verifier][topics[i]]) {
                _trusted[verifier][topics[i]] = true;
                _topics[verifier].push(topics[i]);
            }
        }
        _verifierCount++;
        emit VerifierAdded(verifier, topics);
    }

    function _remove(address verifier) private {
        bytes32[] storage list = _topics[verifier];
        for (uint256 i; i < list.length; ++i) {
            _trusted[verifier][list[i]] = false;
        }
        if (list.length > 0) _verifierCount--;
        delete _topics[verifier];
    }
}
