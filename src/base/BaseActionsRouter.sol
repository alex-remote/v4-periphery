// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";

/// @notice 用于在 Uniswap v4 上执行一组操作（action）组合的抽象合约。
/// @dev 建议使用的 uint256 操作值定义在 Actions.sol 中，但也可以使用任意其它定义
abstract contract BaseActionsRouter is IMsgSender, SafeCallback {
    using CalldataDecoder for bytes;

    /// @notice 当提供的参数数量与操作数量不一致时抛出
    error InputLengthMismatch();

    /// @notice 当继承合约不支持某个操作时抛出
    error UnsupportedAction(uint256 action);

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @notice 触发在 v4 上执行一组操作的内部函数
    /// @dev 继承合约应调用此函数来触发执行
    function _executeActions(bytes calldata unlockData) internal {
        poolManager.unlock(unlockData);
    }

    /// @notice 由 PoolManager 通过 SafeCallback.unlockCallback 调用的函数
    /// @param data (bytes actions, bytes[] params) 的 ABI 编码
    /// 其中 params[i] 是 actions[i] 的编码参数
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // abi.decode(data, (bytes, bytes[]));
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        _executeActionsWithoutUnlock(actions, params);
        return "";
    }

    function _executeActionsWithoutUnlock(bytes calldata actions, bytes[] calldata params) internal {
        uint256 numActions = actions.length;
        if (numActions != params.length) revert InputLengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);

            _handleAction(action, params[actionIndex]);
        }
    }

    /// @notice 负责解析并执行某个操作及其参数的函数
    function _handleAction(uint256 action, bytes calldata params) internal virtual;

    /// @notice 返回被视为这些操作执行者的地址的函数
    /// @dev 本合约不支持其它上下文函数 _msgData 和 _msgValue
    /// 在许多合约中，这会是调用初始入口点（该入口点再调用 `_executeActions`）的地址
    /// 不应使用 `msg.sender`，因为它会是调用 `unlockCallback` 的 v4 PoolManager 合约
    /// 如果使用 ReentrancyLock.sol，此函数可以返回 _getLocker()
    function msgSender() public view virtual returns (address);

    /// @notice 计算某个操作对应的地址
    function _mapRecipient(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) {
            return msgSender();
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            return address(this);
        } else {
            return recipient;
        }
    }

    /// @notice 计算某个操作的付款方
    function _mapPayer(bool payerIsUser) internal view returns (address) {
        return payerIsUser ? msgSender() : address(this);
    }
}
