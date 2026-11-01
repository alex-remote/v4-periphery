// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice 不符合规范的 PoolManager 替身，可返回任意存储值，用于证明 lens（查询合约）的
///         不变量检查会把不一致的状态（例如新链上 StateLibrary 的存储布局漂移）转化为显式的
///         回滚（revert），而不是悄无声息地给出错误的 TVL
contract MockSettableExtsloadManager {
    mapping(bytes32 => bytes32) internal slots;

    function set(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function extsload(bytes32[] calldata query) external view returns (bytes32[] memory values) {
        values = new bytes32[](query.length);
        for (uint256 i; i < query.length; i++) {
            values[i] = slots[query[i]];
        }
    }
}
