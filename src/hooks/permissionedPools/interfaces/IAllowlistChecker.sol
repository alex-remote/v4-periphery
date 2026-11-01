// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PermissionFlag} from "../libraries/PermissionFlags.sol";

interface IAllowlistChecker is IERC165 {
    /// @notice 返回 `account` 针对 `tokenAddress` 的权限标志
    /// @param account 被检查白名单状态的账户
    /// @param tokenAddress 本次检查所针对的许可代币
    /// @dev `tokenAddress` 使单个白名单检查器可以服务多种资产，而无需额外往返调用适配器
    function checkAllowlist(address account, address tokenAddress) external view returns (PermissionFlag);
}
