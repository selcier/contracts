// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {ISelcierShareToken} from "../api/ISelcierShareToken.sol";
import {ISelcierFactory} from "../api/ISelcierFactory.sol";
import {IIdentityRegistry} from "../api/IIdentityRegistry.sol";
import {Roles} from "../shared/Roles.sol";
import {Clock} from "../shared/Clock.sol";

/// @title Snapshot-based, token-weighted shareholder voting
/// @notice Shareholders vote on proposals that span one or more of the company's share classes. Each class adds to a
///         voter's weight: their balance at the snapshot block, scaled by the display multiplier of that class.
/// @dev Checkpointing lets the snapshot block settle delegation as well as balances. Someone who had a delegate at
///      that block cannot vote directly, since the delegate casts their weight through `castVoteFor`. Someone with no
///      delegate then, or who had named themselves, votes on their own behalf. `hasVoted` limits every holder's
///      weight to one count on either path. Being a verified identity is required of a delegate at the moment of
///      delegation. Multiplier values are captured at proposal creation, not at the snapshot block. Finalizing is
///      open to any account once the voting period ends, and it stores either the index of the winning option, with
///      ties going to the lowest index, or NO_QUORUM.
contract Governance is AccessControl, Initializable {
    using Checkpoints for Checkpoints.Trace208;

    uint8 public constant NO_QUORUM = type(uint8).max;
    uint256 public constant MAX_CLASSES = 8;
    uint256 public constant MAX_OPTIONS = 16;

    struct ProposalParams {
        address[] shareTokens;
        uint48 snapshotBlock;
        uint64 endsAt;
        uint16 quorumBps;
        uint8 options;
        bool binding;
        bytes32 documentHash;
    }

    struct Proposal {
        ProposalParams params;
        uint256[] multipliers;
        uint256[] tallies;
        uint256 totalWeight;
        bool finalized;
        uint8 result;
    }

    event ProposalCreated(uint256 indexed proposalId, uint256 snapshotBlock, uint64 endsAt);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 support, uint256 weight);
    event ProposalFinalized(uint256 indexed proposalId, uint8 result);
    event DelegateChanged(address indexed delegator, address indexed delegatee);

    error InvalidParams();
    error NotCompanyToken();
    error VotingClosed();
    error VotingOpen();
    error AlreadyVoted(address voter);
    error NotDelegate(address delegator);
    error DelegateNotVerified();
    error AlreadyFinalized();
    error NoWeight();
    error UnknownProposal();

    bytes32 public companyId;
    ISelcierFactory public factory;
    IIdentityRegistry public identityRegistry;

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => Checkpoints.Trace208) private _delegation;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address factory_, address registry, address admin, address issuerAdmin)
        external
        initializer
    {
        companyId = companyId_;
        factory = ISelcierFactory(factory_);
        identityRegistry = IIdentityRegistry(registry);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ISSUER_ADMIN, issuerAdmin);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Delegation of voting power
    // ---------------------------------------------------------------------------------------------------------------

    function delegate(address delegatee) external {
        if (delegatee != address(0) && !identityRegistry.isVerified(delegatee)) revert DelegateNotVerified();
        _delegation[msg.sender].push(Clock.now48(), uint208(uint160(delegatee)));
        emit DelegateChanged(msg.sender, delegatee);
    }

    function delegateAt(address delegator, uint48 timepoint) public view returns (address) {
        return address(uint160(_delegation[delegator].upperLookupRecent(timepoint)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Proposal creation, vote casting and results
    // ---------------------------------------------------------------------------------------------------------------

    function propose(ProposalParams calldata p) external onlyRole(Roles.ISSUER_ADMIN) returns (uint256 proposalId) {
        uint256 n = p.shareTokens.length;
        if (n == 0 || n > MAX_CLASSES || p.options < 2 || p.options > MAX_OPTIONS) revert InvalidParams();
        if (p.endsAt <= block.timestamp || p.quorumBps > 10_000) revert InvalidParams();
        if (p.snapshotBlock >= Clock.now48()) revert InvalidParams();

        _proposals.push();
        proposalId = _proposals.length - 1;
        Proposal storage prop = _get(proposalId);
        prop.params = p;
        prop.tallies = new uint256[](p.options);
        prop.multipliers = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address token = p.shareTokens[i];
            if (factory.shareClassOf(token).companyId != companyId) revert NotCompanyToken();
            for (uint256 j; j < i; ++j) {
                if (p.shareTokens[j] == token) revert InvalidParams();
            }
            prop.multipliers[i] = ISelcierShareToken(token).uiMultiplier();
        }
        emit ProposalCreated(proposalId, p.snapshotBlock, p.endsAt);
    }

    function castVote(uint256 proposalId, uint8 option) external {
        Proposal storage prop = _open(proposalId, option);
        address current = delegateAt(msg.sender, prop.params.snapshotBlock);
        if (current != address(0) && current != msg.sender) revert NotDelegate(msg.sender);
        uint256 weight = _record(proposalId, prop, msg.sender);
        if (weight == 0) revert NoWeight();
        prop.tallies[option] += weight;
        prop.totalWeight += weight;
        emit VoteCast(proposalId, msg.sender, option, weight);
    }

    /// @notice Lets a delegate put the combined weight of `delegators` behind one option. Each listed holder must have
    ///         named the caller as their delegate at the snapshot block.
    function castVoteFor(uint256 proposalId, uint8 option, address[] calldata delegators) external {
        Proposal storage prop = _open(proposalId, option);
        uint256 weight;
        for (uint256 i; i < delegators.length; ++i) {
            address d = delegators[i];
            if (delegateAt(d, prop.params.snapshotBlock) != msg.sender) revert NotDelegate(d);
            weight += _record(proposalId, prop, d);
        }
        if (weight == 0) revert NoWeight();
        prop.tallies[option] += weight;
        prop.totalWeight += weight;
        emit VoteCast(proposalId, msg.sender, option, weight);
    }

    function finalize(uint256 proposalId) external {
        Proposal storage prop = _get(proposalId);
        if (prop.finalized) revert AlreadyFinalized();
        if (block.timestamp < prop.params.endsAt) revert VotingOpen();
        prop.finalized = true;

        uint256 eligible;
        for (uint256 i; i < prop.params.shareTokens.length; ++i) {
            uint256 supply = ISelcierShareToken(prop.params.shareTokens[i]).totalSupplyAt(prop.params.snapshotBlock);
            eligible += (supply * prop.multipliers[i]) / 1e18;
        }

        uint8 result = NO_QUORUM;
        if (prop.totalWeight * 10_000 >= eligible * prop.params.quorumBps && prop.totalWeight != 0) {
            uint256 best;
            for (uint8 o; o < prop.params.options; ++o) {
                if (prop.tallies[o] > best) {
                    best = prop.tallies[o];
                    result = o;
                }
            }
        }
        prop.result = result;
        emit ProposalFinalized(proposalId, result);
    }

    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _get(proposalId);
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function weightOf(uint256 proposalId, address voter) public view returns (uint256 weight) {
        Proposal storage prop = _get(proposalId);
        for (uint256 i; i < prop.params.shareTokens.length; ++i) {
            uint256 balance =
                ISelcierShareToken(prop.params.shareTokens[i]).balanceOfAt(voter, prop.params.snapshotBlock);
            weight += (balance * prop.multipliers[i]) / 1e18;
        }
    }

    function _open(uint256 proposalId, uint8 option) private view returns (Proposal storage prop) {
        prop = _get(proposalId);
        if (prop.finalized || block.timestamp >= prop.params.endsAt) revert VotingClosed();
        if (option >= prop.params.options) revert InvalidParams();
    }

    function _record(uint256 proposalId, Proposal storage, address voter) private returns (uint256) {
        if (hasVoted[proposalId][voter]) revert AlreadyVoted(voter);
        hasVoted[proposalId][voter] = true;
        return weightOf(proposalId, voter);
    }

    function _get(uint256 proposalId) private view returns (Proposal storage) {
        if (proposalId >= _proposals.length) revert UnknownProposal();
        return _proposals[proposalId];
    }
}
