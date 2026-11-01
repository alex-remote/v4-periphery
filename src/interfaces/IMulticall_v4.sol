// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IMulticall_v4
/// @notice Multicall_v4 合约的接口
interface IMulticall_v4 {
    /// @notice 调用当前合约中的多个函数，若全部成功则返回所有调用的返回数据
    /// @dev `msg.value` 会传递给所有子调用，即使之前的子调用已经消耗了这些 ether。
    /// 子调用可以改用 `address(this).value` 查看可用的 ETH，并通过 {value: x} 来使用它。
    /// @param data 要对本合约发起的每个调用的编码函数数据
    /// @return results 通过 data 传入的每个调用的返回结果
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
