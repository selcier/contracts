// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Mirrors the read side of a Chainlink feed. Reference Valuations thereby reach existing integrations with
///         no changes on their end.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IValuationOracle is AggregatorV3Interface {
    /// @dev Carried around as a uint8, where PRICED_ROUND is 0, INDEPENDENT_VALUATION is 1 and WINDOW_CLEARING is 2.
    enum Source {
        PRICED_ROUND,
        INDEPENDENT_VALUATION,
        WINDOW_CLEARING
    }

    event ValuationPublished(int256 price, uint8 source, uint64 asOf, bytes32 documentHash);

    function token() external view returns (address);
    function publish(int256 price, uint8 source, uint64 asOf, bytes32 documentHash) external;

    /// @return price Value of one share in USD, with 8 decimals of precision.
    function latestValuation() external view returns (int256 price, uint8 source, uint64 asOf, bytes32 documentHash);
}
