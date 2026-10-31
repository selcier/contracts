// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IdentityBalanceModule} from "./BaseModule.sol";
import {ReasonCodes} from "../../shared/ReasonCodes.sol";
import {Roles} from "../../shared/Roles.sol";

/// @title Lock on unvested employee shares
/// @notice An employee's unvested shares stay locked and become free as their schedule progresses. A person with
///         several wallets still counts as one holder, since each schedule attaches to the identity.
/// @dev Configuration reaches this module through the engine, and therefore through the IssuerTimelock. Its encoding
///      is `abi.encode(uint8 action, bytes payload)`, with the meaning of `payload` depending on the action.
///      - action 0 switches acceleration on or off, using `payload = abi.encode(bool accelerationEnabled)`.
///      - action 1 carries `payload = abi.encode(address identity, uint256 index)` and marks that single grant fully
///        vested. It reverts while acceleration is disabled.
///      `addGrants` takes a separate route: grants originate in the cap table, so a caller holding REGISTRAR on the
///      token submits them directly.
///      `cliff` and `duration` are offsets from `start`. Nothing vests before the cliff. From there the vested amount
///      follows a straight line measured from `start`, rounded down, so reaching the cliff releases the part already
///      accrued. Every other rule continues to apply to shares once they vest.
contract EmployeeVestingModule is IdentityBalanceModule {
    uint256 public constant MAX_GRANTS = 16;
    uint8 public constant ACTION_SET = 0;
    uint8 public constant ACTION_ACCELERATE = 1;

    struct Grant {
        uint64 start;
        uint64 cliff;
        uint64 duration;
        uint256 total;
        bool accelerated;
    }

    event GrantAdded(
        address indexed identity, uint256 index, uint64 start, uint64 cliff, uint64 duration, uint256 total
    );
    event GrantAccelerated(address indexed identity, uint256 index);

    error NotRegistrar();
    error AccelerationDisabled();
    error TooManyGrants();

    bool public accelerationEnabled;
    mapping(address => Grant[]) private _grants;

    function moduleId() external pure returns (bytes32) {
        return "EMPLOYEE_VESTING";
    }

    function grantsOf(address identity) external view returns (Grant[] memory) {
        return _grants[identity];
    }

    function addGrants(address identity, Grant[] calldata grants) external {
        if (!IAccessControl(address(token)).hasRole(Roles.REGISTRAR, msg.sender)) revert NotRegistrar();
        Grant[] storage list = _grants[identity];
        if (list.length + grants.length > MAX_GRANTS) revert TooManyGrants();
        for (uint256 i; i < grants.length; ++i) {
            Grant calldata g = grants[i];
            if (g.duration == 0 || g.cliff > g.duration) revert InvalidConfig();
            list.push(Grant({start: g.start, cliff: g.cliff, duration: g.duration, total: g.total, accelerated: false}));
            emit GrantAdded(identity, list.length - 1, g.start, g.cliff, g.duration, g.total);
        }
    }

    function unvestedOf(address identity) public view returns (uint256 unvested) {
        Grant[] storage list = _grants[identity];
        for (uint256 i; i < list.length; ++i) {
            Grant storage g = list[i];
            unvested += g.total - _vested(g);
        }
    }

    function check(address from, address, uint256 amount) external view returns (bytes32) {
        if (_isSystem(from)) return ReasonCodes.OK;
        address id = _identity(from);
        if (id == address(0)) return ReasonCodes.OK;
        uint256 unvested = unvestedOf(id);
        if (unvested == 0) return ReasonCodes.OK;
        return amount + unvested > identityBalance[id] ? ReasonCodes.UNVESTED : ReasonCodes.OK;
    }

    function lockedBalance(address holder) external view override returns (uint256) {
        uint256 unvested = unvestedOf(_identity(holder));
        uint256 balance = token.balanceOf(holder);
        return unvested > balance ? balance : unvested;
    }

    function _vested(Grant storage g) private view returns (uint256) {
        if (g.accelerated || block.timestamp >= uint256(g.start) + g.duration) return g.total;
        if (block.timestamp < uint256(g.start) + g.cliff) return 0;
        return (g.total * (block.timestamp - g.start)) / g.duration;
    }

    function _configure(bytes calldata config) internal override {
        (uint8 action, bytes memory payload) = abi.decode(config, (uint8, bytes));
        if (action == ACTION_SET) {
            accelerationEnabled = abi.decode(payload, (bool));
        } else if (action == ACTION_ACCELERATE) {
            if (!accelerationEnabled) revert AccelerationDisabled();
            (address identity, uint256 index) = abi.decode(payload, (address, uint256));
            _grants[identity][index].accelerated = true;
            emit GrantAccelerated(identity, index);
        } else {
            revert InvalidConfig();
        }
    }
}
