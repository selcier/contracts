// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseModule} from "./BaseModule.sol";
import {ReasonCodes} from "../../shared/ReasonCodes.sol";

/// @title Right of first refusal on direct transfers
/// @notice Before shares change hands directly, the company or someone it designates gets the chance to take them.
/// @dev The module expects the right holder, a notice period in seconds and a venue list, laid out as
///      `abi.encode(address holder, uint32 noticePeriod, address[] exemptVenues)`.
///      A shareholder starts the flow by calling `propose(to, amount)`. From then on `check` answers ROFR_PENDING for
///      any amount above the proposed figure, and for the proposed amount too until the right holder waives or the
///      notice period runs out. Calling `propose` again replaces the record for that pair, whatever its status, and
///      restarts the notice period.
///      Should the right holder exercise, the proposal permits a transfer to the right holder and nobody else. Payment
///      stays between the two parties, who might use RFQSettlement for it.
///      The notice flow does not cover exempt venues. One example is the LiquidityWindow, which handles the right
///      in-line by giving it priority as a bid.
contract ROFRModule is BaseModule {
    uint256 public constant MAX_VENUES = 16;

    enum Status {
        NONE,
        PENDING,
        WAIVED,
        EXERCISED
    }

    struct Proposal {
        uint256 amount;
        uint64 proposedAt;
        Status status;
    }

    event TransferProposed(address indexed from, address indexed to, uint256 amount, uint64 noticeEndsAt);
    event RightWaived(address indexed from, address indexed to);
    event RightExercised(address indexed from, address indexed to, uint256 amount);

    error NotRightHolder();
    error NoProposal();

    address public holder;
    uint32 public noticePeriod;
    address[] private _exemptVenues;
    mapping(address => bool) public isExemptVenue;
    mapping(address => mapping(address => Proposal)) public proposals;

    function moduleId() external pure returns (bytes32) {
        return "ROFR";
    }

    function exemptVenues() external view returns (address[] memory) {
        return _exemptVenues;
    }

    function propose(address to, uint256 amount) external {
        proposals[msg.sender][to] =
            Proposal({amount: amount, proposedAt: uint64(block.timestamp), status: Status.PENDING});
        emit TransferProposed(msg.sender, to, amount, uint64(block.timestamp) + noticePeriod);
    }

    function waive(address from, address to) external {
        Proposal storage p = _pending(from, to);
        p.status = Status.WAIVED;
        emit RightWaived(from, to);
    }

    function exercise(address from, address to) external {
        Proposal storage p = _pending(from, to);
        p.status = Status.EXERCISED;
        emit RightExercised(from, to, p.amount);
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        if (_isSystem(from) || from == holder || to == holder) return ReasonCodes.OK;
        if (isExemptVenue[from] || isExemptVenue[to]) return ReasonCodes.OK;
        Proposal storage p = proposals[from][to];
        if (amount > p.amount) return ReasonCodes.ROFR_PENDING;
        if (p.status == Status.WAIVED) return ReasonCodes.OK;
        if (p.status == Status.PENDING && block.timestamp >= uint256(p.proposedAt) + noticePeriod) {
            return ReasonCodes.OK;
        }
        return ReasonCodes.ROFR_PENDING;
    }

    function _onTransfer(address from, address to, uint256 amount, address) internal override {
        Proposal storage p = proposals[from][to];
        if (p.status == Status.NONE) return;
        if (p.amount <= amount) delete proposals[from][to];
        else p.amount -= amount;
    }

    function _pending(address from, address to) private view returns (Proposal storage p) {
        if (msg.sender != holder) revert NotRightHolder();
        p = proposals[from][to];
        if (p.status != Status.PENDING) revert NoProposal();
    }

    function _configure(bytes calldata config) internal override {
        (address holder_, uint32 notice, address[] memory venues) = abi.decode(config, (address, uint32, address[]));
        if (holder_ == address(0) || venues.length > MAX_VENUES) revert InvalidConfig();
        holder = holder_;
        noticePeriod = notice;
        for (uint256 i; i < _exemptVenues.length; ++i) {
            isExemptVenue[_exemptVenues[i]] = false;
        }
        delete _exemptVenues;
        for (uint256 i; i < venues.length; ++i) {
            isExemptVenue[venues[i]] = true;
            _exemptVenues.push(venues[i]);
        }
    }
}
