// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IEIP712_v4
/// @notice EIP712 合约的接口
interface IEIP712_v4 {
    /// @notice 返回当前链的域分隔符（domain separator）。
    /// @return bytes32 域分隔符
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
