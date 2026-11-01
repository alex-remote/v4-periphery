// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title CurrencyRatioSortOrder
/// @notice 提供在显示价格比率时对代币进行排序的常量
/// 被赋予较大值的代币将位于价格比率的分子中
/// @dev 参考：https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/TokenRatioSortOrder.sol
library CurrencyRatioSortOrder {
    int256 constant NUMERATOR_MOST = 300;
    int256 constant NUMERATOR_MORE = 200;
    int256 constant NUMERATOR = 100;

    int256 constant DENOMINATOR_MOST = -300;
    int256 constant DENOMINATOR_MORE = -200;
    int256 constant DENOMINATOR = -100;
}
