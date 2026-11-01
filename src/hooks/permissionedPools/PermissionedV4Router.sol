// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {V4Router, IPoolManager, Currency, PoolKey} from "../../V4Router.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {PermissionFlags} from "./libraries/PermissionFlags.sol";

/// @title 支持许可 V4 池的路由器的抽象基合约
/// @notice 提供 _pay 与 _mapSettleAmount 的重写，用于包装/解包许可代币。
///         具体的路由器（例如 UniversalRouter 的 V4SwapRouter）继承本合约。
abstract contract PermissionedV4Router is V4Router {
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    error Unauthorized();
    error SwappingDisabled();
    error HookNotAllowed();

    constructor(IPoolManager poolManager_, IPermissionsAdapterFactory permissionsAdapterFactory)
        V4Router(poolManager_)
    {
        PERMISSIONS_ADAPTER_FACTORY = permissionsAdapterFactory;
    }

    /// @inheritdoc V4Router
    /// @dev 许可池的权限控制由其 hook 执行，因此对于包含
    ///      已验证适配器的池，除非适配器的所有者已将该 hook 加入白名单，否则不得
    ///      通过它进行兑换（swap）。仅拒绝 `address(0)` 是不够的 —— 无操作的 hook，或挖出的不带
    ///      `BEFORE_SWAP_FLAG` 的地址，否则都会通过检查。
    function _validatePoolKey(PoolKey memory poolKey) internal view override {
        if (address(PERMISSIONS_ADAPTER_FACTORY) == address(0)) return;
        _validateHook(poolKey.currency0, poolKey.hooks);
        _validateHook(poolKey.currency1, poolKey.hooks);
    }

    /// @notice 若 `currency` 是已验证的权限适配器且未将 `hooks` 加入白名单，则回滚（revert）
    function _validateHook(Currency currency, IHooks hooks) internal view {
        if (PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency)) == address(0)) return;
        if (!IPermissionsAdapter(Currency.unwrap(currency)).allowedHooks(hooks)) revert HookNotAllowed();
    }

    function _take(Currency currency, address recipient, uint256 amount) internal virtual override {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));

        // 若该代币是许可代币，则校验兑换功能已启用且发送者被允许兑换
        if (permissionedToken != address(0)) {
            IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
            if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
            if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) revert Unauthorized();
        }

        super._take(currency, recipient, amount);
    }

    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            _payStandard(currency, payer, amount);
            return;
        }
        // 该代币是许可代币，包装该代币并将其转给 PoolManager
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
            permissionsAdapter.wrapToPoolManager(amount);
        } else {
            _payPermissionedFromPayer(payer, permissionsAdapter, permissionedToken, amount);
        }
    }

    /// @notice 供具体路由器实现的扩展点（hook）：标准（非许可）付款
    function _payStandard(Currency currency, address payer, uint256 amount) internal virtual;

    /// @notice 供具体路由器实现的扩展点（hook）：从付款方到适配器的转账（例如通过 Permit2）
    function _payPermissionedFromPayer(
        address payer,
        IPermissionsAdapter permissionsAdapter,
        address permissionedToken,
        uint256 amount
    ) internal virtual;

    /// @notice 计算结算操作（settle action）的数量
    function _mapSettleAmount(uint256 amount, Currency currency) internal view virtual override returns (uint256) {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        // 除非该代币是在路由器上持有余额的许可代币，否则使用默认实现
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }
}
