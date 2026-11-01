// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// PositionConfig 是在 core 中创建和修改头寸（Position）的输入，其截断哈希按 tokenId 逐个设置
struct PositionConfig {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
}

/// @notice 根据 PositionConfig 结构体计算 PositionConfigId 的库
library PositionConfigLibrary {
    function toId(PositionConfig calldata config) internal pure returns (bytes32 id) {
        // id = keccak256(abi.encodePacked(currency0, currency1, fee, tickSpacing, hooks, tickLower, tickUpper))) >> 1
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x34), calldataload(add(config, 0xc0))) // tickUpper: [0x51, 0x54)
            mstore(add(fmp, 0x31), calldataload(add(config, 0xa0))) // tickLower: [0x4E, 0x51)
            mstore(add(fmp, 0x2E), calldataload(add(config, 0x80))) // hooks: [0x3A, 0x4E)
            mstore(add(fmp, 0x1A), calldataload(add(config, 0x60))) // tickSpacing: [0x37, 0x3A)
            mstore(add(fmp, 0x17), calldataload(add(config, 0x40))) // fee: [0x34, 0x37)
            mstore(add(fmp, 0x14), calldataload(add(config, 0x20))) // currency1: [0x20, 0x34)
            mstore(fmp, calldataload(config)) // currency0: [0x0c, 0x20)

            id := shr(1, keccak256(add(fmp, 0x0c), 0x48)) // 长度为 72 字节，截去哈希的最低位

            // 现在清理我们用过的内存
            mstore(add(fmp, 0x40), 0) // fmp+0x40 处存放了 hooks（14 字节）、tickLower、tickUpper
            mstore(add(fmp, 0x20), 0) // fmp+0x20 处存放了 currency1、fee、tickSpacing、hooks（6 字节）
            mstore(fmp, 0) // fmp 处存放了 currency0
        }
    }
}
