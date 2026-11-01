// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "./IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./IAllowlistChecker.sol";

interface IPermissionsAdapterFactory {
    /// @notice 创建权限适配器时触发
    event PermissionsAdapterCreated(address indexed permissionsAdapter, address indexed permissionedToken);

    /// @notice 权限适配器通过验证时触发
    event PermissionsAdapterVerified(address indexed permissionsAdapter, address indexed permissionedToken);

    /// @notice 当权限适配器不存在时抛出
    error PermissionsAdapterNotFound(address permissionsAdapter);

    /// @notice 当权限适配器已通过验证时抛出
    error PermissionsAdapterAlreadyVerified(address permissionsAdapter);

    /// @notice 当权限适配器未通过验证时抛出
    error PermissionsAdapterNotVerified(address permissionsAdapter);

    /// @notice 创建一个新的权限适配器
    /// @param permissionedToken 要包装的许可代币
    /// @param initialOwner 权限适配器的初始所有者
    /// @param allowListChecker 用于检查转账是否被允许的白名单检查器
    function createPermissionsAdapter(
        IERC20 permissionedToken,
        address initialOwner,
        IAllowlistChecker allowListChecker
    ) external returns (address);

    /// @notice 验证权限适配器
    /// @param permissionsAdapter 权限适配器
    /// @dev 本函数验证权限适配器持有许可代币的余额。这意味着该权限适配器已在许可代币的白名单中，可用于包装和解包许可代币。
    function verifyPermissionsAdapter(address permissionsAdapter) external;

    /// @notice 返回权限适配器对应的许可代币
    /// @param permissionsAdapter 权限适配器
    /// @return permissionedToken 许可代币
    function permissionsAdapterOf(address permissionsAdapter) external view returns (address permissionedToken);

    /// @notice 返回权限适配器对应的已验证许可代币
    /// @param permissionsAdapter 权限适配器
    /// @return permissionedToken 已验证的许可代币
    /// @dev 需要对许可代币进行反向查找，否则任何人都可以为非许可代币创建权限适配器
    function verifiedPermissionsAdapterOf(address permissionsAdapter) external view returns (address permissionedToken);

    /// @notice 返回 v4 的 PoolManager
    /// @return poolManager v4 的 PoolManager
    function POOL_MANAGER() external view returns (address poolManager);
}
