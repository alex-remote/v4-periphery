// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {HookSavesDelta} from "./HookSavesDelta.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice 本合约并非用于生产环境的合约。它仅用于测试，以验证外部合约可以在不持有锁的情况下修改流动性（IPositionManager.modifyLiquiditiesWithoutUnlock）
/// @dev 一个可以在 beforeSwap 中修改流动性的 hook
contract HookModifyLiquidities is HookSavesDelta {
    IPositionManager posm;
    IAllowanceTransfer permit2;

    function setAddresses(IPositionManager _posm, IAllowanceTransfer _permit2) external {
        posm = _posm;
        permit2 = _permit2;
    }

    function beforeSwap(
        address, /* sender **/
        PoolKey calldata key, /* key **/
        SwapParams calldata, /* params **/
        bytes calldata hookData
    )
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        approvePosmCurrency(key.currency0);
        approvePosmCurrency(key.currency1);

        (bytes memory actions, bytes[] memory params) = abi.decode(hookData, (bytes, bytes[]));
        posm.modifyLiquiditiesWithoutUnlock(actions, params);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeAddLiquidity(
        address, /* sender **/
        PoolKey calldata, /* key **/
        ModifyLiquidityParams calldata, /* params **/
        bytes calldata hookData
    )
        external
        override
        returns (bytes4)
    {
        if (hookData.length > 0) {
            (bytes memory actions, bytes[] memory params) = abi.decode(hookData, (bytes, bytes[]));
            posm.modifyLiquiditiesWithoutUnlock(actions, params);
        }
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address, /* sender **/
        PoolKey calldata, /* key **/
        ModifyLiquidityParams calldata, /* params **/
        bytes calldata hookData
    ) external override returns (bytes4) {
        if (hookData.length > 0) {
            (bytes memory actions, bytes[] memory params) = abi.decode(hookData, (bytes, bytes[]));
            posm.modifyLiquiditiesWithoutUnlock(actions, params);
        }
        return this.beforeRemoveLiquidity.selector;
    }

    function approvePosmCurrency(Currency currency) internal {
        // 由于 POSM 使用 permit2，我们必须执行 2 次许可/授权。
        // 1. 首先，调用者必须在代币上授权 permit2。
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. 然后，调用者必须在 permit2 中授权 POSM 作为被授权者。TODO: 这里也可以改用签名。
        permit2.approve(Currency.unwrap(currency), address(posm), type(uint160).max, type(uint48).max);
    }
}
