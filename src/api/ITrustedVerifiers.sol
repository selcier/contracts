// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITrustedVerifiers {
    event VerifierAdded(address indexed verifier, bytes32[] topics);
    event VerifierRemoved(address indexed verifier);

    function addVerifier(address verifier, bytes32[] calldata topics) external;
    function removeVerifier(address verifier) external;
    function isTrusted(address verifier, bytes32 topic) external view returns (bool);
    function topicsOf(address verifier) external view returns (bytes32[] memory);
}
