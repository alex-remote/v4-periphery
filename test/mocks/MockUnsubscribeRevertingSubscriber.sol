// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice 仅在 `notifyUnsubscribe` 时回滚（revert）的订阅者。用于验证
///         admin 强制退出（`unwindPosition`）会通过 `_unsubscribe` 上现有的
///         限制 gas + try/catch 路径吞掉该回滚。
contract MockUnsubscribeRevertingSubscriber is ISubscriber {
    error TestRevert(string);

    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256) external pure {
        revert TestRevert("notifyUnsubscribe");
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {}
}
