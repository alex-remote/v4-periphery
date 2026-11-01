// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowlistChecker, PermissionFlag} from "./IAllowlistChecker.sol";

interface IPermissionsAdapter is IERC20 {
    /// @notice 白名单检查器更新时触发
    event AllowListCheckerUpdated(IAllowlistChecker indexed newAllowListChecker);

    /// @notice 允许的包装者（wrapper）更新时触发
    event AllowedWrapperUpdated(address indexed wrapper, bool allowed);

    /// @notice 允许的 hook 更新时触发
    event AllowedHookUpdated(IHooks indexed hook, bool allowed);

    /// @notice 兑换（swap）启用状态更新时触发
    event SwappingEnabledUpdated(bool enabled);

    /// @notice 许可代币作为验证信号存入本适配器时触发
    /// @dev 提供一个可过滤的信号，表明资产发行方已将本适配器加入白名单，而无需依赖普通的 ERC20 Transfer 事件
    event VerificationDeposit(address indexed depositor, uint256 amount);

    /// @notice 当白名单检查器未实现 IAllowListChecker 接口时抛出
    error InvalidAllowListChecker(IAllowlistChecker newAllowListChecker);

    /// @notice 当转账未与 PoolManager 交互时抛出
    error InvalidTransfer(address from, address to);

    /// @notice 当包装者无权在权限适配器上触发转账时抛出
    error UnauthorizedWrapper(address wrapper);

    /// @notice 当可用于包装的许可代币数量不足时抛出
    error InsufficientBalance(uint256 amount, uint256 availableBalance);

    /// @notice 尝试放弃所有权时抛出；适配器必须始终有所有者
    error RenounceDisabled();

    /// @notice 将许可代币包装后转给 PoolManager
    /// @param amount 要包装的许可代币数量
    /// @dev 只能由允许的包装者调用
    /// @dev 调用本函数之前，必须先把 `amount` 发送到本合约
    function wrapToPoolManager(uint256 amount) external;

    /// @notice 将许可代币存入本适配器，作为链上验证信号
    /// @param amount 要从调用者处拉取的许可代币数量
    /// @dev 应由资产发行方在本适配器被加入许可代币的白名单后调用。
    /// 会触发 `VerificationDeposit` 事件，使链下观察者有专门的事件可供过滤。由此产生的余额也
    /// 能满足 `PermissionsAdapterFactory.verifyPermissionsAdapter` 所用的链上检查。
    function depositForVerification(uint256 amount) external;

    /// @notice 更新白名单检查器
    /// @param newAllowListChecker 新的白名单检查器
    /// @dev 只能由所有者调用
    function updateAllowListChecker(IAllowlistChecker newAllowListChecker) external;

    /// @notice 更新可包装许可代币的允许包装者
    /// @param wrapper 要更新的包装者
    /// @param allowed 该包装者是否被允许
    /// @dev 只能由所有者调用
    /// @dev 为确保权限适配器（代币）无法在 PoolManager 上被包装成 ERC6909 代币，包装者只能实现 `swap` 或 `modifyLiquidity` 函数
    function updateAllowedWrapper(address wrapper, bool allowed) external;

    /// @notice 更新允许的 hook
    /// @param hook 要更新的 hook
    /// @param allowed 该 hook 是否被允许
    /// @dev 只能由所有者调用
    /// @dev 撤销某个 hook 会阻止使用该 hook 的头寸今后的铸造和增加流动性操作。减少流动性
    /// 和销毁则被有意保持开放，以便持有者始终能够退出已有头寸。
    function updateAllowedHook(IHooks hook, bool allowed) external;

    /// @notice 更新兑换（swap）启用状态
    /// @param enabled 是否启用兑换
    /// @dev 只能由所有者调用
    function updateSwappingEnabled(bool enabled) external;

    /// @notice 返回转账是否被允许
    /// @param account 要检查的账户
    function isAllowed(address account, PermissionFlag permission) external view returns (bool);

    /// @notice 返回白名单检查器
    function allowListChecker() external view returns (IAllowlistChecker);

    /// @notice 返回可包装许可代币的允许包装者
    /// @dev 例如许可池的 PoolManager、报价器或 swap 路由器
    /// @dev 包装者必须如实报告 `msgSender()`，以维持权限保证。
    function allowedWrappers(address wrapper) external view returns (bool);

    /// @notice 返回某个 hook 是否被允许
    /// @param hook 要检查的 hook
    /// @dev 对于由两个适配器配对组成的池，两个适配器都必须授权该 hook
    function allowedHooks(IHooks hook) external view returns (bool);

    /// @notice 返回兑换（swap）启用状态
    function swappingEnabled() external view returns (bool);

    /// @notice 返回 Uniswap v4 的 PoolManager
    function POOL_MANAGER() external view returns (address);

    /// @notice 返回存入本合约的许可代币
    function PERMISSIONED_TOKEN() external view returns (IERC20);

    /// @notice 返回权限适配器的管理员
    function owner() external view returns (address);
}
