// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library ERC721PermitHash {
    /// @dev 该值等于 keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    /// @dev 该值等于 keccak256("PermitForAll(address operator,bool approved,uint256 nonce,uint256 deadline)");
    bytes32 constant PERMIT_FOR_ALL_TYPEHASH = 0x6673cb397ee2a50b6b8401653d3638b4ac8b3db9c28aa6870ffceb7574ec2f76;

    /// @notice 对将要为 IERC721Permit_v4.permit() 签名的数据进行哈希
    /// @param spender 可以动用该 tokenId 的地址
    /// @param tokenId 所有者的 tokenId，可由 spender 动用
    /// @param nonce 每个签名唯一的无序值，用于防止重放攻击
    /// @param deadline 签名过期的时间
    /// @return digest 待签名数据的哈希；等价于 keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
    function hashPermit(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // 等价于：keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_TYPEHASH)
            mstore(add(fmp, 0x20), and(spender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x40), tokenId)
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)

            // 现在清理我们用过的内存
            mstore(fmp, 0) // fmp 处存放的是 PERMIT_TYPEHASH
            mstore(add(fmp, 0x20), 0) // fmp+0x20 处存放的是 spender
            mstore(add(fmp, 0x40), 0) // fmp+0x40 处存放的是 tokenId
            mstore(add(fmp, 0x60), 0) // fmp+0x60 处存放的是 nonce
            mstore(add(fmp, 0x80), 0) // fmp+0x80 处存放的是 deadline
        }
    }

    /// @notice 对将要为 IERC721Permit_v4.permit() 签名的数据进行哈希
    /// @param operator 可以动用所有者任意 tokenId 的地址
    /// @param approved 若 operator 将获得对所有者全部 tokenId 的完全权限则为 true，否则为 false
    /// @param nonce 每个签名唯一的无序值，用于防止重放攻击
    /// @param deadline 签名过期的时间
    /// @return digest 待签名数据的哈希；等价于 keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline));
    function hashPermitForAll(address operator, bool approved, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // 等价于：keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline));
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_FOR_ALL_TYPEHASH)
            mstore(add(fmp, 0x20), and(operator, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x40), and(approved, 0x1))
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)

            // 现在清理我们用过的内存
            mstore(fmp, 0) // fmp 处存放的是 PERMIT_FOR_ALL_TYPEHASH
            mstore(add(fmp, 0x20), 0) // fmp+0x20 处存放的是 operator
            mstore(add(fmp, 0x40), 0) // fmp+0x40 处存放的是 approved
            mstore(add(fmp, 0x60), 0) // fmp+0x60 处存放的是 nonce
            mstore(add(fmp, 0x80), 0) // fmp+0x80 处存放的是 deadline
        }
    }
}
