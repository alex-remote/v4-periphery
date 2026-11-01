// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice 不符合规范的 PoolManager 替身，其批量 extsload 返回的字（word）数少于请求的数量，
///         例如新链上地址错误或代理实现不一致的情况
contract MockShortExtsloadManager {
    /// @dev 单槽读取报告一个已初始化的池（sqrtPriceX96 = 2^96，tick 0），使扫描得以继续
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1) << 96);
    }

    function extsload(bytes32[] calldata) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }
}
