// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IRuleEngine} from "../api/IRuleEngine.sol";
import {IRuleModule} from "../api/IRuleModule.sol";
import {ReasonCodes} from "../shared/ReasonCodes.sol";

/// @title Ordered runner for a share class's transfer rules
/// @notice A share class keeps its transfer rules in separate module contracts, and this contract calls them in
///         sequence. Because of that split, the token needs no upgrade when a company adds, drops or retunes a rule.
///         Every such change requires DEFAULT_ADMIN_ROLE, which sits with the company's IssuerTimelock, where module
///         changes wait 24 hours by default.
contract RuleEngine is IRuleEngine, AccessControl, Initializable {
    uint256 public constant MAX_MODULES = 10;

    error OnlyToken();
    error InvalidModule();
    error ModuleExists();
    error ModuleMissing();
    error TooManyModules();
    error LengthMismatch();

    address private _token;
    address[] private _modules;
    mapping(address => bool) private _enabled;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin, address[] calldata modules_, bytes[] calldata configs)
        external
        initializer
    {
        if (token_ == address(0) || admin == address(0)) revert InvalidModule();
        if (modules_.length != configs.length) revert LengthMismatch();
        _token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < modules_.length; ++i) {
            _add(modules_[i], configs[i]);
        }
    }

    function token() external view returns (address) {
        return _token;
    }

    function modules() external view returns (address[] memory) {
        return _modules;
    }

    function hasModule(bytes32 moduleId) external view returns (bool) {
        for (uint256 i; i < _modules.length; ++i) {
            if (IRuleModule(_modules[i]).moduleId() == moduleId) return true;
        }
        return false;
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        for (uint256 i; i < _modules.length; ++i) {
            bytes32 code = IRuleModule(_modules[i]).check(from, to, amount);
            if (code != ReasonCodes.OK) return code;
        }
        return ReasonCodes.OK;
    }

    function transferred(address from, address to, uint256 amount, address operator) external {
        if (msg.sender != _token) revert OnlyToken();
        for (uint256 i; i < _modules.length; ++i) {
            IRuleModule(_modules[i]).onTransfer(from, to, amount, operator);
        }
    }

    function lockedBalance(address holder) external view returns (uint256 total) {
        for (uint256 i; i < _modules.length; ++i) {
            total += IRuleModule(_modules[i]).lockedBalance(holder);
        }
    }

    function addModule(address module, bytes calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _add(module, config);
    }

    function removeModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_enabled[module]) revert ModuleMissing();
        _enabled[module] = false;
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            if (_modules[i] == module) {
                // Shifting instead of swapping with the last entry keeps the sequence the company configured,
                // which is the sequence the loops above run in.
                for (uint256 j = i; j + 1 < n; ++j) {
                    _modules[j] = _modules[j + 1];
                }
                _modules.pop();
                break;
            }
        }
        emit ModuleRemoved(module);
    }

    function configureModule(address module, bytes calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_enabled[module]) revert ModuleMissing();
        IRuleModule(module).configure(config);
        emit ModuleConfigured(module, keccak256(config));
    }

    function _add(address module, bytes calldata config) private {
        if (module == address(0) || IRuleModule(module).engine() != address(this)) revert InvalidModule();
        if (_enabled[module]) revert ModuleExists();
        if (_modules.length >= MAX_MODULES) revert TooManyModules();
        _enabled[module] = true;
        _modules.push(module);
        IRuleModule(module).configure(config);
        emit ModuleAdded(module);
        emit ModuleConfigured(module, keccak256(config));
    }
}
