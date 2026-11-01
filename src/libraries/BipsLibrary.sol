// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 使用基点（bips）计算某个数量的百分比
library BipsLibrary {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice 当提供的百分比无效时抛出
    error InvalidBips();

    /// @param amount 要计算百分比的总数量
    /// @param bips 要计算的百分比，以基点（bips）为单位
    function calculatePortion(uint256 amount, uint256 bips) internal pure returns (uint256) {
        if (bips > BPS_DENOMINATOR) revert InvalidBips();
        return (amount * bips) / BPS_DENOMINATOR;
    }
}
