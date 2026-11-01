// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISubscriber} from "./ISubscriber.sol";

/// @title INotifier
/// @notice Notifier 合约的接口
interface INotifier {
    /// @notice 在没有订阅者的情况下取消订阅时抛出
    error NotSubscribed();
    /// @notice 当订阅者没有合约代码时抛出
    error NoCodeSubscriber();
    /// @notice 当用户指定的 gas 上限过低、会导致有效的取消订阅通知无法完成时抛出
    error GasLimitTooLow();
    /// @notice 订阅调用回滚（revert）时，包装订阅者合约的 revert 消息
    error SubscriptionReverted(address subscriber, bytes reason);
    /// @notice 修改流动性通知回滚（revert）时，包装订阅者合约的 revert 消息
    error ModifyLiquidityNotificationReverted(address subscriber, bytes reason);
    /// @notice 销毁通知回滚（revert）时，包装订阅者合约的 revert 消息
    error BurnNotificationReverted(address subscriber, bytes reason);
    /// @notice 当某个 tokenId 已存在订阅者时抛出
    error AlreadySubscribed(uint256 tokenId, address subscriber);

    /// @notice 成功调用 subscribe 时触发
    event Subscription(uint256 indexed tokenId, address indexed subscriber);
    /// @notice 成功调用 unsubscribe 时触发
    event Unsubscription(uint256 indexed tokenId, address indexed subscriber);

    /// @notice 返回对应头寸的订阅者
    /// @param tokenId ERC721 的 tokenId
    /// @return subscriber 订阅者合约
    function subscriber(uint256 tokenId) external view returns (ISubscriber subscriber);

    /// @notice 使订阅者能够接收对应头寸的通知
    /// @param tokenId ERC721 的 tokenId
    /// @param newSubscriber 订阅者合约的地址
    /// @param data 调用者提供的数据，会被转发给订阅者合约
    /// @dev 若头寸已被订阅，再调用 subscribe 会回滚（revert）
    /// @dev 声明为 payable，以便与 NATIVE 相关的操作（action）一起进行 multicall
    /// @dev 若 PoolManager 处于锁定状态则会回滚（revert）
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data) external payable;

    /// @notice 移除订阅者，使其不再接收对应头寸的通知
    /// @param tokenId ERC721 的 tokenId
    /// @dev 调用者必须指定足够高的 gas 上限（剩余 gas 应高于 unsubscriberGasLimit），以确保订阅者能收到通知
    /// @dev 声明为 payable，以便与 NATIVE 相关的操作（action）一起进行 multicall
    /// @dev 必须始终允许用户取消订阅。即使遇到恶意订阅者，用户也总能安全地取消订阅，从而确保流动性始终可以修改。
    /// @dev 若 PoolManager 处于锁定状态则会回滚（revert）
    function unsubscribe(uint256 tokenId) external payable;

    /// @notice 返回并决定通知取消订阅时允许使用的最大 gas 用量
    /// @return uint256 调用订阅者的 `notifyUnsubscribe` 函数进行通知时的最大 gas 上限
    function unsubscribeGasLimit() external view returns (uint256);
}
