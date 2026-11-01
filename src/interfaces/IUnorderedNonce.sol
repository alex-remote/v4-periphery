// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IUnorderedNonce
/// @notice UnorderedNonce 合约的接口
interface IUnorderedNonce {
    error NonceAlreadyUsed();

    /// @notice 记录每个地址已消耗 nonce 的映射，其中每个 nonce 对应 256 位位图中的一个比特
    /// @dev word 最大为 type(uint248).max
    function nonces(address owner, uint256 word) external view returns (uint256);

    /// @notice 通过消耗一个 nonce 来作废它，防止其被再次使用
    /// @dev 用于某个有效 nonce 尚未在链上广播、而所有者希望撤销该 nonce 有效性的情况
    /// @dev 声明为 payable，以便与原生代币相关的操作（action）一起 multicall
    function revokeNonce(uint256 nonce) external payable;
}
