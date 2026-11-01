// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {PositionConfig} from "test/shared/PositionConfig.sol";
import {SlippageCheck} from "../../../src/libraries/SlippageCheck.sol";
import {BaseActionsRouter} from "../../../src/base/BaseActionsRouter.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {LiquidityFuzzers} from "../../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../../shared/Planner.sol";
import {PermissionedPosmTestSetup, BalanceInfo} from "./shared/PermissionedPosmTestSetup.sol";
import {ReentrantToken} from "../../mocks/ReentrantToken.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockAllowlistChecker, MockPermissionedToken} from "./PermissionedPoolsBase.sol";
import {PermissionsAdapter, IERC20} from "../../../src/hooks/permissionedPools/PermissionsAdapter.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {INotifier} from "../../../src/interfaces/INotifier.sol";
import {MockUnsubscribeRevertingSubscriber} from "../../mocks/MockUnsubscribeRevertingSubscriber.sol";
import {MockFlashAttackSubscriber} from "../../mocks/MockFlashAttackSubscriber.sol";
import {MockBurnRevertingSubscriber} from "../../mocks/MockBurnRevertingSubscriber.sol";
import {MockReentrantSubscriber} from "../../mocks/MockReentrantSubscriber.sol";
import {MockApprovalHijackSubscriber} from "../../mocks/MockApprovalHijackSubscriber.sol";
import {MockRemoveLiquidityDataHook} from "./mocks/MockRemoveLiquidityDataHook.sol";
import {HookMiner} from "../../shared/HookMiner.sol";
import {Deploy} from "../../shared/Deploy.sol";

contract PermissionedPositionManagerTest is Test, PermissionedPosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    // 用于在不导入 PermissionedHooks 的情况下进行测试
    error Unauthorized();
    error InvalidHook();
    error HookCallFailed();

    PoolId public poolId;
    PoolId public poolIdFake;

    // 许可相关组件
    MockAllowlistChecker public mockAllowListChecker;
    PermissionsAdapter public permissionsAdapter0;
    PermissionsAdapter public permissionsAdapter2;
    MockERC20 public originalToken0;
    MockERC20 public originalToken2;
    IPositionManager public secondaryPosm;
    IPositionManager public tertiaryPosm;

    // 许可 / 普通
    PoolKey public key0;
    // 普通 / 许可
    PoolKey public key1;
    // 许可 / 许可
    PoolKey public key2;
    // 普通 / 普通
    PoolKey public key3;

    PoolKey public keyFake0;
    PoolKey public keyFake1;
    PoolKey public keyFake2;

    PoolKey public insecureKey;

    // 测试用户
    address public alice = makeAddr("ALICE");
    address public unauthorizedUser = makeAddr("UNAUTHORIZED");

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());

        deployFreshManagerAndRoutersPermissioned(address(permit2), address(_WETH9));
        (currency0, currency1) = deployMintAndApprove2Currencies(true, false);
        currency2 = deployMintAndApproveCurrency(true);

        setUpPosms();
        setupPermissionedComponents();
        setupPool();

        // 为 alice 设置授权
        seedBalance(alice);
        approvePosmFor(alice);
        permissionsAdapter0.updateSwappingEnabled(true);
        permissionsAdapter2.updateSwappingEnabled(true);
    }

    function setUpPosms() internal {
        deployAndApprovePosm(manager, address(permissionsAdapterFactory), keccak256("permissionedPosm"));

        // 备用 PositionManager，使用不同的 hooks
        secondaryPosm =
            deployAndApprovePosmOnly(manager, address(permissionsAdapterFactory), keccak256("secondaryPosm"));

        // 备用 PositionManager，使用相同的 hooks
        tertiaryPosm = deployAndApprovePosmOnly(manager, address(permissionsAdapterFactory), keccak256("tertiaryPosm"));
    }

    function setupPool() internal {
        (key0, poolId) =
            initPool(Currency.wrap(address(permissionsAdapter0)), currency1, permissionedHooks, 3000, SQRT_PRICE_1_1);
        (key1, poolId) =
            initPool(currency1, Currency.wrap(address(permissionsAdapter2)), permissionedHooks, 3000, SQRT_PRICE_1_1);
        (key2, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)),
            Currency.wrap(address(permissionsAdapter2)),
            permissionedHooks,
            3000,
            SQRT_PRICE_1_1
        );

        (keyFake0, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)), currency1, secondaryPermissionedHooks, 3000, SQRT_PRICE_1_1
        );
        (keyFake1, poolId) = initPool(
            currency1, Currency.wrap(address(permissionsAdapter2)), secondaryPermissionedHooks, 3000, SQRT_PRICE_1_1
        );
        (keyFake2, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)),
            Currency.wrap(address(permissionsAdapter2)),
            secondaryPermissionedHooks,
            3000,
            SQRT_PRICE_1_1
        );
        (insecureKey, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)),
            Currency.wrap(address(permissionsAdapter2)),
            insecureHooks,
            3000,
            SQRT_PRICE_1_1
        );
    }

    function setupPermissionedComponents() internal {
        mockAllowListChecker = new MockAllowlistChecker();
        setUpCurrencyZero();
        setUpCurrencyTwo();
    }

    function setUpCurrencyZero() internal {
        setUpAllowlist(currency0);
        originalToken0 = MockERC20(Currency.unwrap(currency0));
        // 确保符合预期的排序
        while (true) {
            permissionsAdapter0 = PermissionsAdapter(
                permissionsAdapterFactory.createPermissionsAdapter(
                    IERC20(address(originalToken0)), address(this), mockAllowListChecker
                )
            );
            if (address(permissionsAdapter0) < Currency.unwrap(currency1)) {
                break;
            }
        }
        setUpPermissionsAdapter(permissionsAdapter0, currency0);
    }

    function setUpCurrencyTwo() internal {
        setUpAllowlist(currency2);
        originalToken2 = MockERC20(Currency.unwrap(currency2));

        // 确保符合预期的排序
        while (true) {
            permissionsAdapter2 = PermissionsAdapter(
                permissionsAdapterFactory.createPermissionsAdapter(
                    IERC20(address(originalToken2)), address(this), mockAllowListChecker
                )
            );
            if (Currency.unwrap(currency1) < address(permissionsAdapter2)) {
                break;
            }
        }
        setUpPermissionsAdapter(permissionsAdapter2, currency2);
    }

    function setUpAllowlist(Currency currency) internal {
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(this), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(secondaryPosm), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(permissionsAdapterFactory), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(manager), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(permissionedSwapRouter), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2))
            .setAllowlist(address(permissionedHooks), PermissionFlags.ALL_ALLOWED);
    }

    function setUpPermissionsAdapter(PermissionsAdapter permissionsAdapter, Currency currency) internal {
        adapterToPermissioned[Currency.wrap(address(permissionsAdapter))] = currency;

        MockPermissionedToken(Currency.unwrap(currency)).mint(address(this), 1000 ether);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(permissionsAdapter), PermissionFlags.ALL_ALLOWED);

        // 权限适配器合约必须持有非零余额的许可代币
        IERC20(Currency.unwrap(currency)).approve(address(permissionsAdapter), 1);
        permissionsAdapter.depositForVerification(1);

        permissionsAdapter.updateAllowedWrapper(address(manager), true);
        permissionsAdapter.updateAllowedWrapper(address(lpm), true);
        permissionsAdapter.updateAllowedWrapper(address(secondaryPosm), true);
        permissionsAdapter.updateAllowedWrapper(address(permissionedSwapRouter), true);

        permissionsAdapterFactory.verifyPermissionsAdapter(address(permissionsAdapter));

        Currency permissionsAdapterCurrency = Currency.wrap(address(permissionsAdapter));

        setAllowedHooks(permissionsAdapterCurrency, permissionedHooks, true);
        setAllowedHooks(permissionsAdapterCurrency, secondaryPermissionedHooks, true);
        setAllowedHooks(permissionsAdapterCurrency, insecureHooks, true);
    }

    function test_nameAndSymbol() public view {
        ERC721 posm = ERC721(address(lpm));
        assertEq(posm.name(), "Uniswap v4 Permissioned Positions NFT");
        assertEq(posm.symbol(), "UNI-V4-PERM-POSM");
    }

    function test_modifyLiquidities_reverts_deadlinePassed() public {
        _test_modifyLiquidities_reverts_deadlinePassed(key0);
        _test_modifyLiquidities_reverts_deadlinePassed(key1);
        _test_modifyLiquidities_reverts_deadlinePassed(key2);
    }

    function _test_modifyLiquidities_reverts_deadlinePassed(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: 0, tickUpper: 60});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, "");

        uint256 deadline = vm.getBlockTimestamp() - 1;

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.DeadlinePassed.selector, deadline));
        lpm.modifyLiquidities(calls, deadline);
    }

    function test_modifyLiquidities_reverts_mismatchedLengths() public {
        Plan memory planner = Planner.init();
        planner.add(Actions.MINT_POSITION, abi.encode("test"));
        planner.add(Actions.BURN_POSITION, abi.encode("test"));

        bytes[] memory badParams = new bytes[](1);

        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        lpm.modifyLiquidities(abi.encode(planner.actions, badParams), block.timestamp + 1);
    }

    function test_modifyLiquidities_reverts_reentrancy() public {
        PoolKey memory key;

        // 创建一个重入代币，并使用已验证的适配器初始化池，使 beforeInitialize 能够通过
        Currency reentrantToken = Currency.wrap(address(new ReentrantToken(lpm)));
        Currency adapterCurrency = Currency.wrap(address(permissionsAdapter0));
        (Currency c0, Currency c1) = (Currency.unwrap(reentrantToken) < Currency.unwrap(adapterCurrency))
            ? (reentrantToken, adapterCurrency)
            : (adapterCurrency, reentrantToken);

        // 为重入代币设置授权
        approvePosmCurrency(reentrantToken);
        (key, poolId) = initPool(c0, c1, permissionedHooks, 3000, SQRT_PRICE_1_1);

        // 尝试在该区间添加流动性，但代币会重入 posm
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: -int24(key.tickSpacing), tickUpper: int24(key.tickSpacing)});

        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, "");

        // Permit2.transferFrom 不会向上传递 ContractLocked 错误，而是以它自己的错误回滚（revert）
        vm.expectRevert("TRANSFER_FROM_FAILED");
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_fuzz_mint_withLiquidityDelta(ModifyLiquidityParams memory params, uint160 sqrtPriceX96) public {
        bound(sqrtPriceX96, MIN_PRICE_LIMIT, MAX_PRICE_LIMIT);

        _test_fuzz_mint_withLiquidityDelta(key0, params, sqrtPriceX96);
        _test_fuzz_mint_withLiquidityDelta(key1, params, sqrtPriceX96);
        _test_fuzz_mint_withLiquidityDelta(key2, params, sqrtPriceX96);
    }

    function _test_fuzz_mint_withLiquidityDelta(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96
    ) internal {
        params = createFuzzyLiquidityParams(key, params, sqrtPriceX96);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // 流动性是 uint 类型
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        uint256 balance0Before = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1Before = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerBefore = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = key.currency1.balanceOf(address(manager));
        uint256 tokenId = lpm.nextTokenId();

        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0ManagerAfter = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = key.currency1.balanceOf(address(manager));
        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(
            balance0Before - getPermissionedCurrency(key.currency0).balanceOfSelf(),
            balance0ManagerAfter - balance0ManagerBefore,
            "incorrect amount0"
        );
        assertEq(
            balance1Before - getPermissionedCurrency(key.currency1).balanceOfSelf(),
            balance1ManagerAfter - balance1ManagerBefore,
            "incorrect amount1"
        );
    }

    function test_mint_exactTokenRatios() public {
        _test_mint_exactTokenRatios(key0);
        _test_mint_exactTokenRatios(key1);
        _test_mint_exactTokenRatios(key2);
    }

    function _test_mint_exactTokenRatios(PoolKey memory key) internal {
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1Before = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerBefore = key.currency0.balanceOf(address(manager));
        uint256 tokenId = lpm.nextTokenId();

        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0After = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1After = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerAfter = key.currency0.balanceOf(address(manager));
        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(balance0Before - balance0After, balance0ManagerAfter - balance0ManagerBefore);
        assertEq(balance1Before - balance1After, amount1Desired);
    }

    function test_mint_toRecipient() public {
        _test_mint_toRecipient(key0);
        _test_mint_toRecipient(key1);
        _test_mint_toRecipient(key2);
    }

    function _test_mint_toRecipient(PoolKey memory key) internal {
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 tokenId = lpm.nextTokenId();

        BalanceInfo memory balanceInfoBefore = getBalanceInfoSelfAndManager(key);

        // 铸造给指定的接收者 alice，而不使用接收者常量
        mint(config, liquidityToAdd, alice, ZERO_BYTES);

        BalanceInfo memory balanceInfoAfter = getBalanceInfoSelfAndManager(key);

        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
        assertEq(
            balanceInfoBefore.balance0 - balanceInfoAfter.balance0,
            balanceInfoAfter.balance0Manager - balanceInfoBefore.balance0Manager
        );
        assertEq(
            balanceInfoBefore.balance1 - balanceInfoAfter.balance1,
            balanceInfoAfter.balance1Manager - balanceInfoBefore.balance1Manager
        );
        assertEq(balanceInfoBefore.balance0 - balanceInfoAfter.balance0, amount0Desired);
        assertEq(balanceInfoBefore.balance1 - balanceInfoAfter.balance1, amount1Desired);
    }

    function test_fuzz_mint_recipient(ModifyLiquidityParams memory seedParams) public {
        _test_fuzz_mint_recipient(key0, seedParams);
        _test_fuzz_mint_recipient(key1, seedParams);
        _test_fuzz_mint_recipient(key2, seedParams);
    }

    function _test_fuzz_mint_recipient(PoolKey memory key, ModifyLiquidityParams memory seedParams) internal {
        ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        Currency currency0_ = getPermissionedCurrency(key.currency0);
        Currency currency1_ = getPermissionedCurrency(key.currency1);
        Currency currency0Adapter = key.currency0;
        Currency currency1Adapter = key.currency1;
        uint256 tokenId = lpm.nextTokenId();
        uint256 balance0Before = currency0_.balanceOfSelf();
        uint256 balance1Before = currency1_.balanceOfSelf();
        uint256 balance0BeforeAlice = currency0_.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1_.balanceOf(alice);
        uint256 balance0ManagerBefore = currency0Adapter.balanceOf(address(manager));
        uint256 balance1ManagerBefore = currency1Adapter.balanceOf(address(manager));

        mint(config, liquidityToAdd, alice, ZERO_BYTES);

        uint256 balance0ManagerAfter = currency0Adapter.balanceOf(address(manager));
        uint256 balance1ManagerAfter = currency1Adapter.balanceOf(address(manager));

        // alice 不是付款方
        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
        assertEq(balance0Before - currency0_.balanceOfSelf(), balance0ManagerAfter - balance0ManagerBefore);
        assertEq(balance1Before - currency1_.balanceOfSelf(), balance1ManagerAfter - balance1ManagerBefore);
        assertEq(currency0_.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1_.balanceOf(alice), balance1BeforeAlice);
    }

    /// @dev 铸造（负 delta）时不能使用 clear
    function test_fuzz_mint_clear_revert(ModifyLiquidityParams memory seedParams) public {
        _test_fuzz_mint_clear_revert(key0, seedParams);
        _test_fuzz_mint_clear_revert(key1, seedParams);
        _test_fuzz_mint_clear_revert(key2, seedParams);
    }

    function _test_fuzz_mint_clear_revert(PoolKey memory key, ModifyLiquidityParams memory seedParams) internal {
        ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, type(uint256).max));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, type(uint256).max));
        bytes memory calls = planner.encode();

        Currency negativeDeltaCurrency = key.currency0;
        // 由于对区间做了模糊测试，仅用 currency1 的单边铸造意味着 currency0Delta = 0 且 currency1Delta < 0
        if (config.tickUpper <= 0) {
            negativeDeltaCurrency = key.currency1;
        }

        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, (negativeDeltaCurrency)));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_revertAmount0() public {
        _test_mint_slippage_revertAmount0(key0);
        _test_mint_slippage_revertAmount0(key1);
        _test_mint_slippage_revertAmount0(key2);
    }

    function _test_mint_slippage_revertAmount0(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );

        bytes memory calls =
            getMintEncoded(config, liquidity, 1 wei, MAX_SLIPPAGE_INCREASE, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount0 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_revertAmount1() public {
        _test_mint_slippage_revertAmount1(key0);
        _test_mint_slippage_revertAmount1(key1);
        _test_mint_slippage_revertAmount1(key2);
    }

    function _test_mint_slippage_revertAmount1(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        (, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );

        bytes memory calls =
            getMintEncoded(config, liquidity, MAX_SLIPPAGE_INCREASE, 1 wei, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount1 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_exactDoesNotRevert() public {
        _test_mint_slippage_exactDoesNotRevert(key0);
        _test_mint_slippage_exactDoesNotRevert(key1);
        _test_mint_slippage_exactDoesNotRevert(key2);
    }

    function _test_mint_slippage_exactDoesNotRevert(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );
        uint128 slippage = uint128(amount0) + 1;

        uint256 balance0ManagerBefore = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = key.currency1.balanceOf(address(manager));

        assertEq(amount0, amount1); // 对称流动性

        bytes memory calls =
            getMintEncoded(config, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);

        lpm.modifyLiquidities(calls, _deadline);

        uint256 balance0ManagerAfter = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = key.currency1.balanceOf(address(manager));

        assertEq(balance0ManagerAfter - balance0ManagerBefore, slippage);
        assertEq(balance1ManagerAfter - balance1ManagerBefore, slippage);
    }

    function test_mint_slippage_revert_swap() public {
        _test_mint_slippage_revert_swap(key0);
        _test_mint_slippage_revert_swap(key1);
        _test_mint_slippage_revert_swap(key2);
    }

    function _test_mint_slippage_revert_swap(PoolKey memory key) internal {
        // 兑换（swap）会导致滑点回滚（revert）
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 100e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );
        uint128 slippage = uint128(amount0) + 1;

        assertEq(amount0, amount1); // 对称流动性

        bytes memory calls =
            getMintEncoded(config, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 通过兑换推动价格，从而导致滑点回滚
        swap(key, true, -1e18);

        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, slippage, 1199947202932782783)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_permissioned_mint_allowed_user() public {
        _test_permissioned_mint_allowed_user(key0);
        _test_permissioned_mint_allowed_user(key1);
        _test_permissioned_mint_allowed_user(key2);
    }

    function _test_permissioned_mint_allowed_user(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        // Alice 在白名单中，因此她应该能够铸造
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permissioned_mint_disallowed_hook_reverts() public {
        _test_permissioned_mint_disallowed_hook_reverts(key0);
        _test_permissioned_mint_disallowed_hook_reverts(key1);
        _test_permissioned_mint_disallowed_hook_reverts(key2);
    }

    function _test_permissioned_mint_disallowed_hook_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // 以适配器管理员身份撤销该 hook（address(this) 同时拥有 permissionsAdapter0 和 permissionsAdapter2）
        _setHookAllowedForKey(key, false);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 恢复原状，使对各个 key 的逐一测试相互独立
        _setHookAllowedForKey(key, true);
    }

    function test_permissioned_mint_alt_posm_same_hooks_reverts() public {
        // 第三个 posm 使用相同的 hooks 合约
        _test_permissioned_mint_alt_posm_same_hooks_reverts(key0, tertiaryPosm);
        _test_permissioned_mint_alt_posm_same_hooks_reverts(key1, tertiaryPosm);
        _test_permissioned_mint_alt_posm_same_hooks_reverts(key2, tertiaryPosm);
    }

    function _test_permissioned_mint_alt_posm_same_hooks_reverts(PoolKey memory key, IPositionManager posm) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;

        // 这里不使用辅助函数，以便自行选择使用哪个 PositionManager
        bytes memory calls = getMintEncoded(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        posm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_permissioned_mint_alt_posm_allowed_wrapper_succeeds() public {
        // 第二个 posm 是被允许的封装合约（wrapper），因此仅靠适配器层面的 hook 白名单就足够了
        _test_permissioned_mint_alt_posm_allowed_wrapper_succeeds(key0, secondaryPosm);
        _test_permissioned_mint_alt_posm_allowed_wrapper_succeeds(key1, secondaryPosm);
        _test_permissioned_mint_alt_posm_allowed_wrapper_succeeds(key2, secondaryPosm);
    }

    function _test_permissioned_mint_alt_posm_allowed_wrapper_succeeds(PoolKey memory key, IPositionManager posm)
        internal
    {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        uint256 tokenId = posm.nextTokenId();

        // alice 已在底层代币上授权过 permit2；这里将此 posm 授权为 permit2 的被授权者
        vm.startPrank(alice);
        permit2.approve(Currency.unwrap(currency0), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency2), address(posm), type(uint160).max, type(uint48).max);

        // 这里不使用辅助函数，以便自行选择使用哪个 PositionManager
        bytes memory calls = getMintEncoded(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        posm.modifyLiquidities(calls, block.timestamp + 1);
        vm.stopPrank();

        assertEq(IERC721(address(posm)).ownerOf(tokenId), alice);
    }

    function test_permissioned_mint_disallowed_user_reverts() public {
        _test_permissioned_mint_disallowed_user_reverts(key0);
        _test_permissioned_mint_disallowed_user_reverts(key1);
        _test_permissioned_mint_disallowed_user_reverts(key2);
    }

    function _test_permissioned_mint_disallowed_user_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;

        // 给未授权用户添加一些代币
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(unauthorizedUser, 1000e18);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockERC20(Currency.unwrap(currency1)).mint(unauthorizedUser, 1000e18);

        vm.startPrank(unauthorizedUser);

        // 为 PositionManager 授权代币
        originalToken0.approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(address(originalToken0), address(lpm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(lpm), type(uint160).max, type(uint48).max);

        // 这里应当回滚（revert），因为接收者不在白名单中
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
        vm.stopPrank();
    }

    /// @dev 若池的两侧都没有已验证的权限适配器，
    ///      PermissionedPositionManager 就没有任何需要执行的约束；铸造这样的头寸只会产生
    ///      一个不可转让的 NFT（参见 ECO-221 / `transferFrom`）。因此直接拒绝铸造。
    function test_mint_reverts_when_no_verified_adapter() public {
        // 两个普通的 ERC-20——都不是已验证的权限适配器。
        Currency ordinary0 = deployMintAndApproveCurrency(false);
        Currency ordinary1 = deployMintAndApproveCurrency(false);
        if (Currency.unwrap(ordinary1) < Currency.unwrap(ordinary0)) {
            (ordinary0, ordinary1) = (ordinary1, ordinary0);
        }
        approvePosmCurrency(ordinary0);
        approvePosmCurrency(ordinary1);

        // 直接在 PoolManager 上以无 hook 方式初始化，使初始化不受限制。
        PoolKey memory ordinaryKey = PoolKey({
            currency0: ordinary0, currency1: ordinary1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        manager.initialize(ordinaryKey, SQRT_PRICE_1_1);

        PositionConfig memory config = PositionConfig({poolKey: ordinaryKey, tickLower: -120, tickUpper: 120});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 使用字面量选择器，避免在此处引入 PermissionedPositionManager 的导入。
        // bytes4(keccak256("NoVerifiedAdapter()")) = 0x36a01ad4
        vm.expectRevert(bytes4(keccak256("NoVerifiedAdapter()")));
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    /// @dev 基于一个新代币创建工厂适配器并返回它，但不对其进行验证。循环直到该
    ///      适配器地址排序低于 `permissionsAdapter0`，从而可以用作 currency0（会被优先校验）。
    function _createUnverifiedAdapterBelow(address ceiling) internal returns (PermissionsAdapter unverified) {
        Currency ordinary = deployMintAndApproveCurrency(false);
        while (true) {
            unverified = PermissionsAdapter(
                permissionsAdapterFactory.createPermissionsAdapter(
                    IERC20(Currency.unwrap(ordinary)), address(this), mockAllowListChecker
                )
            );
            if (address(unverified) < ceiling) break;
        }
        // 健全性检查：已在工厂中创建，但尚未验证。
        assertEq(permissionsAdapterFactory.permissionsAdapterOf(address(unverified)), Currency.unwrap(ordinary));
        assertEq(permissionsAdapterFactory.verifiedPermissionsAdapterOf(address(unverified)), address(0));
    }

    /// @dev 将已验证适配器与由工厂创建但未验证的适配器配对的池必须拒绝铸造：
    ///      未验证的适配器不是普通代币，不能跳过其 LIQUIDITY_ALLOWED 与 hook 检查。
    function test_mint_reverts_when_paired_with_unverified_adapter() public {
        PermissionsAdapter unverified = _createUnverifiedAdapterBelow(address(permissionsAdapter0));

        // 未验证的适配器是 currency0（排序更低），因此会被优先校验。
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(unverified)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, SQRT_PRICE_1_1);

        PositionConfig memory config = PositionConfig({poolKey: k, tickLower: -120, tickUpper: 120});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.expectRevert(bytes4(keccak256("NoVerifiedAdapter()")));
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_mint_reverts_when_paired_with_non_contract_currency() public {
        // 一个没有代码的非适配器地址（即尚未部署的适配器地址），排序低于该适配器，因此它
        // 是 currency0，并会被优先校验。
        address phantom = address(0xBEEF);
        assertEq(phantom.code.length, 0);

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(phantom),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, SQRT_PRICE_1_1);

        PositionConfig memory config = PositionConfig({poolKey: k, tickLower: -120, tickUpper: 120});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.expectRevert(bytes4(keccak256("NonContractCurrency()")));
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    /// @dev 适配器一旦通过验证，就会越过 NoVerifiedAdapter 这道关卡。此时铸造会改为以
    ///      InvalidHook 回滚（这里使用的零地址 hooks 不在已验证适配器的白名单中），
    ///      从而确认上面阻止铸造的是验证环节——而不是 hook 检查。
    function test_mint_pastVerificationGate_after_adapter_is_verified() public {
        PermissionsAdapter unverified = _createUnverifiedAdapterBelow(address(permissionsAdapter0));

        // 验证它：工厂要求适配器持有非零余额的底层代币。
        IERC20 underlying = IERC20(permissionsAdapterFactory.permissionsAdapterOf(address(unverified)));
        underlying.approve(address(unverified), 1);
        unverified.depositForVerification(1);
        permissionsAdapterFactory.verifyPermissionsAdapter(address(unverified));
        assertEq(permissionsAdapterFactory.verifiedPermissionsAdapterOf(address(unverified)), address(underlying));

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(unverified)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, SQRT_PRICE_1_1);

        PositionConfig memory config = PositionConfig({poolKey: k, tickLower: -120, tickUpper: 120});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 现在已越过 NoVerifiedAdapter 关卡；仅被（无关的）hook 白名单阻止。
        vm.expectRevert(InvalidHook.selector);
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_permissioned_mint_increase_allowed_user() public {
        _test_permissioned_mint_increase_allowed_user(key0);
        _test_permissioned_mint_increase_allowed_user(key1);
        _test_permissioned_mint_increase_allowed_user(key2);
    }

    function _test_permissioned_mint_increase_allowed_user(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.startPrank(alice);

        // 添加初始流动性
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        tokenId = lpm.nextTokenId();

        // 增加流动性
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permissioned_mint_increase_disallowed_user_reverts() public {
        _test_permissioned_mint_increase_disallowed_user_reverts(key0);
        _test_permissioned_mint_increase_disallowed_user_reverts(key1);
        _test_permissioned_mint_increase_disallowed_user_reverts(key2);
    }

    function _test_permissioned_mint_increase_disallowed_user_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e17;
        uint256 tokenId = lpm.nextTokenId();

        vm.startPrank(alice);

        // 添加初始流动性
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        tokenId = lpm.nextTokenId();

        // 增加流动性应当回滚（revert），因为接收者已不在白名单中
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
    }

    function test_unpermissioned_sided_mint_disallowed_user_reverts() public {
        _test_unpermissioned_sided_mint_disallowed_user_reverts(key0, false);
        _test_unpermissioned_sided_mint_disallowed_user_reverts(key1, true);
        // key2 没有非许可的一侧
    }

    function _test_unpermissioned_sided_mint_disallowed_user_reverts(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;
        Currency currencyUnpermissioned;

        uint256 liquidity = 1e18;

        if (useZero) {
            currencyUnpermissioned = getPermissionedCurrency(key.currency0);
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            currencyUnpermissioned = getPermissionedCurrency(key.currency1);
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        // 给未授权用户添加一些代币
        MockERC20(Currency.unwrap(currencyUnpermissioned)).mint(unauthorizedUser, 1000e18);

        vm.startPrank(unauthorizedUser);

        // 为 PositionManager 和 permit2 授权代币
        MockERC20(Currency.unwrap(currencyUnpermissioned)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currencyUnpermissioned), address(lpm), type(uint160).max, type(uint48).max);

        // 这里应当回滚（revert），因为接收者不在白名单中
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
        vm.stopPrank();
    }

    function test_unpermissioned_sided_mint_allowed_user() public {
        _test_unpermissioned_sided_mint_allowed_user(key0, false);
        _test_unpermissioned_sided_mint_allowed_user(key1, true);
        // key2 没有非许可的一侧
    }

    function _test_unpermissioned_sided_mint_allowed_user(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;
        Currency currencyPermissioned;

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        if (useZero) {
            currencyPermissioned = getPermissionedCurrency(key.currency0);
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            currencyPermissioned = getPermissionedCurrency(key.currency1);
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        vm.startPrank(alice);

        // 为 PositionManager 和 permit2 授权代币
        MockERC20(Currency.unwrap(currencyPermissioned)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currencyPermissioned), address(lpm), type(uint160).max, type(uint48).max);

        mint(config, liquidity, alice, ZERO_BYTES);
        vm.stopPrank();

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permissioned_sided_mint_disallowed_user_reverts() public {
        _test_permissioned_sided_mint_disallowed_user_reverts(key0, true);
        _test_permissioned_sided_mint_disallowed_user_reverts(key1, false);
        _test_permissioned_sided_mint_disallowed_user_reverts(key2, true);
    }

    function _test_permissioned_sided_mint_disallowed_user_reverts(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;
        Currency currencyPermissioned;

        uint256 liquidity = 1e18;

        if (useZero) {
            currencyPermissioned = getPermissionedCurrency(key.currency0);
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            currencyPermissioned = getPermissionedCurrency(key.currency1);
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        // 给未授权用户添加一些代币
        MockPermissionedToken(Currency.unwrap(currencyPermissioned))
            .setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currencyPermissioned)).mint(unauthorizedUser, 1000e18);
        MockPermissionedToken(Currency.unwrap(currencyPermissioned))
            .setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        vm.startPrank(unauthorizedUser);

        // 为 PositionManager 和 permit2 授权代币
        MockERC20(Currency.unwrap(currencyPermissioned)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currencyPermissioned), address(lpm), type(uint160).max, type(uint48).max);

        // 这里应当回滚（revert），因为接收者不在白名单中
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
        vm.stopPrank();
    }

    function test_permissioned_single_sided_mint_allowed_user() public {
        _test_permissioned_sided_mint_allowed_user(key0, true);
        _test_permissioned_sided_mint_allowed_user(key1, false);
        _test_permissioned_sided_mint_allowed_user(key2, true);
    }

    function _test_permissioned_sided_mint_allowed_user(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        if (useZero) {
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        vm.prank(alice);
        mint(config, liquidity, alice, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_fuzz_burn_emptyPosition(ModifyLiquidityParams memory params) public {
        _test_fuzz_burn_emptyPosition(key0, params);
        _test_fuzz_burn_emptyPosition(key1, params);
        _test_fuzz_burn_emptyPosition(key2, params);
    }

    function _test_fuzz_burn_emptyPosition(PoolKey memory key, ModifyLiquidityParams memory params) internal {
        uint256 balance0Start = key.currency0.balanceOfSelf();
        uint256 balance1Start = key.currency1.balanceOfSelf();
        uint256 tokenId;

        // 创建可供销毁的流动性
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(1), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));

        uint256 balance0BeforeBurn = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1BeforeBurn = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerBefore = (key.currency0).balanceOf(address(manager));
        uint256 balance1ManagerBefore = (key.currency1).balanceOf(address(manager));

        // 销毁流动性
        decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        uint256 balance0ManagerAfter = (key.currency0).balanceOf(address(manager));
        uint256 balance1ManagerAfter = (key.currency1).balanceOf(address(manager));

        liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 0);
        assertEq(
            getPermissionedCurrency(key.currency0).balanceOfSelf(),
            balance0BeforeBurn + balance0ManagerBefore - balance0ManagerAfter
        );
        assertEq(
            getPermissionedCurrency(key.currency1).balanceOfSelf(),
            balance1BeforeBurn + balance1ManagerBefore - balance1ManagerAfter
        );

        IERC721(address(lpm)).ownerOf(lpm.nextTokenId() - 1);

        // 参见 PositionManager 测试中的说明：“没有代币丢失……模糊测试有时会出现差 1 的情况”
        assertApproxEqAbs(key.currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(key.currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_initialize() public {
        _test_initialize(currency0, currency1);
        _test_initialize(Currency.wrap(address(permissionsAdapter0)), currency1);
        _test_initialize(currency1, Currency.wrap(address(permissionsAdapter2)));
        _test_initialize(Currency.wrap(address(permissionsAdapter0)), Currency.wrap(address(permissionsAdapter2)));
    }

    function _test_initialize(Currency currency0_, Currency currency1_) internal {
        // 初始化一个新池
        PoolKey memory key = PoolKey({
            currency0: currency0_, currency1: currency1_, fee: 0, tickSpacing: 100, hooks: IHooks(address(0))
        });

        lpm.initializePool(key, SQRT_PRICE_1_1);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());

        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, key.fee);
    }

    function test_fuzz_initialize(uint160 sqrtPrice, uint24 fee) public {
        _test_fuzz_initialize(currency0, currency1, sqrtPrice, fee);
        _test_fuzz_initialize(Currency.wrap(address(permissionsAdapter0)), currency1, sqrtPrice, fee);
        _test_fuzz_initialize(currency1, Currency.wrap(address(permissionsAdapter2)), sqrtPrice, fee);
        _test_fuzz_initialize(
            Currency.wrap(address(permissionsAdapter0)), Currency.wrap(address(permissionsAdapter2)), sqrtPrice, fee
        );
    }

    function _test_fuzz_initialize(Currency currency0_, Currency currency1_, uint160 sqrtPrice, uint24 fee) internal {
        sqrtPrice =
            uint160(bound(sqrtPrice, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE));
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        PoolKey memory key = PoolKey({
            currency0: currency0_, currency1: currency1_, fee: fee, tickSpacing: 10, hooks: IHooks(address(0))
        });

        lpm.initializePool(key, sqrtPrice);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());

        assertEq(sqrtPriceX96, sqrtPrice);
        assertEq(tick, TickMath.getTickAtSqrtPrice(sqrtPrice));
        assertEq(protocolFee, 0);
        assertEq(lpFee, fee);
    }

    error TransferDisabled();

    function test_transferFrom_reverts_transfer_disabled_either_admin() public {
        uint256 tokenId0 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);
        uint256 tokenId1 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);
        uint256 tokenId2 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // address(this) 是两个许可代币的管理员
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId0);

        address owner0 = makeAddr("owner0");
        address owner1 = makeAddr("owner1");
        permissionsAdapter0.transferOwnership(owner0);
        vm.prank(owner0);
        permissionsAdapter0.acceptOwnership();
        permissionsAdapter2.transferOwnership(owner1);
        vm.prank(owner1);
        permissionsAdapter2.acceptOwnership();

        vm.startPrank(owner0);
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId1);
        vm.stopPrank();

        vm.startPrank(owner1);
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId2);
        vm.stopPrank();
    }

    function test_transferFrom_reverts_transfer_disabled(address caller) public {
        _testRevert_transferFrom_reverts_transfer_disabled(key0, caller);
        _testRevert_transferFrom_reverts_transfer_disabled(key1, caller);
        _testRevert_transferFrom_reverts_transfer_disabled(key2, caller);
    }

    function _testRevert_transferFrom_reverts_transfer_disabled(PoolKey memory poolKey, address caller) internal {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(poolKey);

        vm.startPrank(caller);
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId);
        vm.stopPrank();
    }

    function test_safe_transfer_from_reverts() public {
        bytes memory encodedCall =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(this), 1);

        address target = address(lpm);

        vm.startPrank(alice);
        (bool success, bytes memory data) = address(target).call(encodedCall);

        assertEq(success, false);
        assertEq(bytes4(data), TransferDisabled.selector);
        vm.stopPrank();
    }

    function test_safe_transfer_from_with_bytes_reverts() public {
        bytes memory encodedCall =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, address(this), 1, "abcd");
        address target = address(lpm);

        vm.startPrank(alice);
        (bool success, bytes memory data) = address(target).call(encodedCall);

        assertEq(success, false);
        assertEq(bytes4(data), TransferDisabled.selector);
        vm.stopPrank();
    }

    function test_mint_from_contract_balance() public {
        _test_mint_from_contract_balance(key0);
        _test_mint_from_contract_balance(key1);
        _test_mint_from_contract_balance(key2);
    }

    /// @dev 为避免 stack-too-deep 错误，该函数不得不被拆分并重构
    function _test_mint_from_contract_balance(PoolKey memory key) internal {
        uint256 amount0ToTransfer = 100e18;
        uint256 amount1ToTransfer = 100e18;

        // 准备并转移代币
        setupContractBalance(key, amount0ToTransfer, amount1ToTransfer);

        // 获取铸造前的余额
        BalanceInfo memory balanceInfo = getBalanceInfo(key);

        // 创建并执行铸造计划
        bytes memory calls = createMintPlan(key, amount0ToTransfer, amount1ToTransfer);
        uint256 tokenId = lpm.nextTokenId();
        lpm.modifyLiquidities(calls, _deadline);

        // 验证结果
        verifyMintResults(key, balanceInfo, tokenId);
    }

    function test_mint_from_contract_balance_disallowed_revert() public {
        _test_mint_from_contract_balance_disallowed_revert(keyFake0);
        _test_mint_from_contract_balance_disallowed_revert(keyFake1);
        _test_mint_from_contract_balance_disallowed_revert(keyFake2);
    }

    function _test_mint_from_contract_balance_disallowed_revert(PoolKey memory key) internal {
        uint256 amount0ToTransfer = 1e18;
        uint256 amount1ToTransfer = 1e18;

        Currency currency0_ = getPermissionedCurrency(key.currency0);
        Currency currency1_ = getPermissionedCurrency(key.currency1);

        uint256 balance0Before = currency0_.balanceOf(address(secondaryPosm));
        uint256 balance1Before = currency1_.balanceOf(address(secondaryPosm));

        // 将代币转入合约
        currency0_.transfer(address(secondaryPosm), amount0ToTransfer);
        currency1_.transfer(address(secondaryPosm), amount1ToTransfer);

        // 根据期望的数量计算流动性
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0ToTransfer,
            amount1ToTransfer
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        // 验证合约持有这些代币
        assertEq(currency0_.balanceOf(address(secondaryPosm)), amount0ToTransfer + balance0Before);
        assertEq(currency1_.balanceOf(address(secondaryPosm)), amount1ToTransfer + balance1Before);

        // 创建一个使用合约余额（而非调用者余额）的计划
        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this), // 接收者
                ZERO_BYTES // hookData
            )
        );

        // 添加从合约余额进行结算的操作（action）
        planner.add(Actions.SETTLE, abi.encode(key.currency0, ActionConstants.OPEN_DELTA, false)); // false = 付款方为合约
        planner.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.OPEN_DELTA, false)); // false = 付款方为合约

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        vm.prank(unauthorizedUser);
        vm.expectRevert();
        secondaryPosm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_from_contract_balance_uses_contract_balance_settle() public {
        _test_mint_from_contract_balance_uses_contract_balance_settle(key0);
        _test_mint_from_contract_balance_uses_contract_balance_settle(key1);
        _test_mint_from_contract_balance_uses_contract_balance_settle(key2);
    }

    function _test_mint_from_contract_balance_uses_contract_balance_settle(PoolKey memory key) internal {
        uint256 amount0ToTransfer = 100e18;
        uint256 amount1ToTransfer = 100e18;

        // 将底层许可代币转入 POSM
        setupContractBalance(key, amount0ToTransfer, amount1ToTransfer);

        BalanceInfo memory balanceInfo = getBalanceInfo(key);

        // 创建一个使用 CONTRACT_BALANCE 而非 OPEN_DELTA 的铸造计划
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0ToTransfer,
            amount1ToTransfer
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );

        // 使用 CONTRACT_BALANCE 而非 OPEN_DELTA——这正是出问题的那条路径
        planner.add(Actions.SETTLE, abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false));
        planner.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false));

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        uint256 tokenId = lpm.nextTokenId();
        lpm.modifyLiquidities(calls, _deadline);

        verifyMintResults(key, balanceInfo, tokenId);
    }

    // ===== 权限标志测试 =====

    function test_permission_flag_none() public {
        // 测试 NONE 权限会阻止所有操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // 仅有 NONE 权限时尝试铸造应当回滚（revert）
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_swap_allowed() public {
        // 测试 SWAP_ALLOWED 只允许兑换（swap），不允许流动性操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        // 仅有 SWAP_ALLOWED 时尝试铸造（流动性操作）应当回滚（revert）
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_liquidity_allowed() public {
        // 测试 LIQUIDITY_ALLOWED 允许流动性操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        // 拥有 LIQUIDITY_ALLOWED 时尝试铸造应当成功
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_all_allowed() public {
        // 测试 ALL_ALLOWED 允许所有操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);

        // 拥有 ALL_ALLOWED 时尝试铸造应当成功
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_combinations() public {
        // 测试各种权限组合
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // 测试 SWAP_ALLOWED + LIQUIDITY_ALLOWED（效果应与 ALL_ALLOWED 相同）
        MockPermissionedToken(Currency.unwrap(currency0))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));
        MockPermissionedToken(Currency.unwrap(currency2))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));

        uint256 tokenId = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_partial_permissions_reverts() public {
        // 测试仅对池中的一个代币拥有权限是不够的
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_dynamic_changes() public {
        // 测试权限变更会立即生效
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // 最初应当成功
        uint256 tokenId = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        // 移除权限
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // 后续操作应当失败
        tokenId = lpm.nextTokenId();
        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_edge_cases() public {
        // 测试权限标志的边界情况
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // 测试零权限（应与 NONE 相同）
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0x0000));
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlag.wrap(0x0000));

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 测试最大权限（应与 ALL_ALLOWED 相同）
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));

        uint256 tokenId = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_all_pools() public {
        // 测试权限标志在所有类型的池中都有效
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        PositionConfig memory config0 = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        PositionConfig memory config1 = PositionConfig({poolKey: key1, tickLower: -120, tickUpper: 120});
        PositionConfig memory config2 = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // 测试 许可/普通 池
        uint256 tokenId0 = lpm.nextTokenId();
        vm.prank(alice);
        mint(config0, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId0), alice);

        // 测试 普通/许可 池
        uint256 tokenId1 = lpm.nextTokenId();
        vm.prank(alice);
        mint(config1, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId1), alice);

        // 测试 许可/许可 池
        uint256 tokenId2 = lpm.nextTokenId();
        vm.prank(alice);
        mint(config2, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId2), alice);
    }

    function test_permission_flag_swap_allowed_unauthorized_reverts() public {
        // 测试 SWAP_ALLOWED 不允许流动性操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        // 仅有 SWAP_ALLOWED 时尝试铸造应当回滚（revert）
        PositionConfig memory config = PositionConfig({poolKey: insecureKey, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.startPrank(alice);
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();
    }

    function test_permissioned_mint_to_unauthorized_recipient_reverts() public {
        // 调用者（address(this)）被允许，但 unauthorizedUser 不被允许
        // 由于调用者已获授权，hook 检查会通过，
        // 但 _mint 应当回滚（revert），因为接收者缺少 LIQUIDITY_ALLOWED
        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
    }

    function test_permissioned_mint_to_authorized_recipient_succeeds() public {
        // 调用者（address(this)）被允许，alice 也被允许
        // 铸造给已获授权的接收者应当成功
        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        mint(config, liquidity, alice, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    // =============================================================================
    // 增加流动性时对 hook 白名单撤销的强制执行（ECO-218 / SC-L-07）
    // =============================================================================

    function test_permissioned_increase_disallowed_hook_reverts() public {
        _test_permissioned_increase_disallowed_hook_reverts(key0);
        _test_permissioned_increase_disallowed_hook_reverts(key1);
        _test_permissioned_increase_disallowed_hook_reverts(key2);
    }

    function _test_permissioned_increase_disallowed_hook_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        // 以适配器管理员身份撤销该 hook（address(this) 同时拥有 permissionsAdapter0 和 permissionsAdapter2）
        _setHookAllowedForKey(key, false);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        // 恢复原状，使对各个 key 的逐一测试相互独立
        _setHookAllowedForKey(key, true);
    }

    function test_permissioned_increaseFromDeltas_disallowed_hook_reverts() public {
        _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(key0);
        _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(key1);
        _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(key2);
    }

    function _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 initialLiquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        _setHookAllowedForKey(key, false);

        // 构建一个计划：先预结算两种代币，再执行 INCREASE_LIQUIDITY_FROM_DELTAS。
        // hook 白名单检查在重写函数（override）的开头执行，因此整个批次会
        // 原子性地回滚，且没有任何资金移动。
        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(key.currency0, uint256(10e18), true));
        planner.add(Actions.SETTLE, abi.encode(key.currency1, uint256(10e18), true));
        planner.add(
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.encode();

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        lpm.modifyLiquidities(calls, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        _setHookAllowedForKey(key, true);
    }

    function test_permissioned_increase_succeeds_when_hook_still_allowed() public {
        _test_permissioned_increase_succeeds_when_hook_still_allowed(key0);
        _test_permissioned_increase_succeeds_when_hook_still_allowed(key1);
        _test_permissioned_increase_succeeds_when_hook_still_allowed(key2);
    }

    function _test_permissioned_increase_succeeds_when_hook_still_allowed(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        vm.prank(alice);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore + uint128(liquidity));
    }

    function test_permissioned_increase_succeeds_then_reverts_after_revocation() public {
        _test_permissioned_increase_succeeds_then_reverts_after_revocation(key0);
        _test_permissioned_increase_succeeds_then_reverts_after_revocation(key1);
        _test_permissioned_increase_succeeds_then_reverts_after_revocation(key2);
    }

    function _test_permissioned_increase_succeeds_then_reverts_after_revocation(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 在 hook 仍被允许时，增加流动性成功。
        vm.prank(alice);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        uint128 liquidityAfterFirstIncrease = lpm.getPositionLiquidity(tokenId);

        // 撤销该 hook——下一次增加流动性必须回滚（revert）。
        _setHookAllowedForKey(key, false);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAfterFirstIncrease);

        _setHookAllowedForKey(key, true);
    }

    function test_permissioned_increase_reverts_when_only_one_currency_hook_revoked() public {
        // 使用 key2（许可/许可）：每种代币都会被独立校验，因此任意一侧
        // 被撤销的 hook 白名单都必须能单独阻止增加流动性。
        _test_permissioned_increase_reverts_when_only_one_currency_hook_revoked(key2, true);
        _test_permissioned_increase_reverts_when_only_one_currency_hook_revoked(key2, false);
    }

    function _test_permissioned_increase_reverts_when_only_one_currency_hook_revoked(
        PoolKey memory key,
        bool revokeCurrency0
    ) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Currency revoked = revokeCurrency0 ? key.currency0 : key.currency1;
        setAllowedHooks(revoked, key.hooks, false);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        // 为下一轮迭代恢复原状，使各测试相互独立。
        setAllowedHooks(revoked, key.hooks, true);
    }

    // =============================================================================
    // 增加流动性时对所有者 LIQUIDITY_ALLOWED 的强制检查
    // =============================================================================
    //
    // 一个经 ERC-721 授权、且仍保有 LIQUIDITY_ALLOWED 的操作者，不得通过用自己的资金付款
    // 来扩大已被移出白名单的所有者的头寸。`_increase` 和
    // `_increaseFromDeltas` 会通过 `_validateLiquidityCurrency` 重新检查所有者的 LIQUIDITY_ALLOWED。

    function test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator() public {
        _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(key0);
        _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(key1);
        _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(key2);
    }

    function _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(PoolKey memory key)
        internal
    {
        address bob = makeAddr("BOB");
        // Bob 在每个许可底层代币上都持有 LIQUIDITY_ALLOWED，并且已获得资金，以便他能
        // 用自己的余额为增加流动性付款。
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        seedBalance(bob);
        approvePosmFor(bob);

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        // Alice 在仍拥有 LIQUIDITY_ALLOWED 时铸造一个头寸。
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        // Alice 通过 ERC-721 授权 Bob，使他能够操作她的 tokenId。
        vm.prank(alice);
        IERC721(address(lpm)).approve(bob, tokenId);

        // Alice 的适配器撤销她在每个许可底层代币上的权限。
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // Bob——仍在白名单中、仍拥有 ERC-721 授权——不得通过用自己的资金付款
        // 来扩大 Alice 的头寸。
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        // 头寸规模不变。
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        // 恢复原状，使对各个 key 的逐一测试相互独立。
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
    }

    function test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator() public {
        _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(key0);
        _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(key1);
        _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(key2);
    }

    function _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(PoolKey memory key)
        internal
    {
        address bob = makeAddr("BOB_DELTAS");
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        seedBalance(bob);
        approvePosmFor(bob);

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 initialLiquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        vm.prank(alice);
        IERC721(address(lpm)).approve(bob, tokenId);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // 构建一个计划：先预结算两种代币，再执行 INCREASE_LIQUIDITY_FROM_DELTAS。
        // 所有者白名单检查在重写函数（override）的开头执行，因此整个批次会
        // 原子性地回滚，且没有任何资金移动。
        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(key.currency0, uint256(10e18), true));
        planner.add(Actions.SETTLE, abi.encode(key.currency1, uint256(10e18), true));
        planner.add(
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.encode();

        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        lpm.modifyLiquidities(calls, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
    }

    // 用于在测试中切换 hook 白名单的辅助函数
    function _setHookAllowedForKey(PoolKey memory key, bool allowed) internal {
        _setHookAllowedIfPermissioned(key.currency0, key.hooks, allowed);
        _setHookAllowedIfPermissioned(key.currency1, key.hooks, allowed);
    }

    function _setHookAllowedIfPermissioned(Currency currency, IHooks hooks_, bool allowed) internal {
        // updateAllowedHook 要求该代币拥有已验证的权限适配器；
        // 跳过非许可代币，使混合池的 key（key0、key1）也能使用此辅助函数。
        if (permissionsAdapterFactory.verifiedPermissionsAdapterOf(Currency.unwrap(currency)) == address(0)) return;
        setAllowedHooks(currency, hooks_, allowed);
    }

    // ===== unwindPosition / withdrawClaim 辅助函数 =====

    /// @dev V4 的舍入对池有利：一次铸造 + 销毁的往返每侧最多损失 1 wei。
    uint256 private constant _ROUNDTRIP_TOLERANCE = 1;
    // `unwindPosition(uint256,uint128,uint128,bytes)` 的字面量选择器；这里刻意不导入具体类型
    // （它固定使用另一个编译器 profile，与测试 profile 冲突）。
    bytes4 internal constant _UNWIND_SELECTOR = 0xb0a281b0;
    bytes4 private constant _WITHDRAW_CLAIM_SELECTOR = 0xf77de3fc;

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

    function _balanceOf(Currency c, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _unwind(uint256 tokenId) internal {
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        require(ok, "unwindPosition failed");
    }

    function _withdrawClaim(Currency currency, uint256 amount, address to) internal {
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_WITHDRAW_CLAIM_SELECTOR, currency, amount, to));
        require(ok, "withdrawClaim failed");
    }

    /// @dev 将 pa0 的所有权移交给 `admin1`、pa2 的所有权移交给 `admin2`，并过滤模糊测试输入，以保证
    ///      级联回退的前提合理。同一管理员的场景请传入 `admin1 == admin2`。
    function _setupUnwindPositionTests(address admin1, address admin2) internal {
        // 管理员必须是有效的 Ownable2Step 接收者，且不同于各协议合约
        vm.assume(admin1 != address(0) && admin2 != address(0));
        vm.assume(admin1 != alice && admin2 != alice);
        vm.assume(admin1 != address(manager) && admin2 != address(manager));
        vm.assume(admin1 != address(lpm) && admin2 != address(lpm));

        permissionsAdapter0.transferOwnership(admin1);
        vm.prank(admin1);
        permissionsAdapter0.acceptOwnership();

        permissionsAdapter2.transferOwnership(admin2);
        vm.prank(admin2);
        permissionsAdapter2.acceptOwnership();
    }

    // ===== 场景 1：两种代币都是由同一管理员拥有的 PA（admin1 == admin2）=====

    /// @dev 场景 1：同一管理员拥有两个 PA，LP 在两侧均合规 → 两部分都经级联流向 LP。
    function test_unwindPosition_two_pas_same_admin_routes_both_to_lp(address admin) public {
        _setupUnwindPositionTests(admin, admin);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // 记录精确的存入数量，以便对事件做全字段检查
        uint256 deposited0 = aliceCurrency0BeforeMint - _balanceOf(currency0, alice);
        uint256 deposited2 = aliceCurrency2BeforeMint - _balanceOf(currency2, alice);

        // 全字段检查会验证 caller == admin（msgSender() 返回 unwindPosition 的调用者，而不是 PoolManager）。
        vm.expectEmit(true, true, true, true);
        emit CurrencyUnwound(tokenId, key2.currency0, alice, admin, alice, deposited0 - 1, false);
        vm.expectEmit(true, true, true, true);
        emit CurrencyUnwound(tokenId, key2.currency1, alice, admin, alice, deposited2 - 1, false);
        vm.prank(admin);
        _unwind(tokenId);

        // alice 在两种代币上都应基本没有损失
        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(currency2, alice), aliceCurrency2BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    // ===== 场景 2：一个 PA + 一个普通 ERC-20；由 admin1（= pa0 的所有者）调用 =====

    /// @dev 场景 2a：LP 在 pa0 的底层代币上合规 → 两者都经级联流向 LP。
    function test_unwindPosition_pa_and_regular_routes_both_to_lp_when_compliant(address admin1, address admin2)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency1BeforeMint = _balanceOf(key0.currency1, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(key0.currency1, alice), aliceCurrency1BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev 场景 2b：LP 被移出 pa0 底层代币的白名单 → pa0 级联流向 admin1；普通代币仍流向 LP。
    function test_unwindPosition_pa_and_regular_routes_pa_to_admin_when_lp_blocked(address admin1, address admin2)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency1BeforeMint = _balanceOf(key0.currency1, alice);
        uint256 adminCurrency0BeforeMint = _balanceOf(currency0, admin1);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        // 记录 alice 在铸造时存入了多少 pa0 底层代币
        uint256 deposited0 = aliceCurrency0BeforeMint - _balanceOf(currency0, alice);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, true);

        // pa0 部分以底层代币形式到达 admin1；普通代币部分以底层代币形式到达 alice
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency0, admin1, address(0), address(0), 0, false);
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency1, alice, address(0), address(0), 0, false);
        vm.prank(admin1);
        _unwind(tokenId);

        // admin1 收到的数量约等于 alice 在 pa0 上的存入；普通代币退回给 alice
        assertApproxEqAbs(_balanceOf(currency0, admin1) - adminCurrency0BeforeMint, deposited0, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(key0.currency1, alice), aliceCurrency1BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev 场景 2c：LP 和 admin1 都不在 pa0 底层代币的白名单中 → pa0 以 6909 claim 的形式记给 admin1。
    function test_unwindPosition_pa_and_regular_credits_6909_when_lp_and_admin_blocked(address admin1, address admin2)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency1BeforeMint = _balanceOf(key0.currency1, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        uint256 deposited0 = aliceCurrency0BeforeMint - _balanceOf(currency0, alice);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, false);

        // pa0 部分以 6909 形式到达 admin1（asClaim=true）；普通代币部分以底层代币形式到达 alice
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency0, admin1, address(0), address(0), 0, true);
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency1, alice, address(0), address(0), 0, false);
        vm.prank(admin1);
        _unwind(tokenId);

        // 记给 admin1 的 6909 claim ≈ alice 在 pa0 上的存入；普通代币退回给 alice
        assertApproxEqAbs(manager.balanceOf(admin1, key0.currency0.toId()), deposited0, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(key0.currency1, alice), aliceCurrency1BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    // ===== 场景 3：两种代币都是由不同管理员拥有的 PA；由 admin1（= pa0 的所有者）调用 =====
    // pa0 总是走级联的正常路径，因为 admin1 控制着 currency0 的合规名单。pa2 才是变量。

    /// @dev 场景 3a：LP 在两种底层代币的白名单中 → 两者都经级联流向 LP。
    function test_unwindPosition_two_pas_different_admins_routes_both_to_lp(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(currency2, alice), aliceCurrency2BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev 场景 3b：LP 被移出 currency2 的白名单 → pa0 → LP，pa2 → admin2（pa2 的管理员）。
    function test_unwindPosition_two_pas_different_admins_routes_pa2_to_admin2_when_lp_blocked(
        address admin1,
        address admin2
    ) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);
        uint256 admin2Currency2BeforeMint = _balanceOf(currency2, admin2);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        uint256 deposited2 = aliceCurrency2BeforeMint - _balanceOf(currency2, alice);

        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(admin2, true);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(currency2, admin2) - admin2Currency2BeforeMint, deposited2, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev 场景 3c：LP 和 admin2 都被移出 currency2 的白名单 → pa0 → LP，pa2 → 记给 admin2 的 6909 claim。
    function test_unwindPosition_two_pas_different_admins_credits_6909_when_lp_and_admin2_blocked(
        address admin1,
        address admin2
    ) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        uint256 deposited2 = aliceCurrency2BeforeMint - _balanceOf(currency2, alice);

        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(admin2, false);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(manager.balanceOf(admin2, key2.currency1.toId()), deposited2, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev 非 PA 的边界情况：向 LP 转账普通 ERC-20 时回滚（例如 LP 被该代币列入黑名单）。
    ///      级联回退为向 LP 铸造 6909 claim——而不是给任何管理员。
    function test_unwindPosition_non_pa_credits_6909_to_lp_when_lp_rejects(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0); // [pa0, 普通代币]

        uint256 aliceRegularPostMint = _balanceOf(key0.currency1, alice);

        // 强制使普通 ERC-20 向 alice 的转账回滚（模拟黑名单或合规 hook）
        vm.mockCallRevert(
            Currency.unwrap(key0.currency1),
            abi.encodeWithSelector(IERC20.transfer.selector, alice),
            bytes("LP rejects")
        );

        // pa0 部分以底层代币形式到达 alice；普通代币部分回退为向 alice 铸造 6909（asClaim=true）
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency0, alice, address(0), address(0), 0, false);
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency1, alice, address(0), address(0), 0, true);
        vm.prank(admin1);
        _unwind(tokenId);

        // alice 的普通代币余额不变（转账被拒绝），但她改为收到了 6909 claim
        assertEq(_balanceOf(key0.currency1, alice), aliceRegularPostMint);
        assertGt(manager.balanceOf(alice, key0.currency1.toId()), 0);
        // admin1 没有该普通代币的 6909 claim——管理员不托管非 PA 资产
        assertEq(manager.balanceOf(admin1, key0.currency1.toId()), 0);
    }

    // ===== 权限校验 / 任一管理员 =====

    function test_unwindPosition_reverts_when_caller_is_not_admin(address admin1, address admin2, address notAdmin)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);
        vm.assume(notAdmin != admin1 && notAdmin != admin2);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        vm.prank(notAdmin);
        (bool ok, bytes memory data) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertEq(ok, false);
        assertEq(bytes4(data), Unauthorized.selector);
    }

    /// @dev 任一 PA 管理员都可以调用 `unwindPosition`。管理员不同时，分别测试两者。
    function test_unwindPosition_either_admin_acts_independently(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);
        vm.assume(admin1 != admin2);

        uint256 tokenId0 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);
        uint256 tokenId1 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        vm.prank(admin1);
        _unwind(tokenId0);
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId0);

        vm.prank(admin2);
        _unwind(tokenId1);
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId1);
    }

    // ===== withdrawClaim =====

    /// @dev 强制级联走到 6909 回退分支（LP 和 admin1 都被移出 currency0 的白名单），然后通过
    ///      `withdrawClaim` 将 admin1 持有的 claim 赎回到一个新的 `to` 地址。
    function test_withdrawClaim_round_trip(address admin1, address admin2, address to) public {
        _setupUnwindPositionTests(admin1, admin2);
        // `to` 必须不同于已有的参与者以及操作处理器的哨兵值（MSG_SENDER = 0x1 /
        // ADDRESS_THIS = 0x2 会在 TAKE 操作中被 _mapRecipient 重新映射）
        vm.assume(to != address(0));
        vm.assume(to != ActionConstants.MSG_SENDER);
        vm.assume(to != ActionConstants.ADDRESS_THIS);
        vm.assume(to != alice);
        vm.assume(to != admin1);
        vm.assume(to != address(manager));
        vm.assume(to != address(lpm));
        vm.assume(to != address(permissionsAdapter0));
        vm.assume(to != address(permissionsAdapter2));

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, false);

        vm.prank(admin1);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin1, key0.currency0.toId());
        assertGt(claim, 0);

        // `to` 需要在底层代币的合规名单中，才能在解包时收到 secToken
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(to, PermissionFlags.ALL_ALLOWED);

        // admin1 授权 permPosm 销毁其 6909 claim
        vm.prank(admin1);
        manager.setOperator(address(lpm), true);

        uint256 toBefore = _balanceOf(currency0, to);
        vm.expectEmit(true, true, true, true);
        emit ClaimWithdrawn(key0.currency0, admin1, to, claim);
        vm.prank(admin1);
        _withdrawClaim(key0.currency0, claim, to);

        // claim 被完全消耗；to 恰好收到 `claim` 数量的底层代币
        assertEq(manager.balanceOf(admin1, key0.currency0.toId()), 0);
        assertEq(_balanceOf(currency0, to) - toBefore, claim);
    }

    /// @dev `MSG_SENDER` 哨兵值在底层代币交付和
    ///      `ClaimWithdrawn` 事件中都必须解析为操作执行者。采用与往返测试相同的级联至 6909 的设置。
    function test_withdrawClaim_resolves_msg_sender_sentinel() public {
        address admin = makeAddr("WC_ADMIN_MS");
        address other = makeAddr("WC_OTHER_MS");
        _setupUnwindPositionTests(admin, other);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin, false);

        vm.prank(admin);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin, key0.currency0.toId());
        assertGt(claim, 0);

        // 将管理员重新加入白名单，使 TAKE 时的解包能把底层代币交付回给它
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(admin, PermissionFlags.ALL_ALLOWED);

        vm.prank(admin);
        manager.setOperator(address(lpm), true);

        vm.expectEmit(true, true, true, true);
        emit ClaimWithdrawn(key0.currency0, admin, admin, claim);
        vm.prank(admin);
        _withdrawClaim(key0.currency0, claim, ActionConstants.MSG_SENDER);
    }

    /// @dev `ADDRESS_THIS` 哨兵值在交付和事件中都必须解析为 PositionManager。
    function test_withdrawClaim_resolves_address_this_sentinel() public {
        address admin = makeAddr("WC_ADMIN_AT");
        address other = makeAddr("WC_OTHER_AT");
        _setupUnwindPositionTests(admin, other);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin, false);

        vm.prank(admin);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin, key0.currency0.toId());
        assertGt(claim, 0);

        // TAKE 会解包到 permPosm，因此必须允许它接收底层代币
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);

        vm.prank(admin);
        manager.setOperator(address(lpm), true);

        vm.expectEmit(true, true, true, true);
        emit ClaimWithdrawn(key0.currency0, admin, address(lpm), claim);
        vm.prank(admin);
        _withdrawClaim(key0.currency0, claim, ActionConstants.ADDRESS_THIS);
    }

    /// @dev 调用者未通过 `setOperator` 授权 permPosm → BURN_6909 在额度检查时下溢。
    function test_withdrawClaim_reverts_without_operator() public {
        vm.startPrank(alice);
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_WITHDRAW_CLAIM_SELECTOR, key2.currency0, 1, alice));
        vm.stopPrank();
        assertEq(ok, false);
    }

    /// @dev 调用者已授权 permPosm，但没有 6909 余额 → BURN_6909 通过授权检查，并在
    ///      扣减余额时下溢。
    function test_withdrawClaim_reverts_without_balance() public {
        vm.prank(alice);
        manager.setOperator(address(lpm), true);

        vm.startPrank(alice);
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_WITHDRAW_CLAIM_SELECTOR, key2.currency0, 1, alice));
        vm.stopPrank();
        assertEq(ok, false);
    }

    /// @dev BURN_6909 必须拒绝不是操作执行者的 `from`，即使持有者已将 permPosm 授权为
    ///      PoolManager 的操作者。否则第三方可以通过直接调用
    ///      `modifyLiquidities([BURN_6909(currency, victim, amount), TAKE(currency, attacker, amount)])` 掏空该 claim。
    function test_burn6909_reverts_when_from_is_not_executor(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);
        address bob = makeAddr("BOB");
        vm.assume(bob != admin1 && bob != admin2 && bob != alice);

        // 通过 unwind 级联生成一个由 admin1 持有的 6909 claim
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, false);
        vm.prank(admin1);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin1, key0.currency0.toId());
        assertGt(claim, 0);

        // admin1 遵循文档中说明的 withdrawClaim 授权模式
        vm.prank(admin1);
        manager.setOperator(address(lpm), true);

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key0.currency0, admin1, claim);
        params[1] = abi.encode(key0.currency0, bob, claim);

        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        lpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /// @dev TAKE(adapter, ADDRESS_THIS) 会使 POSM 持有底层许可代币
    /// （因为 PermissionsAdapter._update 在从 PoolManager 转出时会自动解包）。
    /// 因此 SWEEP(adapter, ...) 必须解析为底层代币并转移它——而不是适配器代币——
    /// 否则底层代币会滞留，并可被后来的调用者清扫（sweep）走。
    function test_sweep_adapterCurrency_transfersUnderlyingToRecipient() public {
        Currency adapterCurrency = key0.currency0;
        Currency underlying = getPermissionedCurrency(adapterCurrency);

        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidityToAdd = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, address(this), ZERO_BYTES);

        uint256 recipientUnderlyingBefore = underlying.balanceOf(alice);
        uint256 recipientAdapterBefore = adapterCurrency.balanceOf(alice);

        // 先 DECREASE 产生正 delta，然后 TAKE(adapter, ADDRESS_THIS) 通过适配器解包将
        // 底层代币转入 POSM，最后 SWEEP(adapter, alice)。
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.TAKE, abi.encode(adapterCurrency, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        planner.add(Actions.SWEEP, abi.encode(adapterCurrency, alice));

        lpm.modifyLiquidities(planner.encode(), _deadline);

        // Alice 收到的是底层代币，而不是适配器代币。
        assertGt(underlying.balanceOf(alice), recipientUnderlyingBefore, "recipient did not receive underlying");
        assertEq(
            adapterCurrency.balanceOf(alice), recipientAdapterBefore, "recipient should not receive adapter tokens"
        );
        // POSM 不应残留任何底层代币或适配器代币。
        assertEq(underlying.balanceOf(address(lpm)), 0, "underlying stranded in POSM");
        assertEq(adapterCurrency.balanceOf(address(lpm)), 0, "adapter stranded in POSM");
    }

    /// @dev 第二次以适配器代币调用 SWEEP 必须是空操作——底层代币
    /// 已在第一次清扫时转出。
    function test_sweep_adapterCurrency_secondSweepTransfersNothing() public {
        Currency adapterCurrency = key0.currency0;
        Currency underlying = getPermissionedCurrency(adapterCurrency);

        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidityToAdd = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, address(this), ZERO_BYTES);

        uint256 aliceBefore = underlying.balanceOf(alice);
        uint256 selfBefore = underlying.balanceOfSelf();

        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.TAKE, abi.encode(adapterCurrency, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        planner.add(Actions.SWEEP, abi.encode(adapterCurrency, alice));
        // 第二次清扫发往测试合约（同样在白名单中），并且不应转移任何代币，
        // 因为 POSM 的底层代币余额已在第一次清扫中被全部转出。
        planner.add(Actions.SWEEP, abi.encode(adapterCurrency, address(this)));

        lpm.modifyLiquidities(planner.encode(), _deadline);

        assertGt(underlying.balanceOf(alice), aliceBefore, "first recipient received nothing");
        assertEq(underlying.balanceOfSelf(), selfBefore, "second sweep should transfer nothing");
        assertEq(adapterCurrency.balanceOfSelf(), 0, "second sweep should not transfer adapter");
    }

    /// @dev 清扫非许可代币的行为不变：它仍会转出 POSM 恰好持有的
    /// 该代币的全部余额。
    function test_sweep_nonPermissionedCurrency_stillTransfersBalance() public {
        Currency nonPermissioned = key0.currency1;
        uint256 amount = 123 ether;
        nonPermissioned.transfer(address(lpm), amount);

        address recipient = makeAddr("RECIPIENT");
        uint256 recipientBefore = nonPermissioned.balanceOf(recipient);

        Plan memory planner = Planner.init();
        planner.add(Actions.SWEEP, abi.encode(nonPermissioned, recipient));
        lpm.modifyLiquidities(planner.encode(), _deadline);

        assertEq(nonPermissioned.balanceOf(recipient) - recipientBefore, amount);
        assertEq(nonPermissioned.balanceOf(address(lpm)), 0);
    }

    // ===== unwindPosition 上由调用者提供的销毁边界与 hookData =====

    /// @dev 销毁能够满足的数量边界不会改变结果。
    function test_unwindPosition_withSatisfiableMinAmounts_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(1), uint128(1), bytes("")));

        assertEq(ok, true);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev 销毁无法满足的数量边界会使整个强制退出回滚，并保持头寸不变。
    function test_unwindPosition_withUnsatisfiableMinAmounts_revertsAndPreservesPosition() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);
        uint256 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        (bool ok, bytes memory data) = address(lpm)
            .call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, type(uint128).max, type(uint128).max, bytes("")));

        assertEq(ok, false);
        assertEq(bytes4(data), SlippageCheck.MinimumAmountInsufficient.selector);
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore, "position untouched");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    /// @dev 带有移除流动性回调的自定义 hook 扩展会收到调用者提供的 `hookData`。
    function test_unwindPosition_forwardsHookDataToHook() public {
        (MockRemoveLiquidityDataHook hook, PoolKey memory hookKey) = _setUpRemoveLiquidityDataHookPool();
        uint256 tokenId = lpm.nextTokenId();
        PositionConfig memory config = PositionConfig({poolKey: hookKey, tickLower: -120, tickUpper: 120});
        vm.prank(alice);
        mint(config, 1e18, alice, ZERO_BYTES);

        bytes memory hookData = abi.encode("force-exit", tokenId);
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), hookData));

        assertEq(ok, true);
        assertEq(hook.lastHookData(), hookData, "hook received the caller-supplied hookData");
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
    }

    /// @dev 对照组：同一个池在 hookData 为空时会在 hook 中回滚，证明上面的测试之所以通过，
    ///      是因为数据被转发了，而不是因为该 hook 什么都不做。
    function test_unwindPosition_emptyHookDataRevertsInHook() public {
        (, PoolKey memory hookKey) = _setUpRemoveLiquidityDataHookPool();
        uint256 tokenId = lpm.nextTokenId();
        PositionConfig memory config = PositionConfig({poolKey: hookKey, tickLower: -120, tickUpper: 120});
        vm.prank(alice);
        mint(config, 1e18, alice, ZERO_BYTES);

        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));

        assertEq(ok, false);
        assertEq(lpm.getPositionLiquidity(tokenId), 1e18, "position untouched");
    }

    /// @dev 部署一个按 BEFORE_REMOVE_LIQUIDITY_FLAG 挖出地址的 hook，将其加入白名单，并开设一个
    ///      将其与已验证适配器配对的池。
    function _setUpRemoveLiquidityDataHookPool()
        internal
        returns (MockRemoveLiquidityDataHook hook, PoolKey memory hookKey)
    {
        uint160 flags = uint160(1 << 9); // BEFORE_REMOVE_LIQUIDITY_FLAG
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), flags, vm.getCode("MockRemoveLiquidityDataHook.sol:MockRemoveLiquidityDataHook"), ""
        );
        address deployed =
            Deploy.create2(vm.getCode("MockRemoveLiquidityDataHook.sol:MockRemoveLiquidityDataHook"), salt);
        assertEq(deployed, expected);
        hook = MockRemoveLiquidityDataHook(payable(deployed));

        (hookKey,) = initPool(
            Currency.wrap(address(permissionsAdapter0)),
            Currency.wrap(address(permissionsAdapter2)),
            IHooks(deployed),
            3000,
            SQRT_PRICE_1_1
        );
        setAllowedHooks(Currency.wrap(address(permissionsAdapter0)), IHooks(deployed), true);
        setAllowedHooks(Currency.wrap(address(permissionsAdapter2)), IHooks(deployed), true);
    }

    // ===== unwindPosition 上针对订阅者 DoS 的防护 =====

    /// @dev 管理员强制退出仍会成功，即使 LP 挂载的订阅者在
    ///      `notifyUnsubscribe` 时回滚。该回滚受 gas 上限限制，并在 `_unsubscribe` 内部被 try/catch 捕获。
    function test_unwindPosition_with_unsubscribe_reverting_subscriber_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockUnsubscribeRevertingSubscriber sub = new MockUnsubscribeRevertingSubscriber();
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(sub));

        // address(this) 是两个适配器的管理员（默认 setUp）
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertEq(ok, true);

        // 订阅者已解除挂载，NFT 已销毁
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev 管理员强制退出仍会成功，即使 LP 挂载的订阅者会留下一个未结算（UNSETTLED）的
    ///      PoolManager delta（在 `notifyUnsubscribe` 期间给自己铸造 1 wei 的原生 ETH 6909 claim
    ///      并正常返回）。`_unsubscribe` 中受 gas 上限限制的 try/catch 无从捕获，
    ///      因此该 delta 绝不能在已开启的 unlock 内部产生——否则外层的 `unlock` 会在
    ///      回调之后以 `CurrencyNotSettled` 回滚，导致强制退出彻底失效。这是针对
    ///      闪电记账恶意消耗（griefing）攻击向量的回归测试：`_unsubscribe` 在 manager 处于锁定状态时运行，因此
    ///      订阅者的 `mint` 会在回调内以 `ManagerLocked` 回滚并被吸收。
    function test_unwindPosition_with_flashAttackSubscriber_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockFlashAttackSubscriber sub = new MockFlashAttackSubscriber(manager);
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(sub));

        // address(this) 是两个适配器的管理员（默认 setUp）。
        // 修复之前，这里会以 CurrencyNotSettled 回滚，且 `ok` 为 false。
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertEq(ok, true);

        // 订阅者已解除挂载，NFT 已销毁。这里不断言 `notifyUnsubscribeCount`：由于 manager
        // 处于锁定状态，订阅者的 `mint` 会在回调内回滚，因此整个回调（及其
        // 计数器自增）都会被回滚，并被 try/catch 吞掉。
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev 管理员强制退出仍会成功，即使 LP 向一个恶意的
    ///      重入订阅者授予了操作者授权，而该订阅者会在 `notifyUnsubscribe` 期间重新挂载一个新的订阅者。
    ///      `_unsubscribe` 在 manager 锁定状态下运行，因此 `subscribe` 的 `onlyIfPoolManagerLocked`
    ///      检查会通过，重新挂载也会成功；随后 `unwindPosition` 中的强制清除会在
    ///      BURN_POSITION 之前移除这个替换者，因此它会回滚的 `notifyBurn` 永远不会执行。
    function test_unwindPosition_with_reentrant_subscriber_reattach_is_force_cleared() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // 重入订阅者重新挂载的替换者；它的 `notifyBurn` 会回滚，因此如果它
        // 存活到 BURN_POSITION，就会使强制退出彻底失效。
        MockBurnRevertingSubscriber replacement = new MockBurnRevertingSubscriber();

        // LP 挂载的恶意订阅者。在 notifyUnsubscribe 时，它会通过 posm.subscribe
        // 重新挂载 `replacement`。
        MockReentrantSubscriber sub = new MockReentrantSubscriber(INotifier(address(lpm)), address(replacement));

        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(sub));

        // 重入路径要求订阅者有权调用 posm.subscribe。
        // LP 授予操作者授权——这正是我们要测试其防御的场景设置。
        vm.prank(alice);
        IERC721(address(lpm)).setApprovalForAll(address(sub), true);

        // 锁定“重新挂载确实发生”这一点：这正是强制清除必须消除的情况。
        // 如果移除强制清除，`replacement` 就会存活下来，其 notifyBurn 会使销毁彻底失效。
        vm.expectEmit(true, true, false, true, address(lpm));
        emit INotifier.Subscription(tokenId, address(replacement));
        // ……并锁定强制清除随后会在销毁前将其取消订阅，使索引器的记录保持平衡。
        vm.expectEmit(true, true, false, true, address(lpm));
        emit INotifier.Unsubscription(tokenId, address(replacement));

        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertEq(ok, true);

        // 重新挂载的订阅者已在销毁前被强制清除，因此头寸已完全解除挂载。
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev 管理员强制退出仍会成功，即使 LP 的订阅者覆盖了管理员临时的
    ///      ERC-721 授权（在 `notifyUnsubscribe` 期间）。`approve` 没有 `onlyIfPoolManagerLocked` 检查，因此
    ///      该写入会生效，但 `unwindPosition` 会在 `_unsubscribe` 返回之后、
    ///      BURN_POSITION 之前再次设置 `getApproved`，因此被劫持的值会被覆盖，销毁仍能通过
    ///      `onlyIfApproved`。这里订阅者就是头寸所有者，因此 `approve` 会在
    ///      `msg.sender == owner` 分支上通过。
    function test_unwindPosition_with_approvalHijackingSubscriber_succeeds() public {
        MockApprovalHijackSubscriber sub = new MockApprovalHijackSubscriber(address(lpm), true, address(0));
        // 合约形式的 LP 需要在两种底层代币上都拥有 LIQUIDITY_ALLOWED 才能持有该头寸
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(sub), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(address(sub), PermissionFlags.ALL_ALLOWED);

        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, 1e18, address(sub), ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(sub));

        sub.subscribeSelf(tokenId);
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(sub));

        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertEq(ok, true);

        // 劫持写入确实在回调内生效了，但被重新授权覆盖丢弃
        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertGt(sub.gasUsedByApprove(), 0);

        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev 同样的劫持，但改为经由 `isApprovedForAll[owner][msg.sender]` 分支：一个 EOA 形式的 LP 挂载一个
    ///      独立的恶意订阅者，并授予其全局操作者（operator-for-all）权限。操作者权限比管理员的
    ///      单个 token 授权存续更久，因此这种情形需要单独覆盖测试。
    function test_unwindPosition_with_operatorApprovalHijackingSubscriber_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockApprovalHijackSubscriber sub = new MockApprovalHijackSubscriber(address(lpm), true, address(0));
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");
        vm.prank(alice);
        IERC721(address(lpm)).setApprovalForAll(address(sub), true);

        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertEq(ok, true);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertGt(sub.gasUsedByApprove(), 0);

        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev LP 主动发起的销毁语义保持不变：在 `notifyBurn` 时回滚的订阅者
    ///      在 LP 通过 BURN_POSITION 销毁自己的头寸时，仍会将回滚向上传递。
    function test_burn_lp_with_burn_reverting_subscriber_still_reverts() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockBurnRevertingSubscriber sub = new MockBurnRevertingSubscriber();
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");

        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});

        vm.prank(alice);
        vm.expectRevert();
        burn(tokenId, config, ZERO_BYTES);
    }

    // ===== 操作（action）处理器的权限校验 =====

    /// @notice MINT_6909 和 UNWIND_WITH_FALLBACK 可以直接通过公开的 `modifyLiquidities`
    ///         路由入口调用（它们共用基础的操作分发器）。这之所以安全，仅仅是因为 PermPosm 在两次调用之间
    ///         从不持有常驻的 6909 claim：既然没有任何暂存资产，直接调用就无法提取任何价值。
    ///         本测试锁定这一不变量。如果将来的某次改动使 PermPosm 持有常驻 claim，
    ///         这里的 UNWIND_WITH_FALLBACK 部分将不再回滚，这就表明这些操作需要再次
    ///         加上防护（例如已被移除的 `_isUnwinding` 标志）。
    function test_unwindActions_onPublicRouter_cannotExtractValue() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // UNWIND_WITH_FALLBACK 会销毁 PermPosm 自己的 claim，并将真实资产提取给 `to`。PermPosm 不持有
        // 常驻 claim，因此 `burn(address(this), id, 1)` 无可销毁，整个批次会回滚。
        Plan memory deliver = Planner.init();
        deliver.add(Actions.UNWIND_WITH_FALLBACK, abi.encode(key2.currency0, unauthorizedUser, uint256(1)));
        bytes memory deliverCalls = deliver.encode();
        vm.expectRevert();
        lpm.modifyLiquidities(deliverCalls, block.timestamp + 1);

        // MINT_6909 会把 PermPosm 的全部正 delta 铸造给它自己。没有 delta 时，`_getFullCredit` 为 0，
        // 铸造为空操作：批次会成功，但不会在 PermPosm 上暂存任何 claim，也不会给调用者任何东西。
        Plan memory settle = Planner.init();
        settle.add(Actions.MINT_6909, abi.encode(key2.currency0));
        lpm.modifyLiquidities(settle.encode(), block.timestamp + 1);
        assertEq(manager.balanceOf(address(lpm), key2.currency0.toId()), 0, "PermPosm parked no claim");
        assertEq(manager.balanceOf(unauthorizedUser, key2.currency0.toId()), 0, "caller received no claim");

        // Alice 的头寸未受影响。
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }
}
