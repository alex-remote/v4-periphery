// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IERC721Permit_v4
/// @notice ERC721Permit_v4 合约的接口
interface IERC721Permit_v4 {
    error SignatureDeadlineExpired();
    error NoSelfPermit();
    error Unauthorized();

    /// @notice 通过签名授权 spender 使用指定 token ID 的代币
    /// @param spender 被授权的账户
    /// @param tokenId 被授权使用的代币 ID
    /// @param deadline 截止时间戳，交易必须在此时间之前被打包上链，授权才会生效
    /// @param nonce 所有者维度的唯一值，用于防止重放攻击；这是一个无序 nonce，高 248 位对应一个 word（字），低 8 位用于计算在该 word 中的位位置
    /// @param signature 持有者有效 secp256k1 签名的拼接数据，即 abi.encodePacked(r, s, v)
    /// @dev 声明为 payable，以便与 NATIVE 相关的操作（action）一起进行 multicall
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable;

    /// @notice 通过签名设置一个对所有者全部代币拥有完全权限的操作者
    /// @param owner 设置操作者的地址
    /// @param operator 将被设置为该所有者之操作者的地址
    /// @param approved 要为该操作者设置的权限
    /// @param deadline 截止时间戳，交易必须在此时间之前被打包上链，授权才会生效
    /// @param nonce 所有者维度的唯一值，用于防止重放攻击；这是一个无序 nonce，高 248 位对应一个 word（字），低 8 位用于计算在该 word 中的位位置
    /// @param signature 持有者有效 secp256k1 签名的拼接数据，即 abi.encodePacked(r, s, v)
    /// @dev 声明为 payable，以便与 NATIVE 相关的操作（action）一起进行 multicall
    function permitForAll(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external payable;
}
