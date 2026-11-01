// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title IPermit2Forwarder
/// @notice Permit2Forwarder 合约的接口
interface IPermit2Forwarder {
    /// @notice 允许将单个许可（permit）转发给 Permit2
    /// @dev 该函数声明为 payable，以便与基于 NATIVE 的操作（action）一起进行 multicall
    /// @param owner 代币的所有者
    /// @param permitSingle 许可（permit）数据
    /// @param signature 该许可的签名；abi.encodePacked(r, s, v)
    /// @return err 许可调用回滚（revert）时返回的错误数据，成功时为空
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        external
        payable
        returns (bytes memory err);

    /// @notice 允许将批量许可（permit）转发给 Permit2
    /// @dev 该函数声明为 payable，以便与基于 NATIVE 的操作（action）一起进行 multicall
    /// @param owner 代币的所有者
    /// @param _permitBatch 一批授权
    /// @param signature 该许可的签名；abi.encodePacked(r, s, v)
    /// @return err 许可调用回滚（revert）时返回的错误数据，成功时为空
    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata _permitBatch, bytes calldata signature)
        external
        payable
        returns (bytes memory err);
}
