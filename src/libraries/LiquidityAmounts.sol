// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @notice 提供根据代币数量和价格计算流动性数量的函数
library LiquidityAmounts {
    using SafeCast for uint256;

    /// @notice 计算给定 token0 数量和价格区间可获得的流动性数量
    /// @dev 计算 amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
    /// @param sqrtPriceAX96 表示第一个 tick 边界的 sqrt 价格
    /// @param sqrtPriceBX96 表示第二个 tick 边界的 sqrt 价格
    /// @param amount0 转入的 amount0
    /// @return liquidity 返回的流动性数量
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
            return FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
        }
    }

    /// @notice 计算给定 token1 数量和价格区间可获得的流动性数量
    /// @dev 计算 amount1 / (sqrt(upper) - sqrt(lower))。
    /// @param sqrtPriceAX96 表示第一个 tick 边界的 sqrt 价格
    /// @param sqrtPriceBX96 表示第二个 tick 边界的 sqrt 价格
    /// @param amount1 转入的 amount1
    /// @return liquidity 返回的流动性数量
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
        }
    }

    /// @notice 根据给定的 token0 数量、token1 数量、当前
    /// 池价格以及各 tick 边界处的价格，计算可获得的最大流动性数量
    /// @param sqrtPriceX96 表示当前池价格的 sqrt 价格
    /// @param sqrtPriceAX96 表示第一个 tick 边界的 sqrt 价格
    /// @param sqrtPriceBX96 表示第二个 tick 边界的 sqrt 价格
    /// @param amount0 转入的 token0 数量
    /// @param amount1 转入的 token1 数量
    /// @return liquidity 可获得的最大流动性数量
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }
}
