// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

/// @notice 用于向 PoolManager 同步、发送并结算资金的抽象合约
/// @dev 注意：在 `settle` 中，任何 ERC-20 转账之前都会先调用 sync()。
abstract contract DeltaResolver is ImmutableState {
    using TransientStateLibrary for IPoolManager;

    /// @notice 当发现意外的负 delta 时抛出。
    error DeltaNotPositive(Currency currency);
    /// @notice 当发现意外的正 delta 时抛出。
    error DeltaNotNegative(Currency currency);
    /// @notice 当合约余额不足以进行包装或解包时抛出。
    error InsufficientBalance();

    /// @notice 从 PoolManager 中提取一定数量的代币
    /// @param currency 要提取的代币
    /// @param recipient 接收代币的地址
    /// @param amount 要提取的数量
    /// @dev 若数量为 0 则提前返回
    function _take(Currency currency, address recipient, uint256 amount) internal virtual {
        if (amount == 0) return;
        poolManager.take(currency, recipient, amount);
    }

    /// @notice 向 PoolManager 支付并结算某种代币
    /// @dev 实现合约必须确保 `payer` 是安全的地址
    /// @param currency 要结算的代币
    /// @param payer 付款方地址
    /// @param amount 要发送的数量
    /// @dev 若数量为 0 则提前返回
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            _pay(currency, payer, amount);
            poolManager.settle();
        }
    }

    /// @notice 抽象函数，供合约实现向 poolManager 支付代币的逻辑
    /// @dev 付款的接收者应为 poolManager
    /// @param token 要结算的代币。已知它不是原生代币
    /// @param payer 应支付代币的地址
    /// @param amount 要发送的代币数量
    function _pay(Currency token, address payer, uint256 amount) internal virtual;

    /// @notice 获取本合约所欠的全部数量（负 delta）
    /// @param currency 要查询 delta 的代币
    /// @return amount 本合约所欠的数量，以 uint256 表示
    function _getFullDebt(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // 如果数量为正，应当提取（take）而不是结算（settle）。
        if (_amount > 0) revert DeltaNotNegative(currency);
        // 由于池的总供应量存在上限，此类型转换是安全的
        amount = uint256(-_amount);
    }

    /// @notice 获取欠本合约的全部贷记数量（正 delta）
    /// @param currency 要查询 delta 的代币
    /// @return amount 欠本合约的数量，以 uint256 表示
    function _getFullCredit(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // 如果数量为负，应当结算（settle）而不是提取（take）。
        if (_amount < 0) revert DeltaNotPositive(currency);
        amount = uint256(_amount);
    }

    /// @notice 计算结算（settle）操作的数量
    function _mapSettleAmount(uint256 amount, Currency currency) internal view virtual returns (uint256) {
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            return currency.balanceOfSelf();
        } else if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullDebt(currency);
        } else {
            return amount;
        }
    }

    /// @notice 计算提取（take）操作的数量
    function _mapTakeAmount(uint256 amount, Currency currency) internal view returns (uint256) {
        if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullCredit(currency);
        } else {
            return amount;
        }
    }

    /// @notice 在包装/解包之前计算经过规范化处理的数量。
    /// @param inputCurrency 本合约持有的代币，可以是原生代币或包装后的原生代币
    /// @param amount 要包装或解包的数量。可以是 CONTRACT_BALANCE、OPEN_DELTA 或具体数量
    /// @param outputCurrency 包装/解包之后的代币，用户可能在 poolManager 上欠有该代币的余额
    function _mapWrapUnwrapAmount(Currency inputCurrency, uint256 amount, Currency outputCurrency)
        internal
        view
        returns (uint256)
    {
        // 若为包装，本合约中的余额为 ETH
        // 若为解包，本合约中的余额为 WETH
        uint256 balance = inputCurrency.balanceOf(address(this));
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            // 提前返回，避免不必要的余额检查
            return balance;
        }
        if (amount == ActionConstants.OPEN_DELTA) {
            // 若为包装，PoolManager 上未结清的代币为 WETH。
            // 若为解包，PoolManager 上未结清的代币为 ETH。
            // 注意这里使用的是债务（DEBT）数量。正的 delta 可以先提取再包装。
            amount = _getFullDebt(outputCurrency);
        }
        if (amount > balance) revert InsufficientBalance();
        return amount;
    }
}
