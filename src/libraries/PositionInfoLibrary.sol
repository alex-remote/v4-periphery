// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @dev PositionInfo 是 solidity 结构体的紧凑打包版本。
 * 使用打包版本无需把结构体各字段分别存放在内存槽中，从而节省 gas 和内存。
 *
 * 布局：
 * 200 位 poolId | 24 位 tickUpper | 24 位 tickLower | 8 位 hasSubscriber
 *
 * 从最低有效位开始依次排列的各字段：
 *
 * 用于判断该 tokenId 是否已订阅到某个地址的标志
 * uint8 hasSubscriber;
 *
 * 头寸的 tickUpper
 * int24 tickUpper;
 *
 * 头寸的 tickLower
 * int24 tickLower;
 *
 * 截断后的 poolId。对 bytes32 值进行截断，只使用最高有效（最高的）200 位。
 * bytes25 poolId;
 *
 * 注意：如果需要更多位，hasSubscriber 可以只占用 1 位。
 *
 */
type PositionInfo is uint256;

using PositionInfoLibrary for PositionInfo global;

library PositionInfoLibrary {
    PositionInfo internal constant EMPTY_POSITION_INFO = PositionInfo.wrap(0);

    uint256 internal constant MASK_UPPER_200_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000;
    uint256 internal constant MASK_8_BITS = 0xFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;
    uint256 internal constant SET_UNSUBSCRIBE = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00;
    uint256 internal constant SET_SUBSCRIBE = 0x01;
    uint8 internal constant TICK_LOWER_OFFSET = 8;
    uint8 internal constant TICK_UPPER_OFFSET = 32;

    /// @dev 此 poolId 与 UniswapV4 core 中使用的 poolId 并不兼容。它被截断为 25 字节，仅用于在 poolKeys 映射中查找 PoolKey。
    function poolId(PositionInfo info) internal pure returns (bytes25 _poolId) {
        assembly ("memory-safe") {
            _poolId := and(MASK_UPPER_200_BITS, info)
        }
    }

    function tickLower(PositionInfo info) internal pure returns (int24 _tickLower) {
        assembly ("memory-safe") {
            _tickLower := signextend(2, shr(TICK_LOWER_OFFSET, info))
        }
    }

    function tickUpper(PositionInfo info) internal pure returns (int24 _tickUpper) {
        assembly ("memory-safe") {
            _tickUpper := signextend(2, shr(TICK_UPPER_OFFSET, info))
        }
    }

    function hasSubscriber(PositionInfo info) internal pure returns (bool _hasSubscriber) {
        assembly ("memory-safe") {
            _hasSubscriber := and(MASK_8_BITS, info)
        }
    }

    /// @dev 此函数并不会真正写入任何存储
    function setSubscribe(PositionInfo info) internal pure returns (PositionInfo _info) {
        assembly ("memory-safe") {
            _info := or(info, SET_SUBSCRIBE)
        }
    }

    /// @dev 此函数并不会真正写入任何存储
    function setUnsubscribe(PositionInfo info) internal pure returns (PositionInfo _info) {
        assembly ("memory-safe") {
            _info := and(info, SET_UNSUBSCRIBE)
        }
    }

    /// @notice 创建默认的 PositionInfo 结构
    /// @dev 在铸造新头寸时调用
    /// @param _poolKey 头寸所在池的 PoolKey
    /// @param _tickLower 头寸的下界 tick
    /// @param _tickUpper 头寸的上界 tick
    /// @return info 打包后的头寸信息，包含截断后的 poolId，且 hasSubscriber 标志设为 false
    function initialize(PoolKey memory _poolKey, int24 _tickLower, int24 _tickUpper)
        internal
        pure
        returns (PositionInfo info)
    {
        bytes25 _poolId = bytes25(PoolId.unwrap(_poolKey.toId()));
        assembly {
            info := or(
                or(and(MASK_UPPER_200_BITS, _poolId), shl(TICK_UPPER_OFFSET, and(MASK_24_BITS, _tickUpper))),
                shl(TICK_LOWER_OFFSET, and(MASK_24_BITS, _tickLower))
            )
        }
    }
}
