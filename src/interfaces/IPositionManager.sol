// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo} from "../libraries/PositionInfoLibrary.sol";

import {INotifier} from "./INotifier.sol";
import {IImmutableState} from "./IImmutableState.sol";
import {IERC721Permit_v4} from "./IERC721Permit_v4.sol";
import {IEIP712_v4} from "./IEIP712_v4.sol";
import {IMulticall_v4} from "./IMulticall_v4.sol";
import {IPoolInitializer_v4} from "./IPoolInitializer_v4.sol";
import {IUnorderedNonce} from "./IUnorderedNonce.sol";
import {IPermit2Forwarder} from "./IPermit2Forwarder.sol";

/// @title IPositionManager
/// @notice PositionManager 合约的接口
interface IPositionManager is
    INotifier,
    IImmutableState,
    IERC721Permit_v4,
    IEIP712_v4,
    IMulticall_v4,
    IPoolInitializer_v4,
    IUnorderedNonce,
    IPermit2Forwarder
{
    /// @notice 由 PositionManager 在每次 modifyLiquidity 调用时触发，对应 PoolManager 的
    ///         ModifyLiquidity 事件，区别在于 `sender` 是 unlock 的锁定者（终端用户），而不是 PositionManager。
    event ModifyPosition(
        PoolId indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt
    );

    /// @notice 当调用者未被授权修改头寸时抛出
    error NotApproved(address caller);
    /// @notice 当 block.timestamp 超过用户提供的截止时间时抛出
    error DeadlinePassed(uint256 deadline);
    /// @notice 在 PoolManager 处于解锁状态时调用 transfer、subscribe 或 unsubscribe 会抛出该错误。
    /// @dev 这是为了防止 hook 在头寸被修改的同时触发通知。
    error PoolManagerMustBeLocked();

    /// @notice 解锁 Uniswap v4 PoolManager，并批量执行修改流动性的操作（action）
    /// @dev 这是 PositionManager 的标准入口
    /// @param unlockData 操作（action）及其参数的编码
    /// @param deadline 这批操作必须在此之前执行的截止时间
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice 在不解锁 v4 PoolManager 的情况下批量执行修改流动性的操作（action）
    /// @dev 必须由已经解锁 v4 PoolManager 的合约调用
    /// @param actions 要执行的操作（action）
    /// @param params 提供给这些操作的参数
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable;

    /// @notice 用于获取下一个铸造的流动性头寸将使用的 ID
    /// @return uint256 下一个 token ID
    function nextTokenId() external view returns (uint256);

    /// @notice 返回头寸的流动性
    /// @param tokenId ERC721 的 tokenId
    /// @return liquidity 头寸的流动性，以 liquidityAmount 表示
    /// @dev 可以借助 LiquidityAmounts 库将该值换算为 amount0 和 amount1
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @notice 返回头寸的 pool key 和头寸信息（position info）
    /// @param tokenId ERC721 的 tokenId
    /// @return poolKey 头寸的 pool key
    /// @return PositionInfo 一个打包的 uint256 值，保存头寸的相关信息，包括价格区间（tickLower, tickUpper）
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, PositionInfo);

    /// @notice 返回头寸的头寸信息（position info）
    /// @param tokenId ERC721 的 tokenId
    /// @return 一个打包的 uint256 值，保存头寸的相关信息，包括价格区间（tickLower, tickUpper）
    function positionInfo(uint256 tokenId) external view returns (PositionInfo);
}
