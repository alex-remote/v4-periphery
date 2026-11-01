// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {INotifier} from "../interfaces/INotifier.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../libraries/PositionInfoLibrary.sol";

/// @notice Notifier 用于选择启用：在头寸被修改或转移时，向外部合约发送更新通知
abstract contract Notifier is INotifier {
    using CustomRevert for *;

    ISubscriber private constant NO_SUBSCRIBER = ISubscriber(address(0));

    /// @inheritdoc INotifier
    uint256 public immutable unsubscribeGasLimit;

    /// @inheritdoc INotifier
    mapping(uint256 tokenId => ISubscriber subscriber) public subscriber;

    constructor(uint256 _unsubscribeGasLimit) {
        unsubscribeGasLimit = _unsubscribeGasLimit;
    }

    /// @notice 仅允许已被授权为该 tokenId 的被授权者或操作者的调用者
    /// @dev 由父合约（PositionManager）实现
    /// @param caller 调用者地址
    /// @param tokenId 头寸的 tokenId
    modifier onlyIfApproved(address caller, uint256 tokenId) virtual;

    /// @notice 强制要求 PoolManager 处于锁定状态。
    modifier onlyIfPoolManagerLocked() virtual;

    function _setUnsubscribed(uint256 tokenId) internal virtual;

    function _setSubscribed(uint256 tokenId) internal virtual;

    /// @inheritdoc INotifier
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data)
        external
        payable
        onlyIfPoolManagerLocked
        onlyIfApproved(msg.sender, tokenId)
    {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(tokenId, address(_subscriber));
        _setSubscribed(tokenId);

        subscriber[tokenId] = ISubscriber(newSubscriber);

        bool success = _call(newSubscriber, abi.encodeCall(ISubscriber.notifySubscribe, (tokenId, data)));

        if (!success) {
            newSubscriber.bubbleUpAndRevertWith(ISubscriber.notifySubscribe.selector, SubscriptionReverted.selector);
        }

        emit Subscription(tokenId, newSubscriber);
    }

    /// @inheritdoc INotifier
    function unsubscribe(uint256 tokenId) external payable onlyIfPoolManagerLocked onlyIfApproved(msg.sender, tokenId) {
        _unsubscribe(tokenId);
    }

    function _unsubscribe(uint256 tokenId) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber == NO_SUBSCRIBER) revert NotSubscribed();
        _setUnsubscribed(tokenId);

        delete subscriber[tokenId];

        if (address(_subscriber).code.length > 0) {
            // 要求剩余 gas 足以通知订阅者
            // 否则，用户可以选择一个 gas 上限，使 .notifyUnsubscribe 发生 OutOfGas，但
            // 交易/取消订阅仍然能够成功
            if (gasleft() < unsubscribeGasLimit) GasLimitTooLow.selector.revertWith();
            try _subscriber.notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId) {} catch {}
        }

        emit Unsubscription(tokenId, address(_subscriber));
    }

    /// @dev 注意：此函数还会从 mapping 中删除订阅者地址
    function _removeSubscriberAndNotifyBurn(
        uint256 tokenId,
        address owner,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) internal {
        address _subscriber = address(subscriber[tokenId]);

        // 移除订阅者
        delete subscriber[tokenId];

        bool success =
            _call(_subscriber, abi.encodeCall(ISubscriber.notifyBurn, (tokenId, owner, info, liquidity, feesAccrued)));

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(ISubscriber.notifyBurn.selector, BurnNotificationReverted.selector);
        }
    }

    function _notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) internal {
        address _subscriber = address(subscriber[tokenId]);

        bool success = _call(
            _subscriber, abi.encodeCall(ISubscriber.notifyModifyLiquidity, (tokenId, liquidityChange, feesAccrued))
        );

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(
                ISubscriber.notifyModifyLiquidity.selector, ModifyLiquidityNotificationReverted.selector
            );
        }
    }

    function _call(address target, bytes memory encodedCall) internal returns (bool success) {
        if (target.code.length == 0) NoCodeSubscriber.selector.revertWith();
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
    }
}
