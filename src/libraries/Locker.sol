// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 这是一个临时库，让我们能够使用瞬态存储（tstore/tload）
/// TODO: 等 solidity 支持 transient 关键字后，即可删除此库。
library Locker {
    // 以瞬态方式保存锁定者状态的槽位。bytes32(uint256(keccak256("LockedBy")) - 1)
    bytes32 constant LOCKED_BY_SLOT = 0x0aedd6bde10e3aa2adec092b02a3e3e805795516cda41f27aa145b8f300af87a;

    function set(address locker) internal {
        assembly {
            tstore(LOCKED_BY_SLOT, locker)
        }
    }

    function get() internal view returns (address locker) {
        assembly {
            locker := tload(LOCKED_BY_SLOT)
        }
    }
}
