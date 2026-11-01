// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice 在 `notifyUnsubscribe` 期间留下一个未结算（UNSETTLED）PoolManager delta 的订阅者。
///         在回调中，它给自己铸造 1 wei 原生 ETH 的 ERC-6909 凭证（claim），这会给
///         订阅者记上 -1 的 delta，然后正常返回。原生 ETH（currency id 0）不需要任何
///         余额、授权或白名单放行。
/// @dev 回调正常返回，因此 `_unsubscribe` 中限制 gas 的 try/catch 没有任何可
///      捕获的异常。如果回调在一个已开启的 PoolManager unlock 内部运行，外层的 `unlock` 会在
///      回调返回后以 `CurrencyNotSettled` 回滚（revert），导致强制退出彻底失效。当
///      取消订阅在 manager 处于锁定状态时执行，`mint` 则会以 `ManagerLocked` 回滚，
///      该回滚发生在回调内部，并被 try/catch 吸收。
contract MockFlashAttackSubscriber is ISubscriber {
    IPoolManager public immutable manager;
    uint256 public notifyUnsubscribeCount;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function notifySubscribe(uint256, bytes memory) external {}

    function notifyUnsubscribe(uint256) external {
        manager.mint(address(this), 0, 1);
        notifyUnsubscribeCount++;
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}
}
