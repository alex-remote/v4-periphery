// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice configId 按 tokenId 逐个设置
/// 低 255 位用于存储对应 PositionConfig 的截断哈希
/// 最高位用于标记该 tokenId 是否有订阅者
struct PositionConfigId {
    bytes32 id;
}

library PositionConfigIdLibrary {
    bytes32 constant MASK_UPPER_BIT = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    bytes32 constant DIRTY_UPPER_BIT = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @notice 返回给定 tokenId 对应的 PositionConfig 的截断哈希
    function getConfigId(PositionConfigId storage _configId) internal view returns (bytes32 configId) {
        configId = _configId.id & MASK_UPPER_BIT;
    }

    /// @dev 我们只在铸造时设置 config，这保证了最高有效位未被置位，因此可以直接把整个 32 字节赋值给 id。
    function setConfigId(PositionConfigId storage _configId, bytes32 configId) internal {
        _configId.id = configId;
    }

    function setSubscribe(PositionConfigId storage configId) internal {
        configId.id |= DIRTY_UPPER_BIT;
    }

    function setUnsubscribe(PositionConfigId storage configId) internal {
        configId.id &= MASK_UPPER_BIT;
    }

    function hasSubscriber(PositionConfigId storage configId) internal view returns (bool subscribed) {
        bytes32 _id = configId.id;
        assembly ("memory-safe") {
            subscribed := shr(255, _id)
        }
    }
}
