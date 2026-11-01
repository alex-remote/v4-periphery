// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {QuoterRevert} from "../libraries/QuoterRevert.sol";
import {SafeCallback} from "../base/SafeCallback.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

abstract contract BaseV4Quoter is SafeCallback {
    using QuoterRevert for *;

    error NotEnoughLiquidity(PoolId poolId);
    error NotSelf();
    error UnexpectedCallSuccess();

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @dev 只有本合约地址可以调用此函数。用于模拟内部函数：通过一次
    /// 外部调用来捕获并解析回滚（revert）原因
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        // 每条报价路径都会先获取报价，然后以 QuoteSwap(quoteAmount) 或其它错误回滚（revert）
        if (success) revert UnexpectedCallSuccess();
        // 向上冒泡回滚数据，无论是有效报价还是其它错误
        returnData.bubbleReason();
    }

    /// @dev 执行一次兑换（swap）并返回余额 delta
    /// @notice 若 amountSpecified < 0，则为 exactInput（精确输入）兑换，否则为 exactOutput（精确输出）
    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        internal
        returns (BalanceDelta swapDelta)
    {
        swapDelta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        // 检查池的流动性是否充足。
        int128 amountSpecifiedActual = (zeroForOne == (amountSpecified < 0)) ? swapDelta.amount0() : swapDelta.amount1();
        if (amountSpecifiedActual != amountSpecified) {
            revert NotEnoughLiquidity(poolKey.toId());
        }
    }
}
