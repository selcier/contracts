// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IValuationOracle} from "../api/IValuationOracle.sol";
import {ISelcierShareToken} from "../api/ISelcierShareToken.sol";
import {Roles} from "../shared/Roles.sol";

/// @title Reference Valuation price feed for a single share class
/// @notice Each share class gets its own instance. The figure published here, called the Reference Valuation, is a
///         USD price per share with 8 decimals, along with its date and source. Lending markets and dashboards can
///         consume it without changes because it implements Chainlink's AggregatorV3 interface. The extra getter
///         `latestValuation()` exposes the source, date and supporting document.
/// @dev Do not treat a Reference Valuation as a live market price. Staleness checks see the real age of the number
///      because `updatedAt` is set to `asOf`, the date the valuation refers to, and not to the publication time.
///      `publish` reverts while the share token is paused, so the oracle keeps its last value for as long as a pause
///      lasts. That covers a corporate action only if the token is paused for it: scheduling a multiplier does not
///      pause the token by itself.
contract ValuationOracle is IValuationOracle, AccessControl, Initializable {
    struct Round {
        int256 price;
        uint8 source;
        uint64 asOf;
        uint64 publishedAt;
        bytes32 documentHash;
    }

    error InvalidPrice();
    error InvalidSource();
    error InvalidDate();
    error TokenPaused();
    error NoData();

    address private _token;
    Round[] private _rounds;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin, address[] calldata publishers) external initializer {
        _token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < publishers.length; ++i) {
            _grantRole(Roles.PUBLISHER, publishers[i]);
        }
    }

    function token() external view returns (address) {
        return _token;
    }

    function publish(int256 price, uint8 source, uint64 asOf, bytes32 documentHash) external onlyRole(Roles.PUBLISHER) {
        if (price <= 0) revert InvalidPrice();
        if (source > uint8(Source.WINDOW_CLEARING)) revert InvalidSource();
        if (asOf == 0 || asOf > block.timestamp) revert InvalidDate();
        // A date older than the last round's is refused, which makes the final round the newest valuation. Equal
        // dates pass, and the later publication then wins.
        if (_rounds.length != 0 && asOf < _rounds[_rounds.length - 1].asOf) revert InvalidDate();
        if (ISelcierShareToken(_token).paused()) revert TokenPaused();
        _rounds.push(
            Round({
                price: price,
                source: source,
                asOf: asOf,
                publishedAt: uint64(block.timestamp),
                documentHash: documentHash
            })
        );
        emit ValuationPublished(price, source, asOf, documentHash);
    }

    function latestValuation() external view returns (int256 price, uint8 source, uint64 asOf, bytes32 documentHash) {
        if (_rounds.length == 0) revert NoData();
        Round storage r = _rounds[_rounds.length - 1];
        return (r.price, r.source, r.asOf, r.documentHash);
    }

    /// @notice Returns everything stored for a round, so callers also get the source, supporting document and
    ///         publication time that getRoundData omits.
    function round(uint80 roundId) external view returns (Round memory) {
        if (roundId == 0 || roundId > _rounds.length) revert NoData();
        return _rounds[roundId - 1];
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    /// @notice Returns true when the latest valuation is older than `maxAge` seconds.
    function isStale(uint256 maxAge) external view returns (bool) {
        if (_rounds.length == 0) return true;
        return block.timestamp - _rounds[_rounds.length - 1].asOf > maxAge;
    }

        // Read functions required by AggregatorV3Interface

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return string.concat(IERC20Metadata(_token).symbol(), " / USD reference valuation");
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId == 0 || roundId > _rounds.length) revert NoData();
        Round storage r = _rounds[roundId - 1];
        return (roundId, r.price, r.asOf, r.asOf, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (_rounds.length == 0) revert NoData();
        return getRoundData(uint80(_rounds.length));
    }
}
