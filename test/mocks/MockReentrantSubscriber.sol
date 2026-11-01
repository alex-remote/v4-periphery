// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {INotifier} from "../../src/interfaces/INotifier.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice 在 `notifyUnsubscribe` 时，通过 `posm.subscribe(...)` 重新挂接一个新的订阅者。
///         `unwindPosition` 在 manager 锁定状态下取消订阅，因此 `subscribe` 的
///         `onlyIfPoolManagerLocked` 守卫会通过，重新挂接成功；用于验证
///         `unwindPosition` 的强制清除会在销毁之前移除重新挂接的订阅者。
contract MockReentrantSubscriber is ISubscriber {
    INotifier public immutable posm;
    address public immutable reentrantTarget;

    constructor(INotifier _posm, address _reentrantTarget) {
        posm = _posm;
        reentrantTarget = _reentrantTarget;
    }

    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256 tokenId) external {
        // 此处 manager 处于锁定状态，因此 subscribe 的 onlyIfPoolManagerLocked 守卫会通过，
        // 本次重新挂接成功；unwindPosition 的强制清除会在 BURN_POSITION 之前将其移除。
        posm.subscribe(tokenId, reentrantTarget, "");
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {}
}
