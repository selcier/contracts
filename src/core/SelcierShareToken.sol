// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {ISelcierShareToken} from "../api/ISelcierShareToken.sol";
import {IIdentityRegistry} from "../api/IIdentityRegistry.sol";
import {IRuleEngine} from "../api/IRuleEngine.sol";
import {ReasonCodes} from "../shared/ReasonCodes.sol";
import {Topics} from "../shared/Topics.sol";
import {Roles} from "../shared/Roles.sol";
import {Clock} from "../shared/Clock.sol";

/// @title Permissioned share token for a single share class
/// @notice A company issues one of these per share class. It is an 18-decimal ERC-20 that applies the company's
///         transfer rules to every movement, in the style of ERC-3643. Splits go through a display multiplier
///         (ERC-8056) and leave raw balances alone. While `uiMultiplier()` is 1e18, one token is one share.
/// @dev Sits behind an ERC1967 proxy. DEFAULT_ADMIN_ROLE authorises upgrades and belongs to the company's
///      IssuerTimelock, which means any upgrade needs M-of-N signer approval and waits out the timelock's upgrade
///      delay.
///
///      "Agents" are system contracts holding tokens for other people. Three kinds qualify: the LiquidityWindow of
///      the company, any address the admin enables with `setAgent`, and any contract with a valid VENUE claim naming
///      this token.
///      The agent side of a transfer gets no identity check, and modules likewise drop their sender-side or
///      recipient-side checks for it. The rules therefore land on the people at each end of a trade, not on the
///      escrow between them.
contract SelcierShareToken is ISelcierShareToken, AccessControl, Initializable, UUPSUpgradeable {
    using Checkpoints for Checkpoints.Trace208;

    uint64 public constant MIN_RECOVERY_DELAY = 48 hours;
    uint64 public constant MIN_MULTIPLIER_DELAY = 48 hours;

    uint8 private constant PARTY_ISSUER = 1;
    uint8 private constant PARTY_REGISTRAR = 2;
    uint8 private constant PARTY_OPERATOR = 4;

    struct InitParams {
        string name;
        string symbol;
        bytes32 companyId;
        bytes32 shareClass;
        bytes32 documentsRoot;
        address identityRegistry;
        address ruleEngine;
        address admin;
        address issuerAdmin;
        address registrar;
        address operator;
        address[] minters;
        address[] agents;
    }

    struct Recovery {
        address replacement;
        bytes32 ref;
        uint8 approvals;
        uint64 eta;
        address[3] approvers;
    }

    error InvalidAddress();
    error InvalidAmount();
    error InsufficientAllowance();
    error NotRecoveryParty();
    error AlreadyApproved();
    error RecoveryNotReady();
    error RecoveryAlreadyScheduled();
    error InvalidMultiplier();
    error MultiplierTooSoon();
    error NoPendingMultiplier();
    error DelayBelowMinimum();
    error FutureLookup();
    error SupplyOverflow();
    error FreezeExceedsBalance();

    string private _name;
    string private _symbol;
    bytes32 private _companyId;
    bytes32 private _shareClass;
    bytes32 private _documentsRoot;

    IIdentityRegistry private _registry;
    IRuleEngine private _engine;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) private _frozen;
    mapping(address => bool) private _agents;
    bool private _paused;

    uint256 private _multiplier;
    uint256 private _pendingMultiplier;
    uint64 private _multiplierEffectiveAt;

    uint64 public recoveryDelay;
    uint64 public multiplierDelay;
    mapping(address => Recovery) private _recoveries;

    mapping(address => Checkpoints.Trace208) private _balanceCheckpoints;
    Checkpoints.Trace208 private _supplyCheckpoints;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.identityRegistry == address(0) || p.ruleEngine == address(0) || p.admin == address(0)) {
            revert InvalidAddress();
        }
        _name = p.name;
        _symbol = p.symbol;
        _companyId = p.companyId;
        _shareClass = p.shareClass;
        _documentsRoot = p.documentsRoot;
        _registry = IIdentityRegistry(p.identityRegistry);
        _engine = IRuleEngine(p.ruleEngine);
        _multiplier = 1e18;
        recoveryDelay = 72 hours;
        multiplierDelay = MIN_MULTIPLIER_DELAY;

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
        _grantRole(Roles.ISSUER_ADMIN, p.issuerAdmin);
        _grantRole(Roles.REGISTRAR, p.registrar);
        _grantRole(Roles.OPERATOR, p.operator);
        _grantRole(Roles.PAUSER, p.issuerAdmin);
        _grantRole(Roles.PAUSER, p.registrar);
        for (uint256 i; i < p.minters.length; ++i) {
            _grantRole(Roles.MINTER, p.minters[i]);
        }
        for (uint256 i; i < p.agents.length; ++i) {
            _agents[p.agents[i]] = true;
            emit AgentSet(p.agents[i], true);
        }
        emit DocumentsRootUpdated(p.documentsRoot);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-20 interface
    // ---------------------------------------------------------------------------------------------------------------

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        if (to == address(0)) revert InvalidAddress();
        _enforce(msg.sender, to, value);
        _move(msg.sender, to, value, msg.sender);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (to == address(0)) revert InvalidAddress();
        uint256 current = _allowances[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < value) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = current - value;
            }
        }
        _enforce(from, to, value);
        _move(from, to, value, msg.sender);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Transfer eligibility
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISelcierShareToken
    function canTransfer(address from, address to, uint256 amount) public view returns (bool ok, bytes32 reasonCode) {
        if (_paused) return (false, ReasonCodes.TOKEN_PAUSED);

        if (from != address(0)) {
            if (_recoveries[from].eta != 0) return (false, ReasonCodes.FROZEN);
            uint256 balance = _balances[from];
            if (balance < amount) return (false, ReasonCodes.INSUFFICIENT_UNLOCKED_BALANCE);
            if (balance - _frozen[from] < amount) return (false, ReasonCodes.FROZEN);
            if (!isAgent(from)) {
                IIdentityRegistry.Status s = _registry.status(from);
                if (s == IIdentityRegistry.Status.NOT_VERIFIED) return (false, ReasonCodes.SENDER_NOT_VERIFIED);
                if (s == IIdentityRegistry.Status.CLAIM_EXPIRED) return (false, ReasonCodes.CLAIM_EXPIRED);
            }
        }

        if (to != address(0) && !isAgent(to)) {
            IIdentityRegistry.Status s = _registry.status(to);
            if (s == IIdentityRegistry.Status.NOT_VERIFIED) return (false, ReasonCodes.RECIPIENT_NOT_VERIFIED);
            if (s == IIdentityRegistry.Status.CLAIM_EXPIRED) return (false, ReasonCodes.CLAIM_EXPIRED);
        }

        reasonCode = _engine.check(from, to, amount);
        ok = reasonCode == ReasonCodes.OK;
    }

    /// @inheritdoc ISelcierShareToken
    function isAgent(address account) public view returns (bool) {
        if (_agents[account]) return true;
        if (account.code.length == 0 || !_registry.hasValidClaim(account, Topics.VENUE)) return false;
        bytes memory data = _registry.claimData(account, Topics.VENUE);
        return data.length == 32 && abi.decode(data, (address)) == address(this);
    }

    function unlockedBalanceOf(address holder) external view returns (uint256) {
        if (_recoveries[holder].eta != 0) return 0;
        uint256 balance = _balances[holder];
        uint256 held = _frozen[holder] + _engine.lockedBalance(holder);
        return held >= balance ? 0 : balance - held;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Minting and burning
    // ---------------------------------------------------------------------------------------------------------------

    function mint(address to, uint256 amount, bytes32 ref) external {
        if (!hasRole(Roles.REGISTRAR, msg.sender) && !hasRole(Roles.MINTER, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, Roles.REGISTRAR);
        }
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        _enforce(address(0), to, amount);
        _move(address(0), to, amount, msg.sender);
        emit SharesIssued(to, amount, ref);
    }

    function burn(address from, uint256 amount, bytes32 ref) external onlyRole(Roles.REGISTRAR) {
        if (amount == 0 || _balances[from] < amount) revert InvalidAmount();
        _move(from, address(0), amount, msg.sender);
        uint256 remaining = _balances[from];
        if (_frozen[from] > remaining) _frozen[from] = remaining;
        emit SharesRedeemed(from, amount, ref);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Lost wallets: two of issuer, registrar and operator approve, `recoveryDelay` passes, the registrar executes.
    // ---------------------------------------------------------------------------------------------------------------

    function approveRecovery(address lost, address replacement, bytes32 ref) external {
        uint8 party = _partyOf(msg.sender);
        if (replacement == address(0) || replacement == lost) revert InvalidAddress();
        if (!_registry.isVerified(replacement)) revert TransferNotAllowed(ReasonCodes.RECIPIENT_NOT_VERIFIED);

        Recovery storage r = _recoveries[lost];
        if (r.replacement != replacement || r.ref != ref) {
            if (r.eta != 0) revert RecoveryAlreadyScheduled();
            delete _recoveries[lost];
            r.replacement = replacement;
            r.ref = ref;
        }
        if (r.eta != 0) revert RecoveryAlreadyScheduled();
        if (r.approvals & party != 0) revert AlreadyApproved();
        for (uint256 i; i < 3; ++i) {
            if (r.approvers[i] == msg.sender) revert AlreadyApproved();
        }

        r.approvals |= party;
        r.approvers[_partyIndex(party)] = msg.sender;
        emit RecoveryApproved(lost, replacement, msg.sender);

        if (_popcount(r.approvals) >= 2) {
            r.eta = uint64(block.timestamp) + recoveryDelay;
            emit RecoveryScheduled(lost, replacement, r.eta, ref);
        }
    }

    function cancelRecovery(address lost) external {
        _partyOf(msg.sender);
        delete _recoveries[lost];
        emit RecoveryCancelled(lost);
    }

    function recover(address lost, address replacement, bytes32 ref) external onlyRole(Roles.REGISTRAR) {
        Recovery storage r = _recoveries[lost];
        if (r.eta == 0 || block.timestamp < r.eta || r.replacement != replacement || r.ref != ref) {
            revert RecoveryNotReady();
        }
        delete _recoveries[lost];

        uint256 amount = _balances[lost];
        uint256 frozenAmount = _frozen[lost];
        _frozen[lost] = 0;
        _frozen[replacement] += frozenAmount;
        // Stateful modules read an operator equal to this token as a recovery and leave each lot's age untouched.
        _move(lost, replacement, amount, address(this));
        emit RecoveryExecuted(lost, replacement, amount);
    }

    function recoveryOf(address lost) external view returns (Recovery memory) {
        return _recoveries[lost];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Holder freezes and the token-wide pause
    // ---------------------------------------------------------------------------------------------------------------

    function freezePartial(address holder, uint256 amount, bytes32 reason) external onlyRole(Roles.REGISTRAR) {
        uint256 next = _frozen[holder] + amount;
        if (next > _balances[holder]) revert FreezeExceedsBalance();
        _frozen[holder] = next;
        emit TokensFrozen(holder, amount, reason);
    }

    function unfreezePartial(address holder, uint256 amount) external onlyRole(Roles.REGISTRAR) {
        if (amount > _frozen[holder]) revert InvalidAmount();
        _frozen[holder] -= amount;
        emit TokensUnfrozen(holder, amount);
    }

    function pause(bytes32 reason) external onlyRole(Roles.PAUSER) {
        _paused = true;
        emit Paused(reason);
    }

    function unpause() external onlyRole(Roles.PAUSER) {
        _paused = false;
        emit Unpaused();
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function isFrozen(address holder) external view returns (bool) {
        return _recoveries[holder].eta != 0;
    }

    function getFrozenTokens(address holder) external view returns (uint256) {
        return _frozen[holder];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Display multiplier for splits and similar corporate actions (ERC-8056)
    // ---------------------------------------------------------------------------------------------------------------

    function uiMultiplier() public view returns (uint256) {
        if (_multiplierEffectiveAt != 0 && block.timestamp >= _multiplierEffectiveAt) return _pendingMultiplier;
        return _multiplier;
    }

    function pendingMultiplier() external view returns (uint256 multiplier, uint64 effectiveAt) {
        return (_pendingMultiplier, _multiplierEffectiveAt);
    }

    function scheduleMultiplier(uint256 newMultiplier, uint64 effectiveAt) external onlyRole(Roles.ISSUER_ADMIN) {
        if (newMultiplier == 0) revert InvalidMultiplier();
        if (effectiveAt < block.timestamp + multiplierDelay) revert MultiplierTooSoon();
        if (_multiplierEffectiveAt != 0 && block.timestamp >= _multiplierEffectiveAt) _applyMultiplier();
        _pendingMultiplier = newMultiplier;
        _multiplierEffectiveAt = effectiveAt;
        emit MultiplierScheduled(newMultiplier, effectiveAt);
    }

    function cancelMultiplier() external onlyRole(Roles.ISSUER_ADMIN) {
        if (_multiplierEffectiveAt == 0 || block.timestamp >= _multiplierEffectiveAt) revert NoPendingMultiplier();
        _pendingMultiplier = 0;
        _multiplierEffectiveAt = 0;
    }

    /// @notice Open to any caller. Once a scheduled multiplier's time has come, this settles it into storage and
    ///         emits `UIMultiplierUpdated`. Settling is only bookkeeping, since `uiMultiplier()` has been returning
    ///         the scheduled value from `effectiveAt` on.
    function applyMultiplier() external {
        if (_multiplierEffectiveAt == 0 || block.timestamp < _multiplierEffectiveAt) revert NoPendingMultiplier();
        _applyMultiplier();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Historical balances by timepoint
    // ---------------------------------------------------------------------------------------------------------------

    function clock() public view returns (uint48) {
        return Clock.now48();
    }

    function balanceOfAt(address account, uint48 timepoint) external view returns (uint256) {
        if (timepoint >= clock()) revert FutureLookup();
        return _balanceCheckpoints[account].upperLookupRecent(timepoint);
    }

    function totalSupplyAt(uint48 timepoint) external view returns (uint256) {
        if (timepoint >= clock()) revert FutureLookup();
        return _supplyCheckpoints.upperLookupRecent(timepoint);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Token metadata and admin settings
    // ---------------------------------------------------------------------------------------------------------------

    function identityRegistry() external view returns (IIdentityRegistry) {
        return _registry;
    }

    function ruleEngine() external view returns (IRuleEngine) {
        return _engine;
    }

    function compliance() external view returns (address) {
        return address(_engine);
    }

    function shareClass() external view returns (bytes32) {
        return _shareClass;
    }

    function companyId() external view returns (bytes32) {
        return _companyId;
    }

    function documentsRoot() external view returns (bytes32) {
        return _documentsRoot;
    }

    function setDocumentsRoot(bytes32 root) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _documentsRoot = root;
        emit DocumentsRootUpdated(root);
    }

    function setAgent(address agent, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _agents[agent] = enabled;
        emit AgentSet(agent, enabled);
    }

    function setRecoveryDelay(uint64 delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delay < MIN_RECOVERY_DELAY) revert DelayBelowMinimum();
        recoveryDelay = delay;
    }

    function setMultiplierDelay(uint64 delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delay < MIN_MULTIPLIER_DELAY) revert DelayBelowMinimum();
        multiplierDelay = delay;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(ISelcierShareToken).interfaceId || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal mechanics
    // ---------------------------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _enforce(address from, address to, uint256 amount) private view {
        (bool ok, bytes32 code) = canTransfer(from, to, amount);
        if (!ok) revert TransferNotAllowed(code);
    }

    function _move(address from, address to, uint256 amount, address operator) private {
        uint48 now48 = clock();
        if (from == address(0)) {
            uint256 supply = _totalSupply + amount;
            if (supply > type(uint208).max) revert SupplyOverflow();
            _totalSupply = supply;
            _supplyCheckpoints.push(now48, uint208(supply));
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < amount) revert InvalidAmount();
            unchecked {
                _balances[from] = fromBalance - amount;
            }
            _balanceCheckpoints[from].push(now48, uint208(fromBalance - amount));
        }

        if (to == address(0)) {
            unchecked {
                _totalSupply -= amount;
            }
            _supplyCheckpoints.push(now48, uint208(_totalSupply));
        } else {
            uint256 toBalance = _balances[to] + amount;
            _balances[to] = toBalance;
            _balanceCheckpoints[to].push(now48, uint208(toBalance));
        }

        emit Transfer(from, to, amount);
        _engine.transferred(from, to, amount, operator);
    }

    function _applyMultiplier() private {
        uint256 old = _multiplier;
        _multiplier = _pendingMultiplier;
        _pendingMultiplier = 0;
        _multiplierEffectiveAt = 0;
        emit UIMultiplierUpdated(old, _multiplier);
    }

    function _partyOf(address account) private view returns (uint8) {
        if (hasRole(Roles.ISSUER_ADMIN, account)) return PARTY_ISSUER;
        if (hasRole(Roles.REGISTRAR, account)) return PARTY_REGISTRAR;
        if (hasRole(Roles.OPERATOR, account)) return PARTY_OPERATOR;
        revert NotRecoveryParty();
    }

    function _partyIndex(uint8 party) private pure returns (uint256) {
        return party == PARTY_ISSUER ? 0 : party == PARTY_REGISTRAR ? 1 : 2;
    }

    function _popcount(uint8 x) private pure returns (uint8 n) {
        while (x != 0) {
            n += x & 1;
            x >>= 1;
        }
    }
}
