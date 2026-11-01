// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC20 as SafeERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {PermissionFlag} from "./libraries/PermissionFlags.sol";

contract PermissionsAdapter is ERC20, Ownable2Step, IPermissionsAdapter {
    using SafeTransferLib for SafeERC20;

    /// @inheritdoc IPermissionsAdapter
    address public immutable POOL_MANAGER;

    /// @inheritdoc IPermissionsAdapter
    IERC20 public immutable PERMISSIONED_TOKEN;

    /// @inheritdoc IPermissionsAdapter
    IAllowlistChecker public allowListChecker;

    /// @inheritdoc IPermissionsAdapter
    bool public swappingEnabled;

    /// @inheritdoc IPermissionsAdapter
    mapping(address wrapper => bool) public allowedWrappers;

    /// @inheritdoc IPermissionsAdapter
    mapping(IHooks hook => bool) public allowedHooks;

    constructor(
        IERC20 permissionedToken,
        address poolManager,
        address initialOwner,
        IAllowlistChecker allowListChecker_
    ) ERC20(_getName(permissionedToken), _getSymbol(permissionedToken)) Ownable(initialOwner) {
        PERMISSIONED_TOKEN = permissionedToken;
        POOL_MANAGER = poolManager;
        _updateAllowListChecker(allowListChecker_);
    }

    /// @inheritdoc IPermissionsAdapter
    function wrapToPoolManager(uint256 amount) external {
        if (!allowedWrappers[msg.sender]) revert UnauthorizedWrapper(msg.sender);
        uint256 availableBalance = PERMISSIONED_TOKEN.balanceOf(address(this)) - totalSupply();
        if (amount > availableBalance) revert InsufficientBalance(amount, availableBalance);
        _mint(POOL_MANAGER, amount);
    }

    /// @inheritdoc IPermissionsAdapter
    function depositForVerification(uint256 amount) external {
        SafeERC20(address(PERMISSIONED_TOKEN)).safeTransferFrom(msg.sender, address(this), amount);
        emit VerificationDeposit(msg.sender, amount);
    }

    /// @inheritdoc IPermissionsAdapter
    function updateAllowListChecker(IAllowlistChecker newAllowListChecker) external onlyOwner {
        _updateAllowListChecker(newAllowListChecker);
    }

    /// @inheritdoc IPermissionsAdapter
    function updateAllowedWrapper(address wrapper, bool allowed) external onlyOwner {
        _updateAllowedWrapper(wrapper, allowed);
    }

    /// @inheritdoc IPermissionsAdapter
    function updateAllowedHook(IHooks hook, bool allowed) external onlyOwner {
        _updateAllowedHook(hook, allowed);
    }

    /// @inheritdoc IPermissionsAdapter
    function updateSwappingEnabled(bool enabled) external onlyOwner {
        _updateSwappingEnabled(enabled);
    }

    /// @inheritdoc IPermissionsAdapter
    function isAllowed(address account, PermissionFlag permission) public view returns (bool) {
        return ((allowListChecker.checkAllowlist(account, address(PERMISSIONED_TOKEN))) & (permission)) == (permission);
    }

    function _updateAllowListChecker(IAllowlistChecker newAllowListChecker) internal {
        if (!ERC165Checker.supportsInterface(address(newAllowListChecker), type(IAllowlistChecker).interfaceId)) {
            revert InvalidAllowListChecker(newAllowListChecker);
        }
        allowListChecker = newAllowListChecker;
        emit AllowListCheckerUpdated(newAllowListChecker);
    }

    function _updateAllowedWrapper(address wrapper, bool allowed) internal {
        allowedWrappers[wrapper] = allowed;
        emit AllowedWrapperUpdated(wrapper, allowed);
    }

    function _updateAllowedHook(IHooks hook, bool allowed) internal {
        bool oldAllowed = allowedHooks[hook];
        if (oldAllowed == allowed) return;
        allowedHooks[hook] = allowed;
        emit AllowedHookUpdated(hook, allowed);
    }

    function _updateSwappingEnabled(bool enabled) internal {
        swappingEnabled = enabled;
        emit SwappingEnabledUpdated(enabled);
    }

    /// @dev 重写 ERC20._update 函数，加入以下检查和逻辑：
    /// - 在 PoolManager 上调用 `settle` 之前，先存入许可代币，并向 PoolManager 铸造权限适配器（代币）
    /// - 在 PoolManager 上调用 `take` 时，PoolManager 将权限适配器（代币）转给接收者，此时许可代币会被自动释放
    /// - 强制要求 PoolManager 是权限适配器（代币）的唯一持有者
    function _update(address from, address to, uint256 amount) internal override {
        if (to == address(0)) {
            // 防止销毁时出现无限循环
            super._update(from, to, amount);
            return;
        }
        if (from == address(0)) {
            assert(to == POOL_MANAGER);
            // 正在存入许可代币
            super._update(from, to, amount);
            return;
        } else if (from != POOL_MANAGER) {
            // 如果发送方是 PoolManager，许可代币会被自动释放，跳过这些检查
            revert InvalidTransfer(from, to);
        }
        // 拒绝自我转账：否则会把原始底层代币解包到 PoolManager 中
        if (to == POOL_MANAGER) revert InvalidTransfer(from, to);
        super._update(from, to, amount);
        _unwrap(to, amount);
        // PoolManager 必须始终是权限适配器（代币）的唯一持有者
        assert(balanceOf(POOL_MANAGER) == totalSupply());
    }

    function _unwrap(address account, uint256 amount) internal {
        _burn(account, amount);
        SafeERC20(address(PERMISSIONED_TOKEN)).safeTransfer(account, amount);
    }

    /// @dev 底层 staticcall + ABI 布局校验。try/catch 无法捕获返回数据的解码失败，
    /// 因此对于返回 bytes32（MKR 风格）或其它非 string 形式的代币，必须显式检查。
    function _readString(address token, bytes4 selector, string memory fallback_) private view returns (string memory) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length < 64) return fallback_;
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            length := mload(add(data, 0x40))
        }
        if (offset != 0x20 || length == 0 || length > data.length - 64) return fallback_;
        return abi.decode(data, (string));
    }

    function _getName(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat(
            "Uniswap v4 ", _readString(address(permissionedToken), IERC20Metadata.name.selector, "Permissioned Token")
        );
    }

    function _getSymbol(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat("v4", _readString(address(permissionedToken), IERC20Metadata.symbol.selector, "PT"));
    }

    function decimals() public view override returns (uint8) {
        (bool ok, bytes memory data) =
            address(PERMISSIONED_TOKEN).staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || data.length < 32) return 18;
        uint256 value = abi.decode(data, (uint256));
        return value > type(uint8).max ? 18 : uint8(value);
    }

    function owner() public view override(Ownable, IPermissionsAdapter) returns (address) {
        return super.owner();
    }

    /// @notice 已禁用。适配器必须始终有所有者。
    /// @dev 零地址所有者会永久禁用发行方的强制退出功能：`unwindPosition` 针对池的两种代币
    ///      都以 `_getOwner` 作为授权依据，且其按代币的回退路径也会转到同一个
    ///      所有者。没有所有者时，强制退出对任何调用者都会以 `Unauthorized` 回滚（revert），且每次失败的
    ///      平仓（unwind）反而会向被退出的 LP 铸造一个可自由转让的、基于本适配器的 ERC-6909 凭证（claim）。
    ///      `Ownable2Step` 已能防止经由 `transferOwnership` 丢失所有权，因为若新所有者不调用
    ///      `acceptOwnership`，转移就无法完成；放弃所有权是唯一剩下的让所有者变为零地址的途径。
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
