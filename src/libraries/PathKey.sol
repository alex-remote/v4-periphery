//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct PathKey {
    Currency intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    bytes hookData;
}

using PathKeyLibrary for PathKey global;

/// @title PathKey 库
/// @notice 用于处理 PathKey 的函数
library PathKeyLibrary {
    /// @notice 获取给定 PathKey 对应的池及兑换（swap）方向
    /// @param params 给定的 PathKey
    /// @param currencyIn 输入代币
    /// @return poolKey 此次兑换（swap）所在池的 PoolKey
    /// @return zeroForOne 兑换方向；若用 currency0 兑换 currency1 则为 true
    function getPoolAndSwapDirection(PathKey calldata params, Currency currencyIn)
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        Currency currencyOut = params.intermediateCurrency;
        (Currency currency0, Currency currency1) =
            currencyIn < currencyOut ? (currencyIn, currencyOut) : (currencyOut, currencyIn);

        zeroForOne = currencyIn == currency0;
        poolKey = PoolKey(currency0, currency1, params.fee, params.tickSpacing, params.hooks);
    }
}
