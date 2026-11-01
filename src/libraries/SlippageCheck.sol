// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title 滑点检查库
/// @notice 用于检查 delta 是否超过最大上限或未达到最小下限的库
library SlippageCheck {
    using SafeCast for int128;

    error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);
    error MinimumAmountInsufficient(uint128 minimumAmount, uint128 amountReceived);

    /// @notice 若其中一个或两个 delta 未达到最小输出，则回滚（revert）
    /// @param delta 要移除的代币本金数量，不包括任何已累积的手续费
    /// @param amount0Min 要收到的 token0 的最小数量
    /// @param amount1Min 要收到的 token1 的最小数量
    /// @dev 应在移除流动性（销毁或减少流动性）时调用
    function validateMinOut(BalanceDelta delta, uint128 amount0Min, uint128 amount1Min) internal pure {
        // 在销毁或减少流动性时调用，此时我们预期返回的 delta 为正。
        // 但在 hook 可于修改流动性时返回 delta 的池中，返回的 delta 有可能为负。
        // 由于使用了 SafeCast，在 delta 为负的这些情况下会回滚（revert）。
        // 这意味着本合约不支持 hook 在销毁/减少流动性时返回负 delta 的池。
        if (delta.amount0().toUint128() < amount0Min) {
            revert MinimumAmountInsufficient(amount0Min, delta.amount0().toUint128());
        }
        if (delta.amount1().toUint128() < amount1Min) {
            revert MinimumAmountInsufficient(amount1Min, delta.amount1().toUint128());
        }
    }

    /// @notice 若其中一个或两个 delta 超过最大输入，则回滚（revert）
    /// @param delta 要添加的代币本金数量，不包括任何已累积的手续费（在增加流动性时可能存在）
    /// @param amount0Max 愿意花费的 token0 的最大数量
    /// @param amount1Max 愿意花费的 token1 的最大数量
    /// @dev 应在添加流动性（铸造或增加流动性）时调用
    function validateMaxIn(BalanceDelta delta, uint128 amount0Max, uint128 amount1Max) internal pure {
        // 在铸造或增加流动性时调用，此时我们预期返回的 delta 为负。
        // 但在 hook 可于修改流动性时返回 delta 的池中，返回的 delta 有可能为正（即使扣除已累积的手续费之后）。
        // 因此，只有在 delta 确定为负时我们才对其进行类型转换。
        // 并且在 delta 为正的情况下我们不会回滚（revert）。由于正 delta 意味着 hook 在用户铸造/增加流动性时向其记入代币，因此我们不检查滑点。
        // 这意味着在 hook 于铸造/增加流动性时返回正 delta 的池中，本合约不支持“正向”滑点检查（minAmountOut 检查）。
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        if (amount0 < 0 && amount0Max < uint128(uint256(-amount0))) {
            revert MaximumAmountExceeded(amount0Max, uint128(uint256(-amount0)));
        }
        if (amount1 < 0 && amount1Max < uint128(uint256(-amount1))) {
            revert MaximumAmountExceeded(amount1Max, uint128(uint256(-amount1)));
        }
    }
}
