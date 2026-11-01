// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice 仅在 `notifyBurn` 时回滚（revert）的订阅者。用于验证由 LP 发起的
///         销毁仍会向上传播该回滚（保留基础行为）。
contract MockBurnRevertingSubscriber is ISubscriber {
    error TestRevert(string);

    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256) external pure {}

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {
        revert TestRevert("notifyBurn");
    }
}
