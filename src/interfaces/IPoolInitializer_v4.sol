// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPoolInitializer_v4
/// @notice PoolInitializer_v4 合约的接口
interface IPoolInitializer_v4 {
    /// @notice 初始化一个 Uniswap v4 池
    /// @dev 若池已初始化，该函数不会回滚（revert），而是直接返回 type(int24).max
    /// @param key 要初始化的池的 PoolKey
    /// @param sqrtPriceX96 池的初始价格，以 sqrtPriceX96 形式表示
    /// @return 池的当前 tick；若创建池失败或池已存在，则返回 type(int24).max
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
}
