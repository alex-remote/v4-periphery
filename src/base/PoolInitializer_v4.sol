// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ImmutableState} from "./ImmutableState.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolInitializer_v4} from "../interfaces/IPoolInitializer_v4.sol";

/// @title 池初始化器（Pool Initializer）
/// @notice 初始化一个 Uniswap v4 池
/// @dev 支持借助 multicall 在单笔交易中完成创建池 + 铸造流动性
abstract contract PoolInitializer_v4 is ImmutableState, IPoolInitializer_v4 {
    /// @inheritdoc IPoolInitializer_v4
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        try poolManager.initialize(key, sqrtPriceX96) returns (int24 tick) {
            return tick;
        } catch {
            return type(int24).max;
        }
    }
}
