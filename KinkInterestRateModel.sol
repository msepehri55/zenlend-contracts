// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRateModel {
    function borrowRatePerSecond(uint256 cash, uint256 borrows, uint256 reserves) external view returns (uint256);
}

contract KinkInterestRateModel is IRateModel {
    uint256 public immutable basePerYear;   // 1e18
    uint256 public immutable slope1PerYear; // 1e18
    uint256 public immutable slope2PerYear; // 1e18
    uint256 public immutable kink;          // 1e18
    uint256 constant SECONDS_PER_YEAR = 365 days;

    constructor(
        uint256 _basePerYear,
        uint256 _slope1PerYear,
        uint256 _slope2PerYear,
        uint256 _kink
    ) {
        basePerYear = _basePerYear;
        slope1PerYear = _slope1PerYear;
        slope2PerYear = _slope2PerYear;
        kink = _kink;
    }

    function utilization(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        if (borrows == 0) return 0;
        return borrows * 1e18 / (cash + borrows - reserves);
    }

    function borrowRatePerSecond(uint256 cash, uint256 borrows, uint256 reserves) external view returns (uint256) {
        uint256 u = utilization(cash, borrows, reserves);
        uint256 apr;
        if (u <= kink) {
            apr = basePerYear + (slope1PerYear * u) / kink;
        } else {
            uint256 over = u - kink;
            apr = basePerYear + slope1PerYear + (slope2PerYear * over) / (1e18 - kink);
        }
        return apr / SECONDS_PER_YEAR; // 1e18 per second
    }
}