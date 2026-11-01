// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PositionConfig} from "../../shared/PositionConfig.sol";
import {PermissionedPositionManagerTest} from "./PermissionedPositionManager.t.sol";
import {MockPermissionedToken, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {PermissionFlags} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {
    IPermissionsAdapter,
    IERC20 as IERC20Adapter
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice LP 为自己创建并管理的 PA 提供的“底层”代币。`transfer` 是无条件触发的：每一次
///         调用（而非一次性的“arm/disarm”开关触发）都会把 gas 消耗到一个极低的下限，然后回滚。
///         `transferFrom` 保持不变，因此初始化（permit2 存入、`depositForVerification`）仍能正常工作——
///         只有交付过程中走到的 `_unwrap` -> `safeTransfer` 路径是恶意的。
contract GasGuzzlerPermUnderlying is MockPermissionedToken {
    error Grief();

    /// @dev 足够小，使循环几乎耗尽所有转发进来的 gas，但又刚好留出足够的 gas，
    ///      让自定义错误的回滚本身得以完成，而不会在操作码执行中途因“gas 耗尽”而直接中止。
    uint256 public constant FLOOR = 5_000;

    function transfer(address, uint256) public override returns (bool) {
        while (gasleft() > FLOOR) {} // 无条件地烧掉转发给本次调用的几乎全部 gas
        revert Grief();
    }
}

/// @title 针对 unwindPosition 按代币级联交付的 gas 恶意消耗（griefing）PoC 及其修复验证
/// @dev 攻击者既是 LP，又是其自建 PermissionsAdapter 的管理员，因此 `_deliverCurrency` 中
///      先 `to = lp`、再 `to = admin` 的两次尝试都会命中恶意代币的 `transfer`。修复前，每次
///      尝试都会发起一次不设 gas 上限的 `poolManager.unlock`，于是在 EIP-150 的 63/64 转发规则下，被恶意消耗的环节会烧掉
///      剩余 gas 的大部分；环节足够多时，就能让后续交付以及移交 claim 的回退路径因 gas 不足而失败。修复后，
///      `_tryDeliverAsset` 每次尝试最多转发 `DELIVERY_GAS_LIMIT`，因此每个环节的消耗都有上界，
///      回退路径的开销也始终可承受；下面两个场景在每个 gas 水平下都能成功。
contract UnwindGasGriefPoC is PermissionedPositionManagerTest {
    /// @dev 部署一个由攻击者自行创建并担任管理员的恶意 PA（包装 `GasGuzzlerPermUnderlying`），
    ///      与合法的 `permissionsAdapter0`（admin = address(this)，即“诚实的合规管理员”）配对。
    ///      不断重新部署直到 `paEvil < permissionsAdapter0`，使恶意代币成为 `currency0`，从而
    ///      被 `unwindPosition` 最先交付——这是最坏情况，因为它自身的回退 + 整个
    ///      第二种代币的交付，都必须在其两次失败尝试所剩下的 gas 内完成。
    function _setupGasGriefPaPool()
        internal
        returns (uint256 tokenId, GasGuzzlerPermUnderlying malU, address paEvil, address evilLp)
    {
        evilLp = makeAddr("EVIL_LP_GASGRIEF");
        MockAllowlistChecker checker = new MockAllowlistChecker();

        while (true) {
            malU = new GasGuzzlerPermUnderlying();
            vm.prank(evilLp);
            address candidate =
                permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malU)), evilLp, checker);
            if (candidate < address(permissionsAdapter0)) {
                paEvil = candidate;
                break;
            }
        }

        _wireGriefPa(malU, paEvil, evilLp);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(paEvil),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // 为 LP 在合法适配器的底层代币上注资并加入白名单（malU 已在上面处理过）。
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(evilLp, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(evilLp, 100 ether);
        malU.mint(evilLp, 100 ether);

        _approveViaPermit2(evilLp, Currency.unwrap(currency0));
        _approveViaPermit2(evilLp, address(malU));

        tokenId = lpm.nextTokenId();
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        vm.prank(evilLp);
        mint(config, 1e18, evilLp, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), evilLp);
    }

    /// @dev 更强的变体：两种代币都是由 LP 创建并管理的恶意 PA，各自包装独立的
    ///      `GasGuzzlerPermUnderlying` 代币。这使被恶意消耗的 `_tryDeliverAsset` 尝试次数从
    ///      2 次翻倍到 4 次（先是 currency0 的 LP+admin，再是 currency1 的 LP+admin），损耗叠加两轮而不是
    ///      一轮，且没有良性代币来“吸收”这部分亏空。由于这里 admin0 == admin1 == evilLp，
    ///      evilLp 是唯一可能的调用者（不存在可被恶意消耗的诚实第三方）——这是一个最坏情况的校准，
    ///      而不是绕过合规的场景。
    function _setupDoubleGasGriefPaPool()
        internal
        returns (uint256 tokenId, address paEvilA, address paEvilB, address evilLp)
    {
        evilLp = makeAddr("EVIL_LP_GASGRIEF_2");
        MockAllowlistChecker checker = new MockAllowlistChecker();

        GasGuzzlerPermUnderlying malA;
        GasGuzzlerPermUnderlying malB;
        while (true) {
            malA = new GasGuzzlerPermUnderlying();
            malB = new GasGuzzlerPermUnderlying();
            vm.prank(evilLp);
            address candA =
                permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malA)), evilLp, checker);
            vm.prank(evilLp);
            address candB =
                permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malB)), evilLp, checker);
            if (candA < candB) {
                paEvilA = candA;
                paEvilB = candB;
                _wireGriefPa(malA, paEvilA, evilLp);
                _wireGriefPa(malB, paEvilB, evilLp);
                break;
            }
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(paEvilA),
            currency1: Currency.wrap(paEvilB),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        malA.mint(evilLp, 100 ether);
        malB.mint(evilLp, 100 ether);
        _approveViaPermit2(evilLp, address(malA));
        _approveViaPermit2(evilLp, address(malB));

        tokenId = lpm.nextTokenId();
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        vm.prank(evilLp);
        mint(config, 1e18, evilLp, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), evilLp);
    }

    function _wireGriefPa(GasGuzzlerPermUnderlying malU, address paEvil, address evilLp) internal {
        // 所有会持有/接收 malU 的地址都必须通过其白名单检查（mock 在 !isAllowed[to] 时回滚）。
        malU.setAllowlist(evilLp, PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(paEvil, PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(address(manager), PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);

        malU.mint(paEvil, 1); // 验证要求适配器持有非零余额
        permissionsAdapterFactory.verifyPermissionsAdapter(paEvil);

        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedHook(permissionedHooks, true);
        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedWrapper(address(lpm), true);
    }

    function _approveViaPermit2(address who, address token) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(permit2), type(uint256).max);
        (bool ok,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)", token, address(lpm), type(uint160).max, type(uint48).max
                )
            );
        require(ok);
        vm.stopPrank();
    }

    /// @notice 场景 A：只有一种代币是恶意消耗者，与一种诚实代币配对。修复前，该场景在
    ///         5-10M gas 时会卡死，需要约 15M 才行。修复后每次尝试的上限为 `DELIVERY_GAS_LIMIT`，因此恶意消耗
    ///         有上界，正常的 gas 预算即可成功。
    function test_Fixed_singleCurrencyGrief_forceExitSucceedsAtNormalGas() public {
        (uint256 tokenId,, address paEvil, address evilLp) = _setupGasGriefPaPool();
        bytes memory callData = abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes(""));

        uint256[3] memory gasLevels = [uint256(5_000_000), 10_000_000, 30_000_000];

        for (uint256 i = 0; i < gasLevels.length; i++) {
            uint256 g = gasLevels[i];
            uint256 snapshot = vm.snapshotState();
            (bool okLoop,) = address(lpm).call{gas: g}(callData);
            emit log_named_uint("gas supplied", g);
            emit log_named_string("unwindPosition succeeded?", okLoop ? "yes" : "no (reverted / bricked)");
            assertTrue(okLoop, "post-fix, unwindPosition must succeed at a normal gas budget");
            vm.revertToState(snapshot);
        }

        // 真正执行一次，确认 LP 被强制退出，且被恶意消耗的环节以 6909 claim 的形式落账。
        (bool ok,) = address(lpm).call{gas: 10_000_000}(callData);
        assertTrue(ok, "force-exit must succeed at a normal gas budget after the fix");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // NFT 已销毁 -> LP 被移除，强制退出完成

        // paEvil 的管理员就是 evilLp（攻击者管理自己的适配器），因此被恶意消耗环节的回退
        // claim 会记到 evilLp 名下，而非诚实管理员（address(this)）——无论哪种情况都不会丢失。
        assertGt(
            manager.balanceOf(evilLp, Currency.wrap(paEvil).toId()),
            0,
            "griefed leg must fall back to a 6909 claim, not be lost"
        );
    }

    /// @notice 场景 B：两种代币都是由 LP 管理的恶意消耗者（4 次被恶意消耗的尝试）。修复前，该场景在
    ///         直到 1B 的所有 gas 水平下都会卡死。修复后，每次尝试的上限约束了全部四个环节，因此正常的 gas 预算
    ///         即可成功。
    function test_Fixed_doubleCurrencyGrief_forceExitSucceedsAtNormalGas() public {
        (uint256 tokenId,,, address evilLp) = _setupDoubleGasGriefPaPool();
        bytes memory callData = abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes(""));

        uint256[3] memory gasLevels = [uint256(5_000_000), 10_000_000, 30_000_000];
        for (uint256 i = 0; i < gasLevels.length; i++) {
            uint256 g = gasLevels[i];
            uint256 snapshot = vm.snapshotState();
            vm.prank(evilLp);
            (bool okLoop,) = address(lpm).call{gas: g}(callData);
            emit log_named_uint("gas supplied", g);
            emit log_named_string("unwindPosition succeeded?", okLoop ? "yes" : "no (reverted / bricked)");
            assertTrue(okLoop, "post-fix, unwindPosition must succeed at a normal gas budget (even the self-dos case)");
            vm.revertToState(snapshot);
        }

        vm.prank(evilLp);
        (bool ok,) = address(lpm).call{gas: 10_000_000}(callData);
        assertTrue(ok, "force-exit must succeed at a normal gas budget after the fix, even with 4 griefed legs");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // NFT 已销毁 -> LP 被移除，强制退出完成
    }
}
