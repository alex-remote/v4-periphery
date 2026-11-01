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
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Actions} from "../../src/libraries/Actions.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract ExecuteTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    PositionConfig config;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // 需要它来接收 modifyLiquidity 调用返回的 delta。
        deployPosmHookSavesDelta();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        // 要求 currency0 和 currency1 已在基础合约 Deployers 中设置好。
        deployAndApprovePosm(manager);

        // 给 Alice 和 Bob 发放代币。
        seedBalance(alice);
        seedBalance(bob);

        // 为 Alice 和 Bob 授权 posm。
        approvePosmFor(alice);
        approvePosmFor(bob);

        // 定义一个可复用的池头寸
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_fuzz_execute_increaseLiquidity_once(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        increaseLiquidity(tokenId, config, liquidityToAdd, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    function test_fuzz_execute_increaseLiquidity_twice_withClose(
        uint256 initialLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init();

        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd2, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    function test_fuzz_execute_increaseLiquidity_twice_withSettlePair(
        uint256 initialLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        Plan memory planner = Planner.init();

        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd2, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithSettlePair(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    // 这种情况在实际使用中没有意义，所以没有起一个很酷的名字，但它是一个很好的测试用例
    function test_fuzz_execute_mintAndIncrease(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);

        uint256 tokenId = lpm.nextTokenId(); // 假设 .mint() 产生 tokenId=1，供 increaseLiquidity 使用

        Plan memory planner = Planner.init();

        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                initialLiquidity,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    // rebalance（再平衡）：销毁并铸造
    function test_execute_rebalance_perfect() public {
        uint256 initialLiquidity = 100e18;

        // 在区间 [-300, 300] 上铸造一个头寸
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        // 我们将销毁旧头寸并在 [-60, 60] 上铸造新头寸；计算新区间对应的流动性单位
        PositionConfig memory newConfig = PositionConfig({poolKey: config.poolKey, tickLower: -60, tickUpper: 60});
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(newConfig.tickLower),
            TickMath.getSqrtPriceAtTick(newConfig.tickUpper),
            uint128(-delta.amount0()),
            uint128(-delta.amount1())
        );

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        hook.clearDeltas(); // 清除 delta，以便检查 BURN & MINT 的净 delta

        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION,
            abi.encode(tokenId, uint128(-delta.amount0()) - 1 wei, uint128(-delta.amount1()) - 1 wei, ZERO_BYTES)
        );
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                newConfig.poolKey,
                newConfig.tickLower,
                newConfig.tickUpper,
                newLiquidity,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        lpm.modifyLiquidities(calls, _deadline);
        {
            BalanceDelta netDelta = getNetDelta();

            uint256 balance0After = currency0.balanceOfSelf();
            uint256 balance1After = currency1.balanceOfSelf();

            // TODO: 使用 clear，使用户无需支付 1 wei
            assertEq(netDelta.amount0(), -1 wei);
            assertEq(netDelta.amount1(), -1 wei);
            assertApproxEqAbs(balance0Before - balance0After, 0, 1 wei);
            assertApproxEqAbs(balance1Before - balance1After, 0, 1 wei);
        }

        // 旧头寸已被销毁
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);

        {
            // 旧头寸没有流动性
            uint128 liquidity = lpm.getPositionLiquidity(tokenId);
            assertEq(liquidity, 0);

            // 新 token 已被铸造
            uint256 newTokenId = lpm.nextTokenId() - 1;
            assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this));

            // 新 token 具有预期的流动性

            liquidity = lpm.getPositionLiquidity(newTokenId);
            assertEq(liquidity, newLiquidity);
        }
    }

    // coalesce（合并）：销毁并增加流动性
    function test_execute_coalesce() public {}
    // split（拆分）：减少流动性并铸造
    function test_execute_split() public {}
    // shift（平移）：减少并增加流动性
    function test_execute_shift() public {}
    // shard（分片）：收取并铸造
    function test_execute_shard() public {}
    // feed（注入）：收取并增加流动性
    function test_execute_feed() public {}

    // transplant（移植）：在不同的 key 上销毁并铸造
    function test_execute_transplant() public {}
    // cross-coalesce：在不同的 key 上销毁并增加流动性
    function test_execute_crossCoalesce() public {}
    // cross-split：在不同的 key 上减少流动性并铸造
    function test_execute_crossSplit() public {}
    // cross-shift：在不同的 key 上减少并增加流动性
    function test_execute_crossShift() public {}
    // cross-shard：在不同的 key 上收取并铸造
    function test_execute_crossShard() public {}
    // cross-feed：在不同的 key 上收取并增加流动性
    function test_execute_crossFeed() public {}
}
