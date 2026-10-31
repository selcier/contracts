// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseModule} from "./BaseModule.sol";
import {ReasonCodes} from "../../shared/ReasonCodes.sol";

/// @title Lot-based lockup after acquisition
/// @notice Each acquired lot starts its own lockup clock at the moment of acquisition, and outgoing transfers draw
///         lots down first in, first out.
/// @dev Encode the configuration as `abi.encode(uint32 holdingPeriod, bytes32[] sources, uint32[] periods,
///      address[] operators, bytes32[] operatorSources)`.
///      - The lockup for any lot without an override is `holdingPeriod`, measured in seconds.
///      - `sources`/`periods` replace that fallback for specific acquisition sources, which are ISSUANCE, OFFERING,
///        WINDOW, RFQ and TRANSFER.
///      - `operators`/`operatorSources` pick a lot's source from the contract that moved the tokens. Shares delivered
///        by a company's OfferingVault might be tagged OFFERING and those from its LiquidityWindow tagged WINDOW. With
///        no label, a mint counts as ISSUANCE and a transfer as TRANSFER.
///      Any balance with no recorded lot predates the module. It ranks as the oldest holding and carries no lockup.
///      Lockup lengths are looked up in the live configuration, which means changing it also affects lots already held.
///      During a recovery, signalled by operator == token, lots reach the replacement wallet with their original
///      timestamps intact.
contract HoldingPeriodModule is BaseModule {
    bytes32 public constant ISSUANCE = "ISSUANCE";
    bytes32 public constant TRANSFER = "TRANSFER";
    uint256 public constant MAX_WALK = 64;
    uint256 public constant MAX_OVERRIDES = 16;

    struct Lot {
        uint128 amount;
        uint64 acquiredAt;
        bytes32 source;
    }

    uint32 public holdingPeriod;
    mapping(bytes32 => uint32) private _periodBySource;
    mapping(bytes32 => bool) private _hasOverride;
    bytes32[] private _overrideSources;
    mapping(address => bytes32) public operatorSource;
    address[] private _operators;

    mapping(address => Lot[]) private _lots;
    mapping(address => uint256) private _head;
    mapping(address => uint256) public tracked;

    function moduleId() external pure returns (bytes32) {
        return "HOLDING_PERIOD";
    }

    function periodFor(bytes32 source) public view returns (uint32) {
        return _hasOverride[source] ? _periodBySource[source] : holdingPeriod;
    }

    /// @notice Lists the lots a wallet has not yet consumed, in consumption order. That is oldest first, except where
    ///         a recovery appended lots to a wallet that already had some.
    function lotsOf(address holder) external view returns (Lot[] memory out) {
        Lot[] storage all = _lots[holder];
        uint256 start = _head[holder];
        out = new Lot[](all.length - start);
        for (uint256 i = start; i < all.length; ++i) {
            out[i - start] = all[i];
        }
    }

    function check(address from, address, uint256 amount) external view returns (bytes32) {
        if (_isSystem(from)) return ReasonCodes.OK;
        return amount <= _available(from) ? ReasonCodes.OK : ReasonCodes.HOLDING_PERIOD_ACTIVE;
    }

    function lockedBalance(address holder) external view override returns (uint256) {
        uint256 balance = token.balanceOf(holder);
        uint256 available = _available(holder);
        return available >= balance ? 0 : balance - available;
    }

    /// @dev Sums the balance no lot accounts for and the expired lots at the front of the queue, stopping at the first
    ///      lot still locked or after MAX_WALK lots. The result never exceeds the current balance.
    function _available(address holder) private view returns (uint256 available) {
        uint256 balance = token.balanceOf(holder);
        uint256 lotsTotal = tracked[holder];
        available = balance > lotsTotal ? balance - lotsTotal : 0;
        Lot[] storage lots = _lots[holder];
        uint256 end = lots.length;
        uint256 start = _head[holder];
        if (end - start > MAX_WALK) end = start + MAX_WALK;
        for (uint256 i = start; i < end; ++i) {
            Lot storage lot = lots[i];
            if (block.timestamp < uint256(lot.acquiredAt) + periodFor(lot.source)) break;
            available += lot.amount;
        }
        if (available > balance) available = balance;
    }

    function _onTransfer(address from, address to, uint256 amount, address operator) internal override {
        if (operator == address(token)) {
            _moveLots(from, to);
            return;
        }
        if (!_isSystem(from)) _consume(from, amount);
        if (!_isSystem(to) && amount != 0) {
            bytes32 source = operatorSource[operator];
            if (source == bytes32(0)) source = from == address(0) ? ISSUANCE : TRANSFER;
            _push(to, amount, uint64(block.timestamp), source);
        }
    }

    function _consume(address holder, uint256 amount) private {
        // By the time this runs the token has already taken `amount` out of the balance, so adding it back recovers
        // the figure from before the transfer.
        uint256 before = token.balanceOf(holder) + amount;
        uint256 lotsTotal = tracked[holder];
        uint256 untracked = before > lotsTotal ? before - lotsTotal : 0;
        if (amount <= untracked) return;
        uint256 remaining = amount - untracked;

        Lot[] storage lots = _lots[holder];
        uint256 i = _head[holder];
        while (remaining != 0 && i < lots.length) {
            uint256 lotAmount = lots[i].amount;
            if (lotAmount <= remaining) {
                remaining -= lotAmount;
                delete lots[i];
                ++i;
            } else {
                lots[i].amount = uint128(lotAmount - remaining);
                remaining = 0;
            }
        }
        _head[holder] = i;
        uint256 consumed = (amount - untracked) - remaining;
        tracked[holder] = lotsTotal - consumed;
    }

    function _push(address holder, uint256 amount, uint64 at, bytes32 source) private {
        Lot[] storage lots = _lots[holder];
        uint256 n = lots.length;
        if (n > _head[holder]) {
            Lot storage last = lots[n - 1];
            if (last.acquiredAt == at && last.source == source) {
                last.amount += uint128(amount);
                tracked[holder] += amount;
                return;
            }
        }
        lots.push(Lot({amount: uint128(amount), acquiredAt: at, source: source}));
        tracked[holder] += amount;
    }

    function _moveLots(address from, address to) private {
        Lot[] storage lots = _lots[from];
        for (uint256 i = _head[from]; i < lots.length; ++i) {
            _lots[to].push(lots[i]);
        }
        tracked[to] += tracked[from];
        delete _lots[from];
        _head[from] = 0;
        tracked[from] = 0;
    }

    function _configure(bytes calldata config) internal override {
        (
            uint32 period,
            bytes32[] memory sources,
            uint32[] memory periods,
            address[] memory operators,
            bytes32[] memory opSources
        ) = abi.decode(config, (uint32, bytes32[], uint32[], address[], bytes32[]));
        if (sources.length != periods.length || operators.length != opSources.length) revert InvalidConfig();
        if (sources.length > MAX_OVERRIDES || operators.length > MAX_OVERRIDES) revert InvalidConfig();

        holdingPeriod = period;
        for (uint256 i; i < _overrideSources.length; ++i) {
            _hasOverride[_overrideSources[i]] = false;
        }
        delete _overrideSources;
        for (uint256 i; i < sources.length; ++i) {
            _hasOverride[sources[i]] = true;
            _periodBySource[sources[i]] = periods[i];
            _overrideSources.push(sources[i]);
        }
        for (uint256 i; i < _operators.length; ++i) {
            delete operatorSource[_operators[i]];
        }
        delete _operators;
        for (uint256 i; i < operators.length; ++i) {
            operatorSource[operators[i]] = opSources[i];
            _operators.push(operators[i]);
        }
    }
}
