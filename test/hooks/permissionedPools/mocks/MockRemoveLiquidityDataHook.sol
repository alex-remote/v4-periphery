// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice 充当一个在移除流动性时要求提供 `hookData` 的自定义许可 hook 扩展。
/// @dev 挖掘地址时只带 `BEFORE_REMOVE_LIQUIDITY_FLAG`，因此添加流动性时永远不会被调用，也不会干扰
///      初始流动性的注入。`hookData` 为空时回滚，以便调用方断言该值确实被转发了。
contract MockRemoveLiquidityDataHook {
    error HookDataRequired();

    bytes public lastHookData;

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata hookData)
        external
        returns (bytes4)
    {
        if (hookData.length == 0) revert HookDataRequired();
        lastHookData = hookData;
        return IHooks.beforeRemoveLiquidity.selector;
    }

    receive() external payable {}
}
