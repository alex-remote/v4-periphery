// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PositionManager,
    PoolKey,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    Currency
} from "../../PositionManager.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PermissionFlags} from "./libraries/PermissionFlags.sol";
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {Actions} from "../../libraries/Actions.sol";
import {CalldataDecoder} from "../../libraries/CalldataDecoder.sol";

contract PermissionedPositionManager is PositionManager {
    using CalldataDecoder for bytes;

    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    /// @notice 在 `_tryDeliverAsset` 中每次实际资产交付尝试所转发的 gas。
    ///         用于限制恶意接收者每次尝试最多可消耗的 gas。
    uint256 public immutable DELIVERY_GAS_LIMIT;

    event CurrencyUnwound(
        uint256 indexed tokenId,
        Currency indexed currency,
        address indexed recipient,
        address caller,
        address lp,
        uint256 amount,
        bool asClaim
    );
    event ClaimWithdrawn(Currency indexed currency, address indexed from, address indexed to, uint256 amount);

    error InvalidHook();
    error TransferDisabled();
    error NoVerifiedAdapter();
    error NonContractCurrency();

    /// @dev 由于本合约必须预先知道 hooks 地址，因此必须将其作为构造函数参数传入
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IPermissionsAdapterFactory _permissionsAdapterFactory,
        uint256 _deliveryGasLimit
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        PERMISSIONS_ADAPTER_FACTORY = _permissionsAdapterFactory;
        DELIVERY_GAS_LIMIT = _deliveryGasLimit;
        /// @dev EIP712 域分隔符仍使用 "Uniswap v4 Positions NFT" 作为名称
        name = "Uniswap v4 Permissioned Positions NFT";
        symbol = "UNI-V4-PERM-POSM";
    }

    /// @notice 强制 LP 退出头寸。销毁 NFT、解除（unwind）流动性，并交付每种代币。
    /// @dev 任一 PA 管理员均可调用。首先销毁头寸，并将两种代币以 ERC-6909 凭证（claim）的形式结算给
    ///      本合约；铸造凭证不会转移任何代币，因此不会执行任何由 LP 控制的代码，这一步也就不可能被
    ///      卡死（brick）。随后将每份凭证作为实际资产交付给 LP，失败时回退为交付给管理员，每次交付都在各自
    ///      独立的 unlock 中进行且 gas 上限为 `DELIVERY_GAS_LIMIT`；若接收者回滚（revert）、遗留未结清的 delta 或耗尽
    ///      其受限的 gas，只会导致它自己的那次交付失败，此时改为把 6909 凭证交给 LP（或管理员）
    ///      （见 `_deliverCurrency`）。每一笔（leg）发出一个 `CurrencyUnwound` 事件。
    /// @param tokenId 要解除的头寸
    /// @param amount0Min 销毁必须返回的 currency0 最小数量；为 0 时禁用该检查
    /// @param amount1Min 销毁必须返回的 currency1 最小数量；为 0 时禁用该检查
    /// @param hookData 移除流动性时转发给该池的 hook，供需要它的 hook 扩展使用
    /// @dev 非零下限会使销毁在低于下限时回滚（revert），而不是照常执行。
    /// @dev 在销毁之前先取消订阅，因此订阅者会收到 notifyUnsubscribe，但不会收到 notifyBurn。
    function unwindPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        external
        isNotLocked
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address admin0 = _getOwner(poolKey.currency0);
        address admin1 = _getOwner(poolKey.currency1);
        if (msg.sender != admin0 && msg.sender != admin1) revert Unauthorized();

        address lp = ownerOf(tokenId);

        // 在 PoolManager 锁定状态下取消订阅，使 notifyUnsubscribe 无法遗留未结清的 delta 而卡死 unlock。
        if (positionInfo[tokenId].hasSubscriber()) {
            _unsubscribe(tokenId);
            // 处于锁定状态的回调仍可通过 subscribe 重新挂载订阅者；将其清除，使会回滚的 notifyBurn 无法卡死销毁。
            // 故意不调用其 notifyUnsubscribe（订阅者由攻击者选定），但仍发出 Unsubscription 事件，使索引器的事件保持配对。
            if (positionInfo[tokenId].hasSubscriber()) {
                address reattached = address(subscriber[tokenId]);
                delete subscriber[tokenId];
                _setUnsubscribed(tokenId);
                emit Unsubscription(tokenId, reattached);
            }
        }

        // 进行授权，使 BURN_POSITION 能通过 onlyIfApproved 检查。
        // ERC-721 的 _burn 在清理过程中会清除 getApproved，因此该授权会自动清除。
        getApproved[tokenId] = msg.sender;

        // 销毁头寸；将两种代币以 6909 凭证的形式结算给本合约。
        bytes memory actions =
            abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.MINT_6909), uint8(Actions.MINT_6909));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);
        poolManager.unlock(abi.encode(actions, params));

        // 读取完整的 6909 余额，而非销毁产生的 delta：即销毁产出，加上任何滞留在本合约中的
        // 零散 MINT_6909 凭证。
        uint256 amount0 = poolManager.balanceOf(address(this), poolKey.currency0.toId());
        uint256 amount1 = poolManager.balanceOf(address(this), poolKey.currency1.toId());

        // 先向 LP 交付实际资产，再尝试管理员；若遭遇任何恶意消耗（griefing），则改为移交 6909 凭证。
        _deliverCurrency(poolKey.currency0, lp, tokenId, amount0);
        _deliverCurrency(poolKey.currency1, lp, tokenId, amount1);
    }

    /// @notice 销毁 PoolManager 上的 ERC-6909 凭证，并将底层代币转给 `to`。
    /// @dev 调用者必须持有该凭证，或已调用 PoolManager.setOperator(permPosm, true)。对于许可
    ///      代币，`to` 在解包时必须通过底层代币发行方的合规检查。`to` 遵循
    ///      标准的 `Actions.TAKE` 接收者哨兵值：`address(1)` 映射为调用者，`address(2)` 映射为本
    ///      合约。哨兵值会在底层代币交付及 `ClaimWithdrawn` 事件之前完成解析。
    /// @param currency 要销毁其 6909 凭证的代币
    /// @param amount 要销毁的凭证数量（也即要交付的底层代币数量）
    /// @param to 底层代币的接收者
    function withdrawClaim(Currency currency, uint256 amount, address to) external isNotLocked {
        address resolvedTo = _mapRecipient(to);
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(currency, msg.sender, amount);
        params[1] = abi.encode(currency, resolvedTo, amount);
        poolManager.unlock(abi.encode(actions, params));

        emit ClaimWithdrawn(currency, msg.sender, resolvedTo, amount);
    }

    /// @inheritdoc PositionManager
    /// @dev 许可代币的头寸不可转移。
    function transferFrom(address from, address to, uint256 id) public override onlyIfPoolManagerLocked {
        revert TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256) public pure override {
        revert TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) public pure override {
        revert TransferDisabled();
    }

    /// @dev 铸造头寸时，校验发送者是否被允许铸造该头寸。这可防止未获许可的用户铸造单边流动性。
    ///      同时拒绝两侧都不是已验证权限适配器的池 —— 这类头寸相比基础 PositionManager 不提供任何
    ///      权限管控价值，而且否则还会永久不可转移
    ///      （见 `transferFrom`），因此本合约拒绝铸造它们。
    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal override {
        // 校验每种代币；要求至少有一种是已验证的权限适配器。
        bool verified0 = _validateLiquidityCurrency(poolKey.currency0, poolKey.hooks, owner);
        bool verified1 = _validateLiquidityCurrency(poolKey.currency1, poolKey.hooks, owner);
        if (!verified0 && !verified1) revert NoVerifiedAdapter();
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev 每次增加流动性时都重新校验 hook 白名单，使已被撤销的 hook 无法
    ///      继续在现有头寸上接收新的资金流入。同时重新检查头寸所有者
    ///      对每种许可代币是否仍满足 `LIQUIDITY_ALLOWED`。减少流动性和销毁路径
    ///      有意不做检查，使持有者即使在其
    ///      权限或 hook 被撤销之后，也始终能够退出头寸。
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal override {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address owner = ownerOf(tokenId);
        _validateLiquidityCurrency(poolKey.currency0, poolKey.hooks, owner);
        _validateLiquidityCurrency(poolKey.currency1, poolKey.hooks, owner);
        super._increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
    }

    /// @dev 见 `_increase` —— 基于 delta 的变体（from-deltas）理由相同。
    function _increaseFromDeltas(uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
        internal
        override
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address owner = ownerOf(tokenId);
        _validateLiquidityCurrency(poolKey.currency0, poolKey.hooks, owner);
        _validateLiquidityCurrency(poolKey.currency1, poolKey.hooks, owner);
        super._increaseFromDeltas(tokenId, amount0Max, amount1Max, hookData);
    }

    /// @notice 针对增加流动性的操作校验 `currency`，并返回其是否为已验证的适配器。
    /// @dev 普通代币直接通过。由工厂创建的适配器必须已经过验证 —— 否则它在此处会被当作
    ///      普通代币，跳过其 hook/`LIQUIDITY_ALLOWED` 检查，之后再通过验证被激活。已
    ///      验证的适配器必须允许 `hooks`，且所有者必须满足 `LIQUIDITY_ALLOWED`。
    function _validateLiquidityCurrency(Currency currency, IHooks hooks, address owner)
        internal
        view
        returns (bool isVerifiedAdapter)
    {
        address currencyAddress = Currency.unwrap(currency);
        if (_verifiedPermissionedTokenOf(currency) == address(0)) {
            if (PERMISSIONS_ADAPTER_FACTORY.permissionsAdapterOf(currencyAddress) != address(0)) {
                revert NoVerifiedAdapter();
            }
            // 非适配器代币必须是真实存在的合约（原生 ETH 除外）
            if (currencyAddress != address(0) && currencyAddress.code.length == 0) revert NonContractCurrency();
            return false;
        }
        IPermissionsAdapter adapter = IPermissionsAdapter(currencyAddress);
        if (!adapter.allowedHooks(hooks)) revert InvalidHook();
        if (!adapter.isAllowed(owner, PermissionFlags.LIQUIDITY_ALLOWED)) revert Unauthorized();
        return true;
    }

    /// @dev 为结算付款时，若该代币是许可代币，则包装该代币并将其转给 PoolManager。
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) {
            // 该代币不是许可代币，使用默认实现
            super._pay(currency, payer, amount);
            return;
        }
        // 该代币是许可代币，包装该代币并将其转给 PoolManager
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        // 检查实际用户的流动性权限
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
        } else {
            permit2.transferFrom(payer, address(permissionsAdapter), uint160(amount), permissionedToken);
        }
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function _verifiedPermissionedTokenOf(Currency currency) internal view returns (address) {
        return PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
    }

    /// @notice 计算结算操作（settle action）的数量
    function _mapSettleAmount(uint256 amount, Currency currency) internal view override returns (uint256) {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }

    /// @dev 当以适配器代币向本合约执行 TAKE 时，适配器的
    /// _update hook 会解包适配器代币，因此本合约最终持有的是底层
    /// 许可代币 —— 而不是适配器代币。清扫（sweep）底层代币，以避免遗留
    /// 可被后续调用者领取的代币。
    function _sweep(Currency currency, address to) internal override {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) {
            super._sweep(currency, to);
            return;
        }
        Currency underlying = Currency.wrap(permissionedToken);
        uint256 balance = underlying.balanceOfSelf();
        if (balance > 0) underlying.transfer(to, balance);
    }

    function _getOwner(Currency currency) internal view returns (address) {
        address permissionsAdapter = Currency.unwrap(currency);
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return address(0);
        return IPermissionsAdapter(permissionsAdapter).owner();
    }

    /// @dev 处理由 `unwindPosition` 分派的两个解除操作（MINT_6909 和 UNWIND_WITH_FALLBACK），
    ///      以及 `withdrawClaim` 使用的 BURN_6909 原语。其它所有操作都交由基础
    ///      PositionManager 分派器处理。
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == Actions.MINT_6909) {
            // 将本合约在 `currency` 上的全部正 delta 以 6909 凭证的形式结算给本合约自身。
            Currency currency = params.decodeCurrency();
            poolManager.mint(address(this), currency.toId(), _getFullCredit(currency));
            return;
        }
        if (action == Actions.UNWIND_WITH_FALLBACK) {
            // 销毁本合约持有的 `currency` 凭证，并将实际资产提取到 `to`。
            (Currency currency, address to, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, to, amount);
            return;
        }
        if (action == Actions.BURN_6909) {
            (Currency currency, address from, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            // 销毁前校验凭证所有者就是该操作的执行者
            if (from != msgSender()) revert Unauthorized();
            poolManager.burn(from, currency.toId(), amount);
            return;
        }
        super._handleAction(action, params);
    }

    /// @notice 将 `amount` 数量的 `currency`（以 6909 凭证形式持有）交付给 LP，失败则交付给管理员，再不行则移交
    ///         凭证。每次尝试都是一次独立的 unlock，gas 上限为 `DELIVERY_GAS_LIMIT`，因此会回滚或大量消耗 gas 的
    ///         接收者只会导致它自己那一笔（leg）失败。每一笔发出一个 `CurrencyUnwound` 事件。
    function _deliverCurrency(Currency currency, address lp, uint256 tokenId, uint256 amount) internal {
        if (amount == 0) return;

        // 向 LP 交付实际资产。
        if (_tryDeliverAsset(currency, lp, amount)) {
            emit CurrencyUnwound(tokenId, currency, lp, msg.sender, lp, amount, false);
            return;
        }
        // 然后尝试管理员（仅限许可代币；放弃所有权（renounce）已被禁用，因此许可代币的管理员永远不会是零地址）。
        address admin = _getOwner(currency);
        if (admin != address(0) && _tryDeliverAsset(currency, admin, amount)) {
            emit CurrencyUnwound(tokenId, currency, admin, msg.sender, lp, amount, false);
            return;
        }
        // 两者都拒收：移交 6909 凭证（不会执行任何代币代码）。许可代币移交给管理员（LP
        // 不合规），否则移交给 LP。
        address claimTo = admin == address(0) ? lp : admin;
        poolManager.transfer(claimTo, currency.toId(), amount);
        emit CurrencyUnwound(tokenId, currency, claimTo, msg.sender, lp, amount, true);
    }

    /// @notice 尝试在一次独立的 unlock 中，将 `amount` 数量 `currency` 的实际资产交付给 `to`（销毁
    ///         本合约的凭证，提取到 `to`），最多转发 `DELIVERY_GAS_LIMIT` gas。若
    ///         `to` 回滚、遗留未结清的 delta 或耗尽受限的 gas，则返回 false，此时没有交付任何资产，
    ///         本合约仍持有该凭证。
    function _tryDeliverAsset(Currency currency, address to, uint256 amount) internal returns (bool) {
        bytes memory actions = abi.encodePacked(uint8(Actions.UNWIND_WITH_FALLBACK));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currency, to, amount);
        try poolManager.unlock{gas: DELIVERY_GAS_LIMIT}(abi.encode(actions, params)) {
            return true;
        } catch {
            return false;
        }
    }
}
