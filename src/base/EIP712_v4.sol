// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEIP712_v4} from "../interfaces/IEIP712_v4.sol";

/// @notice 通用的 EIP712 实现
/// @dev 在发生分叉时仍保持跨链重放保护
/// @dev 不应通过 delegatecall 调用，因为 DOMAIN_SEPARATOR 返回的是缓存的哈希，不会使用 delegatecall 调用方的地址重新计算
/// @dev 参考：https://github.com/Uniswap/permit2/blob/3f17e8db813189a03950dc7fc8382524a095c053/src/EIP712.sol
/// @dev 参考：https://github.com/OpenZeppelin/openzeppelin-contracts/blob/7bd2b2aaf68c21277097166a9a51eb72ae239b34/contracts/utils/cryptography/EIP712.sol
contract EIP712_v4 is IEIP712_v4 {
    // 将域分隔符（domain separator）缓存为 immutable 值，同时存储其对应的 chain id，
    // 以便在 chain id 发生变化时使缓存的域分隔符失效。
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _HASHED_NAME;

    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    constructor(string memory name) {
        _HASHED_NAME = keccak256(bytes(name));

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @inheritdoc IEIP712_v4
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        // 如果 chainid 与构造时相比未改变，则使用缓存的版本
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    /// @notice 使用当前 chainId 和合约地址构建域分隔符。
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, block.chainid, address(this)));
    }

    /// @notice 创建 EIP-712 类型化数据哈希
    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32 digest) {
        // 等价于 keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
        bytes32 domainSeparator = DOMAIN_SEPARATOR();
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, hex"1901")
            mstore(add(fmp, 0x02), domainSeparator)
            mstore(add(fmp, 0x22), dataHash)
            digest := keccak256(fmp, 0x42)

            // 现在清理我们使用过的内存
            mstore(fmp, 0) // fmp 处存放过 "\x19\x01" 和 domainSeparator
            mstore(add(fmp, 0x20), 0) // fmp+0x20 处存放过 domainSeparator 和 dataHash
            mstore(add(fmp, 0x40), 0) // fmp+0x40 处存放过 dataHash
        }
    }
}
