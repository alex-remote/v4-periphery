// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Hook 统计接口
/// @notice 面向 hook 管理的储备金与可立即使用的流动性的 URC-3 接口
interface IHookStats is IERC165 {
    /// @notice 返回 hook 为某个池管理的总储备金
    function getReserves(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1);

    /// @notice 返回 hook 管理的、可立即用于兑换的资产
    function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1);

    /// @notice 返回本合约所报告统计数据对应的 hook
    function hook() external view returns (address);
}
