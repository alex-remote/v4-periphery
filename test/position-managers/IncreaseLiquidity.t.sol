// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {SlippageCheck} from "../../src/libraries/SlippageCheck.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

contract IncreaseLiquidityTest is Test, PosmTestSetup, Fuzzers {
    using FixedPointMathLib for uint256;
    using FeeMath for IPositionManager;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // 以 wad 形式表示手续费（即 3000 = 0.003e18 = 0.30%）
    uint256 FEE_WAD;

    PositionConfig config;

    // 误差容限。
    uint256 tolerance = 0.00000000001 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // 需要它来接收 modifyLiquidity 调用返回的 delta。
        deployPosmHookSavesDelta();

        (key, poolId) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        // 要求已在基础合约 Deployers 中设置 currency0 和 currency1。
        deployAndApprovePosm(manager);

        // 给 Alice 和 Bob 发放代币。
        seedBalance(alice);
        seedBalance(bob);

        // 让 Alice 和 Bob 对 posm 授权。
        approvePosmFor(alice);
        approvePosmFor(bob);

        // 定义一个可复用的区间
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    /// @notice 增加的流动性少于头寸已赚取的流动性，因此需要一次提取（take）
    function test_increaseLiquidity_withCollection_takePair() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 用她恰好赚到的手续费增加流动性（复投）

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice 提供流动性
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob 提供流动性
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // 通过 donate 产生手续费
        uint256 amountDonate = 0.1e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice 用她一半的手续费增加流动性
        // 此计算与实际手续费之间存在轻微误差。TODO: 修复此问题。
        BalanceDelta feesOwedAlice = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);
        // 注意：也可以根据兑换（swap）数量、池的手续费率以及该区间内的总流动性来计算 Alice 应得的手续费。
        // swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint256(int256(feesOwedAlice.amount0() / 2)),
            uint256(int256(feesOwedAlice.amount1() / 2))
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        //  把滑点数量设为恰好等于 alice 用于再投资的那一半手续费。

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(
                tokenIdAlice, liquidityDelta, feesOwedAlice.amount0() / 2, feesOwedAlice.amount1() / 2, ZERO_BYTES
            )
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(alice));
        vm.startPrank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.stopPrank();

        // alice 当前的余额等于 balanceBefore 加上她应得手续费的一半
        assertApproxEqAbs(
            currency0.balanceOf(alice), balance0BeforeAlice + uint256(int256(feesOwedAlice.amount0() / 2)), tolerance
        );
        assertApproxEqAbs(
            currency1.balanceOf(alice), balance1BeforeAlice + uint256(int256(feesOwedAlice.amount1() / 2)), tolerance
        );
    }

    /// @notice 用恰好的手续费增加流动性，并提取（take）剩余零头（dust）
    function test_increaseLiquidity_withExactFees_take() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 用她恰好赚到的手续费增加流动性（复投）

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice 提供流动性
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob 提供流动性
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // 通过兑换（swap）产生手续费
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // 把价格移回原处

        // alice 用她恰好赚到的手续费增加流动性
        // 此计算与实际手续费之间存在轻微误差。TODO: 修复此问题。
        BalanceDelta feesOwedAlice = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);
        // 注意：也可以根据兑换（swap）数量、池的手续费率以及该区间内的总流动性来计算 Alice 应得的手续费。
        // swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint256(int256(feesOwedAlice.amount0())),
            uint256(int256(feesOwedAlice.amount1()))
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, feesOwedAlice.amount0(), feesOwedAlice.amount1(), ZERO_BYTES)
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        vm.startPrank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.stopPrank();

        // alice 几乎没有花费任何代币
        assertApproxEqAbs(balance0BeforeAlice, currency0.balanceOf(alice), tolerance);
        assertApproxEqAbs(balance1BeforeAlice, currency1.balanceOf(alice), tolerance);
    }

    /// @dev 用恰好的手续费增加流动性，并清除（clear）剩余零头（dust）
    function test_increaseLiquidity_withExactFees_clear() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 用她恰好赚到的手续费增加流动性（复投）

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice 提供流动性
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob 提供流动性
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // 通过兑换（swap）产生手续费
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // 把价格移回原处

        // alice 用她恰好赚到的手续费增加流动性
        // 此计算与实际手续费之间存在轻微误差。TODO: 修复此问题。
        BalanceDelta feesOwedAlice = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);
        // 注意：也可以根据兑换（swap）数量、池的手续费率以及该区间内的总流动性来计算 Alice 应得的手续费。
        // swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint256(int256(feesOwedAlice.amount0())),
            uint256(int256(feesOwedAlice.amount1()))
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, 18 wei)); // alice 愿意放弃 18 wei
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, 18 wei));
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);

        // alice 既没有花费也没有收到代币
        // （alice 通过 CLEAR 把少量代币放弃给了池）
        assertEq(currency0.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1.balanceOf(alice), balance1BeforeAlice);
    }

    // 使用 donate 模拟手续费收入，并提取（take）零头（dust）
    function test_increaseLiquidity_withExactFees_take_donate() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 用她恰好赚到的手续费增加流动性（复投）

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice 提供流动性
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob 提供流动性
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // 通过 donate 产生手续费
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // 减去 1，因为我们宁可提取（take）也不愿支付
        uint256 feesAmount = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            feesAmount,
            feesAmount
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        vm.startPrank(alice);
        increaseLiquidity(tokenIdAlice, config, liquidityDelta, ZERO_BYTES);
        vm.stopPrank();

        // alice 几乎没有花费任何代币
        assertApproxEqAbs(balance0BeforeAlice, currency0.balanceOf(alice), 1 wei);
        assertApproxEqAbs(balance1BeforeAlice, currency1.balanceOf(alice), 1 wei);
    }

    // 使用 donate 模拟手续费收入，并清除（clear）零头（dust）
    function test_increaseLiquidity_withExactFees_clear_donate() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 用她恰好赚到的手续费增加流动性（复投）

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice 提供流动性
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob 提供流动性
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // 通过 donate 产生手续费
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // 减去 1，因为我们宁可提取（take）也不愿支付
        uint256 feesAmount = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            feesAmount,
            feesAmount
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, 1 wei)); // alice 愿意放弃 1 wei
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, 1 wei));
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);

        // alice 既没有花费也没有收到代币
        // （alice 通过 CLEAR 把少量代币放弃给了池）
        assertEq(currency0.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1.balanceOf(alice), balance1BeforeAlice);
    }

    function test_increaseLiquidity_sameRange_withExcessFees() public {
        // Alice 和 Bob 在同一区间上提供流动性
        // Alice 用一半的手续费增加流动性，另一半被收取到她的钱包。
        // Bob 收取全部手续费。
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice 提供流动性
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob 提供流动性
        vm.prank(bob);
        uint256 tokenIdBob = lpm.nextTokenId();
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // 通过兑换（swap）产生手续费
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // 把价格移回原处

        {
            // alice 将用她一半的手续费增加流动性
            BalanceDelta aliceFeesOwed = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);

            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(config.tickLower),
                TickMath.getSqrtPriceAtTick(config.tickUpper),
                uint256(int256(aliceFeesOwed.amount0() / 2)),
                uint256(int256(aliceFeesOwed.amount1() / 2))
            );
            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            increaseLiquidity(tokenIdAlice, config, liquidityDelta, ZERO_BYTES);
            vm.stopPrank();

            assertApproxEqAbs(
                currency0.balanceOf(alice) - balance0BeforeAlice,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
                tolerance
            );
            assertApproxEqAbs(
                currency1.balanceOf(alice) - balance1BeforeAlice,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
                tolerance
            );

            assertApproxEqAbs(
                currency0.balanceOf(alice) - balance0BeforeAlice, uint128(aliceFeesOwed.amount0()) / 2, tolerance
            );

            assertApproxEqAbs(
                currency1.balanceOf(alice) - balance1BeforeAlice, uint128(aliceFeesOwed.amount1()) / 2, tolerance
            );
        }

        {
            // bob 收取他的手续费
            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            collect(tokenIdBob, config, ZERO_BYTES);
            vm.stopPrank();

            assertApproxEqAbs(
                currency0.balanceOf(bob) - balance0BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );
            assertApproxEqAbs(
                currency1.balanceOf(bob) - balance1BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );

            uint256 balance0AfterBob = currency0.balanceOf(bob);
            uint256 balance1AfterBob = currency1.balanceOf(bob);
            assertApproxEqAbs(
                balance0AfterBob - balance0BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                1 wei
            );
            assertApproxEqAbs(
                balance1AfterBob - balance1BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                1 wei
            );
        }
    }

    function test_increaseLiquidity_withInsufficientFees() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 用她的手续费增加流动性，并额外投入资金来增加流动性
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice 提供流动性
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob 提供流动性
        vm.startPrank(bob);
        uint256 tokenIdBob = lpm.nextTokenId();
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // 通过兑换（swap）产生手续费
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // 把价格移回原处

        // alice 将用她全部的手续费 + 额外资金来增加流动性
        BalanceDelta feesOwed = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);

        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(config.tickLower),
                TickMath.getSqrtPriceAtTick(config.tickUpper),
                uint256(int256(feesOwed.amount0())) * 2,
                uint256(int256(feesOwed.amount1())) * 2
            );

            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            increaseLiquidity(tokenIdAlice, config, liquidityDelta, ZERO_BYTES);
            vm.stopPrank();
            uint256 balance0AfterAlice = currency0.balanceOf(alice);
            uint256 balance1AfterAlice = currency1.balanceOf(alice);

            // Alice 在 0 和 1 上各需支付 feesOwed 数量，因为她向池中投入了 feesOwed * 2。
            assertApproxEqAbs(balance0BeforeAlice - balance0AfterAlice, uint256(int256(feesOwed.amount0())), tolerance);
            assertApproxEqAbs(balance1BeforeAlice - balance1AfterAlice, uint256(int256(feesOwed.amount1())), tolerance);
        }

        {
            // bob 收取他的手续费
            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            collect(tokenIdBob, config, ZERO_BYTES);
            vm.stopPrank();
            uint256 balance0AfterBob = currency0.balanceOf(bob);
            uint256 balance1AfterBob = currency1.balanceOf(bob);
            assertApproxEqAbs(
                balance0AfterBob - balance0BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );
            assertApproxEqAbs(
                balance1AfterBob - balance1BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );
        }
    }

    function test_increaseLiquidity_slippage_revertAmount0() public {
        // 使用严格的滑点参数（amount0）增加流动性会回滚（revert）
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 100e18;
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        // 因 amount0Max 过低而回滚（revert）
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, 1 wei, type(uint128).max, ZERO_BYTES);
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount0 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_increaseLiquidity_slippage_revertAmount1() public {
        // 使用严格的滑点参数（amount1）增加流动性会回滚（revert）
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 100e18;
        (, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        // 因 amount1Max 过低而回滚（revert）
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, type(uint128).max, 1 wei, ZERO_BYTES);
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount1 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_increaseLiquidity_slippage_exactDoesNotRevert() public {
        // 使用恰好合适的滑点参数增加流动性不会回滚（revert）
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 10e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        assertEq(amount0, amount1); // 对称地添加流动性
        uint128 slippage = uint128(amount0) + 1;

        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, slippage, slippage, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        // 确认 delta == 滑点容限
        assertEq(-delta.amount0(), int128(slippage));
        assertEq(-delta.amount1(), int128(slippage));
    }

    /// 兑换（swap）引起的价格变动会导致滑点回滚（revert）
    function test_increaseLiquidity_slippage_revert_swap() public {
        // 使用恰好合适的滑点参数增加流动性不会回滚（revert）
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 10e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        assertEq(amount0, amount1); // 对称地添加流动性
        uint128 slippage = uint128(amount0) + 1;

        // 通过兑换（swap）制造滑点
        swap(key, true, -10e18, ZERO_BYTES);

        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, slippage, slippage, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, slippage, 299996249439153403)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_settleWithBalance_andSweepToOtherAddress() public {
        uint256 liquidityAlice = 3_000e18;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityAlice,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                alice,
                ZERO_BYTES
            )
        );
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));
        // 本测试把余额 sweep 到测试合约，尽管 Alice 才是该交易的调用者
        planner.add(Actions.SWEEP, abi.encode(currency0, address(this)));
        planner.add(Actions.SWEEP, abi.encode(currency1, address(this)));

        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        assertEq(currency0.balanceOf(address(lpm)), 0);
        assertEq(currency0.balanceOf(address(lpm)), 0);

        currency0.transfer(address(lpm), 100e18);
        currency1.transfer(address(lpm), 100e18);

        assertEq(currency0.balanceOf(address(lpm)), 100e18);
        assertEq(currency0.balanceOf(address(lpm)), 100e18);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();
        uint256 amount0 = uint128(-delta.amount0());
        uint256 amount1 = uint128(-delta.amount1());

        // 余额已被 sweep 回本地址。
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(lpm)), 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(lpm)), 0);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amount0);
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 - amount1);
    }

    function test_mint_settleWithBalance_andSweepToMsgSender() public {
        uint256 liquidityAlice = 3_000e18;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityAlice,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                alice,
                ZERO_BYTES
            )
        );
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SWEEP, abi.encode(currency0, ActionConstants.MSG_SENDER));
        planner.add(Actions.SWEEP, abi.encode(currency1, ActionConstants.MSG_SENDER));

        uint256 balanceBefore0 = currency0.balanceOf(alice);
        uint256 balanceBefore1 = currency1.balanceOf(alice);

        uint256 seedAmount = 100e18;
        currency0.transfer(address(lpm), seedAmount);
        currency1.transfer(address(lpm), seedAmount);

        assertEq(currency0.balanceOf(address(lpm)), seedAmount);
        assertEq(currency0.balanceOf(address(lpm)), seedAmount);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();
        uint256 amount0 = uint128(-delta.amount0());
        uint256 amount1 = uint128(-delta.amount1());

        // alice 的余额增加了预存资金中未用于支付铸造的那部分
        assertEq(currency0.balanceOf(alice), balanceBefore0 + (seedAmount - amount0));
        assertEq(currency1.balanceOf(alice), balanceBefore1 + (seedAmount - amount1));
    }

    function test_increaseLiquidity_settleWithBalance() public {
        uint256 liquidityAlice = 3_000e18;

        // alice 提供流动性
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        uint256 liquidity = lpm.getPositionLiquidity(tokenIdAlice);
        assertEq(liquidity, liquidityAlice);

        // alice 使用 PositionManager 中的余额增加流动性
        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityAlice, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));
        // 本测试把余额 sweep 到测试合约，尽管 Alice 才是该交易的调用者
        planner.add(Actions.SWEEP, abi.encode(currency0, address(this)));
        planner.add(Actions.SWEEP, abi.encode(currency1, address(this)));

        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        assertEq(currency0.balanceOf(address(lpm)), 0);
        assertEq(currency0.balanceOf(address(lpm)), 0);

        currency0.transfer(address(lpm), 100e18);
        currency1.transfer(address(lpm), 100e18);

        assertEq(currency0.balanceOf(address(lpm)), 100e18);
        assertEq(currency0.balanceOf(address(lpm)), 100e18);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();
        uint256 amount0 = uint128(-delta.amount0());
        uint256 amount1 = uint128(-delta.amount1());

        liquidity = lpm.getPositionLiquidity(tokenIdAlice);
        assertEq(liquidity, 2 * liquidityAlice);

        // 余额已被 sweep 回本地址。
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(lpm)), 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(lpm)), 0);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amount0);
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 - amount1);
    }

    /// @dev 如果要清除的数量超过最大值，则改为提取（take）该数量
    function test_increaseLiquidity_clearExceedsThenTake() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1000e18, address(this), ZERO_BYTES);

        // 通过 donate 产生手续费收入
        uint256 amountToDonate = 0.2e18;
        donateRouter.donate(key, amountToDonate, amountToDonate, ZERO_BYTES);

        // 计算要添加的流动性数量，使用一半的收益
        uint256 amountToReinvest = amountToDonate / 2;
        uint256 amountToReclaim = amountToDonate / 2; // 预期取回另一半手续费收入
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            amountToReinvest,
            amountToReinvest
        );

        // 把最大可放弃数量设为小于我们预期领取的数量
        uint256 maxClear = amountToReclaim - 2 wei;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, maxClear));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, maxClear));
        bytes memory calls = planner.encode();

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        // 预期会提取（take）多出的部分，因为它超过了可清除的数量
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        assertEq(uint128(delta.amount0()), amountToReclaim - 1 wei); // 精度误差
        assertEq(uint128(delta.amount1()), amountToReclaim - 1 wei);

        assertEq(currency0.balanceOf(address(this)), balance0Before + amountToReclaim - 1 wei);
        assertEq(currency1.balanceOf(address(this)), balance1Before + amountToReclaim - 1 wei);
    }

    /// @dev 清除负的 delta 会回滚（revert）
    function test_increaseLiquidity_clearNegative_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1000e18, address(this), ZERO_BYTES);

        // 用新代币增加流动性，但尝试清除负的 delta
        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, type(uint256).max));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, type(uint256).max));
        bytes memory calls = planner.encode();

        // 因为我们试图清除负的 delta 而回滚（revert）
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, currency0));
        lpm.modifyLiquidities(calls, _deadline);
    }
}
