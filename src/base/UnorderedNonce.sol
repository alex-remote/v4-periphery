// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnorderedNonce} from "../interfaces/IUnorderedNonce.sol";

/// @title 无序 nonce（Unordered Nonce）
/// @notice 在签名中使用无序 nonce 所需的合约状态与方法
contract UnorderedNonce is IUnorderedNonce {
    /// @inheritdoc IUnorderedNonce
    mapping(address owner => mapping(uint256 word => uint256 bitmap)) public nonces;

    /// @notice 消耗一个 nonce，若其已被使用则回滚（revert）
    /// @param owner address，该 nonce 的所有者/签名者
    /// @param nonce uint256，要消耗的 nonce。高 248 位为 word（字索引），低 8 位表示该字内的位位置
    function _useUnorderedNonce(address owner, uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint256 bitPos = uint8(nonce);

        uint256 bit = 1 << bitPos;
        uint256 flipped = nonces[owner][wordPos] ^= bit;
        if (flipped & bit == 0) revert NonceAlreadyUsed();
    }

    /// @inheritdoc IUnorderedNonce
    function revokeNonce(uint256 nonce) external payable {
        _useUnorderedNonce(msg.sender, nonce);
    }
}
