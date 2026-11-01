// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IImmutableState} from "../interfaces/IImmutableState.sol";

/// @title IStateView
/// @notice StateView 合约的接口
interface IStateView is IImmutableState {
    /// @notice 获取池的 Slot0：sqrtPriceX96、tick、protocolFee、lpFee
    /// @dev 对应 pools[poolId].slot0
    /// @param poolId 池的 ID。
    /// @return sqrtPriceX96 池价格的平方根，Q96 精度。
    /// @return tick 池的当前 tick。
    /// @return protocolFee 池的协议费。
    /// @return lpFee 池的兑换（swap）手续费。
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /// @notice 获取池在指定 tick 处的 tick 信息。
    /// @dev 对应 pools[poolId].ticks[tick]
    /// @param poolId 池的 ID。
    /// @param tick 要获取信息的 tick。
    /// @return liquidityGross 引用该 tick 的头寸流动性总量
    /// @return liquidityNet 从左向右（从右向左）穿越该 tick 时增加（减去）的净流动性数量
    /// @return feeGrowthOutside0X128 该 tick _另一侧_（相对于当前 tick）每单位流动性的手续费增长
    /// @return feeGrowthOutside1X128 该 tick _另一侧_（相对于当前 tick）每单位流动性的手续费增长
    function getTickInfo(PoolId poolId, int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        );

    /// @notice 获取池在指定 tick 处的流动性信息。
    /// @dev 对应 pools[poolId].ticks[tick].liquidityGross 和 pools[poolId].ticks[tick].liquidityNet。是 getTickInfo 更省 gas 的版本
    /// @param poolId 池的 ID。
    /// @param tick 要获取流动性的 tick。
    /// @return liquidityGross 引用该 tick 的头寸流动性总量
    /// @return liquidityNet 从左向右（从右向左）穿越该 tick 时增加（减去）的净流动性数量
    function getTickLiquidity(PoolId poolId, int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet);

    /// @notice 获取池在某个 tick 区间外侧的手续费增长
    /// @dev 对应 pools[poolId].ticks[tick].feeGrowthOutside0X128 和 pools[poolId].ticks[tick].feeGrowthOutside1X128。是 getTickInfo 更省 gas 的版本
    /// @param poolId 池的 ID。
    /// @param tick 要获取手续费增长的 tick。
    /// @return feeGrowthOutside0X128 该 tick _另一侧_（相对于当前 tick）每单位流动性的手续费增长
    /// @return feeGrowthOutside1X128 该 tick _另一侧_（相对于当前 tick）每单位流动性的手续费增长
    function getTickFeeGrowthOutside(PoolId poolId, int24 tick)
        external
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128);

    /// @notice 获取池的全局手续费增长。
    /// @dev 对应 pools[poolId].feeGrowthGlobal0X128 和 pools[poolId].feeGrowthGlobal1X128
    /// @param poolId 池的 ID。
    /// @return feeGrowthGlobal0 token0 的全局手续费增长。
    /// @return feeGrowthGlobal1 token1 的全局手续费增长。
    function getFeeGrowthGlobals(PoolId poolId)
        external
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1);

    /// @notice 获取池的总流动性。
    /// @dev 对应 pools[poolId].liquidity
    /// @param poolId 池的 ID。
    /// @return liquidity 池的流动性。
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity);

    /// @notice 获取池在指定 tick 处的 tick bitmap。
    /// @dev 对应 pools[poolId].tickBitmap[tick]
    /// @param poolId 池的 ID。
    /// @param tick 要获取 bitmap 的 tick。
    /// @return tickBitmap 该 tick 的 bitmap。
    function getTickBitmap(PoolId poolId, int16 tick) external view returns (uint256 tickBitmap);

    /// @notice 获取头寸信息，无需自行计算 `positionId`。
    /// @dev 对应 pools[poolId].positions[positionId]
    /// @param poolId 池的 ID。
    /// @param owner 流动性头寸的所有者。
    /// @param tickLower 流动性区间的下边界 tick。
    /// @param tickUpper 流动性区间的上边界 tick。
    /// @param salt 用于进一步区分头寸状态的 bytes32 随机值。
    /// @return liquidity 头寸的流动性。
    /// @return feeGrowthInside0LastX128 头寸内 token0 的手续费增长。
    /// @return feeGrowthInside1LastX128 头寸内 token1 的手续费增长。
    function getPositionInfo(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

    /// @notice 获取池在指定头寸 ID 处的头寸信息。
    /// @dev 对应 pools[poolId].positions[positionId]
    /// @param poolId 池的 ID。
    /// @param positionId 头寸的 ID。
    /// @return liquidity 头寸的流动性。
    /// @return feeGrowthInside0LastX128 头寸内 token0 的手续费增长。
    /// @return feeGrowthInside1LastX128 头寸内 token1 的手续费增长。
    function getPositionInfo(PoolId poolId, bytes32 positionId)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

    /// @notice 获取头寸的流动性。
    /// @dev 对应 pools[poolId].positions[positionId].liquidity。仅获取流动性时比 getPositionInfo 更省 gas
    /// @param poolId 池的 ID。
    /// @param positionId 头寸的 ID。
    /// @return liquidity 头寸的流动性。
    function getPositionLiquidity(PoolId poolId, bytes32 positionId) external view returns (uint128 liquidity);

    /// @notice 计算池在某个 tick 区间内的手续费增长
    /// @dev Position.Info 中的 pools[poolId].feeGrowthInside0LastX128 是缓存值，可能会过时。此函数会计算最新的 feeGrowthInside
    /// @param poolId 池的 ID。
    /// @param tickLower 区间的下边界 tick。
    /// @param tickUpper 区间的上边界 tick。
    /// @return feeGrowthInside0X128 tick 区间内 token0 的手续费增长。
    /// @return feeGrowthInside1X128 tick 区间内 token1 的手续费增长。
    function getFeeGrowthInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128);
}
