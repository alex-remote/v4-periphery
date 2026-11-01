// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IImmutableState
/// @notice ImmutableState 合约的接口
interface IImmutableState {
    /// @notice Uniswap v4 的 PoolManager 合约
    function poolManager() external view returns (IPoolManager);
}
