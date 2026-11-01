// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager, IPoolInitializer_v4} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {IMulticall_v4} from "../../src/interfaces/IMulticall_v4.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {MockSubscriber} from "../mocks/MockSubscriber.sol";

contract PosMGasTest is Test, PosmTestSetup {
    using FixedPointMathLib for uint256;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    // 以 wad 形式表示手续费（即 3000 = 0.003e18 = 0.30%）
    uint256 FEE_WAD;

    PositionConfig config;
    PositionConfig configNative;

    MockSubscriber sub;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        (nativeKey,) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        // 要求在基础 Deployers 合约中已设置 currency0 和 currency1。
        deployAndApprovePosm(manager);

        // 给 Alice 和 Bob 发放代币。
        seedBalance(alice);
        seedBalance(bob);

        // 为 Alice 和 bob 授权 posm。
        approvePosmFor(alice);
        approvePosmFor(bob);

        // 定义一个可复用的区间
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
        configNative = PositionConfig({poolKey: nativeKey, tickLower: -300, tickUpper: 300});

        sub = new MockSubscriber(lpm);
    }

    function test_posm_initcodeHash() public {
        vm.snapshotValue(
            "position manager initcode hash (without constructor params, as uint256)",
            uint256(keccak256(abi.encodePacked(vm.getCode("PositionManager.sol:PositionManager"))))
        );
    }

    function test_bytecodeSize_positionManager() public {
        vm.snapshotValue("positionManager bytecode size", address(lpm).code.length);
    }

    function test_gas_mint_withClose() public {
        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    config.poolKey,
                    config.tickLower,
                    config.tickUpper,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_withClose");
    }

    function test_gas_mint_withSettlePair() public {
        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    config.poolKey,
                    config.tickLower,
                    config.tickUpper,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    address(this),
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithSettlePair(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_withSettlePair");
    }

    function test_gas_mint_differentRanges() public {
        // 显式地在同一个池上铸造到一个新区间。
        PositionConfig memory bob_mint = PositionConfig({poolKey: key, tickLower: 0, tickUpper: 60});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // 铸造到不同的配置，不同的用户。
        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    config.poolKey,
                    config.tickLower,
                    config.tickUpper,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_warmedPool_differentRange");
    }

    function test_gas_mint_sameTickLower() public {
        // 显式地铸造到 tickLower 相同的区间。
        PositionConfig memory bob_mint = PositionConfig({poolKey: key, tickLower: -300, tickUpper: -60});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // 铸造到不同的配置，不同的用户。
        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    config.poolKey,
                    config.tickLower,
                    config.tickUpper,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_onSameTickLower");
    }

    function test_gas_mint_sameTickUpper() public {
        // 显式地铸造到 tickUpper 相同的区间。
        PositionConfig memory bob_mint = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 300});
        vm.startPrank(bob);
        mint(bob_mint, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // 铸造到不同的配置，不同的用户。
        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    config.poolKey,
                    config.tickLower,
                    config.tickUpper,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_onSameTickUpper");
    }

    function test_gas_increaseLiquidity_erc20_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_increaseLiquidity_erc20_withClose");
    }

    function test_gas_increaseLiquidity_erc20_withSettlePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, address(this), ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithSettlePair(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_increaseLiquidity_erc20_withSettlePair");
    }

    function test_gas_autocompound_exactUnclaimedFees() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 使用她恰好等额的手续费来增加流动性（复利）

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

        // 捐赠以产生手续费
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice 使用她恰好等额的手续费来增加流动性
        uint256 tokensOwedAlice = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            tokensOwedAlice,
            tokensOwedAlice
        );

        Plan memory planner = Planner.init()
            .add(
                Actions.INCREASE_LIQUIDITY,
                abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );
        // 因为这是完美的自动复利，delta 恰好为 0，我们不需要 "close" delta
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_increase_autocompoundExactUnclaimedFees");
    }

    function test_gas_autocompound_clearExcess() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 使用她恰好等额的手续费来增加流动性（复利）

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

        // 捐赠以产生手续费
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice 将使用她一半的手续费来增加流动性
        uint256 halfTokensOwedAlice = (amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1) / 2;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            halfTokensOwedAlice,
            halfTokensOwedAlice
        );

        // Alice 选择放弃未领取的代币
        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, halfTokensOwedAlice + 1 wei));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, halfTokensOwedAlice + 1 wei));
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_increase_autocompound_clearExcess");
    }

    // 自动复利，但多余的手续费会被提取给用户
    function test_gas_autocompound_excessFeesCredit() public {
        // Alice 和 Bob 在该区间上提供流动性
        // Alice 使用她的手续费来增加流动性。多余的手续费记入 alice 名下
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

        // 捐赠以产生手续费
        uint256 amountDonate = 20e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice 将使用她一半的手续费来增加流动性
        uint256 halfTokensOwedAlice = (amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1) / 2;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            halfTokensOwedAlice,
            halfTokensOwedAlice
        );

        Plan memory planner = Planner.init()
            .add(
                Actions.INCREASE_LIQUIDITY,
                abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_increase_autocompoundExcessFeesCredit");
    }

    function test_gas_decreaseLiquidity_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_decreaseLiquidity_withClose");
    }

    function test_gas_decreaseLiquidity_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_decreaseLiquidity_withTakePair");
    }

    function test_gas_multicall_initialize_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // 使用 multicall 初始化池并铸造流动性
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, SQRT_PRICE_1_1);

        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(lpm).multicall(calls);
        vm.snapshotGasLastCall("PositionManager_multicall_initialize_mint");
    }

    function test_gas_collect_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 捐赠以产生手续费收入
        donateRouter.donate(config.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        // 通过以 0 调用 decrease 来收取手续费。
        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_collect_withClose");
    }

    function test_gas_collect_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 捐赠以产生手续费收入
        donateRouter.donate(config.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        // 通过以 0 调用 decrease 来收取手续费。
        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_collect_withTakePair");
    }

    // 同一区间的 gas 测试
    function test_gas_sameRange_mint() public {
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    config.poolKey,
                    config.tickLower,
                    config.tickUpper,
                    10_001 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_sameRange");
    }

    function test_gas_sameRange_decrease() public {
        // 两个相同配置的头寸，其中一个减少全部流动性
        vm.startPrank(alice);
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_decrease_sameRange_allLiquidity");
    }

    function test_gas_sameRange_collect() public {
        // 两个相同配置的头寸，其中一个收取其全部手续费
        vm.startPrank(alice);
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 捐赠以产生手续费收入
        donateRouter.donate(config.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_collect_sameRange");
    }

    function test_gas_burn_nonEmptyPosition_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES));
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_burn_nonEmpty_withClose");
    }

    function test_gas_burn_nonEmptyPosition_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES));
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(this));

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_burn_nonEmpty_withTakePair");
    }

    function test_gas_burnEmpty() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        decreaseLiquidity(tokenId, config, 10_000 ether, ZERO_BYTES);
        Plan memory planner = Planner.init()
            .add(Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES));

        // 无需包含 CLOSE 命令。
        bytes memory calls = planner.encode();
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_burn_empty");
    }

    function test_gas_decrease_burnEmpty_batch() public {
        // 这会比不编码 decrease、只编码 burn 更昂贵。
        // 即：将其与 PositionManager_burn_nonEmpty 进行对比
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        planner.add(
            Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );

        // 我们必须包含 CLOSE 命令。
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_decrease_burnEmpty");
    }

    // TODO: 支持 ERC6909。
    function test_gas_increaseLiquidity_erc6909() public {}
    function test_gas_decreaseLiquidity_erc6909() public {}

    // 原生代币 gas 测试
    function test_gas_mint_native() public {
        uint256 liquidityToAdd = 10_000 ether;
        bytes memory calls = getMintEncoded(configNative, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(configNative.tickLower),
            TickMath.getSqrtPriceAtTick(configNative.tickUpper),
            uint128(liquidityToAdd)
        );
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_native");
    }

    function test_gas_mint_native_excess_withClose() public {
        uint256 liquidityToAdd = 10_000 ether;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                configNative.poolKey,
                configNative.tickLower,
                configNative.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency1));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER));
        bytes memory calls = planner.encode();

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(configNative.tickLower),
            TickMath.getSqrtPriceAtTick(configNative.tickUpper),
            uint128(liquidityToAdd)
        );
        // 对原生代币多付
        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_nativeWithSweep_withClose");
    }

    function test_gas_mint_native_excess_withSettlePair() public {
        uint256 liquidityToAdd = 10_000 ether;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                configNative.poolKey,
                configNative.tickLower,
                configNative.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        planner.add(Actions.SETTLE_PAIR, abi.encode(nativeKey.currency0, nativeKey.currency1));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this)));
        bytes memory calls = planner.encode();

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(configNative.tickLower),
            TickMath.getSqrtPriceAtTick(configNative.tickUpper),
            uint128(liquidityToAdd)
        );
        // 对原生代币多付
        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_nativeWithSweep_withSettlePair");
    }

    function test_gas_increase_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, configNative, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidityToAdd = 10_000 ether;
        bytes memory calls = getIncreaseEncoded(tokenId, configNative, liquidityToAdd, ZERO_BYTES);
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(configNative.tickLower),
            TickMath.getSqrtPriceAtTick(configNative.tickUpper),
            uint128(liquidityToAdd)
        );
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_increaseLiquidity_native");
    }

    function test_gas_decrease_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, configNative, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidityToRemove = 10_000 ether;
        bytes memory calls = getDecreaseEncoded(tokenId, configNative, liquidityToRemove, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_decreaseLiquidity_native");
    }

    function test_gas_collect_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, configNative, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // 捐赠以产生手续费收入
        donateRouter.donate{value: 0.2e18}(configNative.poolKey, 0.2e18, 0.2e18, ZERO_BYTES);

        bytes memory calls = getCollectEncoded(tokenId, configNative, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_collect_native");
    }

    function test_gas_burn_nonEmptyPosition_native_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, configNative, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES));
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(configNative.poolKey);

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_burn_nonEmpty_native_withClose");
    }

    function test_gas_burn_nonEmptyPosition_native_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, configNative, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES));
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(configNative.poolKey, address(this));

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_burn_nonEmpty_native_withTakePair");
    }

    function test_gas_burnEmpty_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, configNative, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        decreaseLiquidity(tokenId, configNative, 10_000 ether, ZERO_BYTES);
        Plan memory planner = Planner.init()
            .add(Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES));

        // 无需包含 CLOSE 命令。
        bytes memory calls = planner.encode();
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_burn_empty_native");
    }

    function test_gas_decrease_burnEmpty_batch_native() public {
        // 这会比不编码 decrease、只编码 burn 更昂贵。
        // 即：将其与 PositionManager_burn_nonEmpty 进行对比
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, configNative, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        planner.add(Actions.BURN_POSITION, abi.encode(tokenId, 0 wei, 0 wei, ZERO_BYTES));

        // 我们必须包含 CLOSE 命令。
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(configNative.poolKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_decrease_burnEmpty_native");
    }

    function test_gas_permit() public {
        // alice 首次进行许可（permit）
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice 授予 bob 操作者权限
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.snapshotGasLastCall("PositionManager_permit");
    }

    function test_gas_permit_secondPosition() public {
        // alice 为她的两个代币进行许可，对第二次 permit 做基准测试
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice 授予 bob 操作者权限
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);

        // alice 创建另一个头寸
        vm.startPrank(alice);
        tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice 授予 bob 操作者权限
        nonce = 2;
        digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (v, r, s) = vm.sign(alicePK, digest);
        signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.snapshotGasLastCall("PositionManager_permit_secondPosition");
    }

    function test_gas_permit_twice() public {
        // alice 对同一个代币进行两次许可
        address charlie = makeAddr("CHARLIE");

        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice 授予 bob 操作者权限
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);

        // alice 授予 charlie 操作者权限
        nonce = 2;
        digest = getDigest(charlie, tokenIdAlice, nonce, block.timestamp + 1);
        (v, r, s) = vm.sign(alicePK, digest);
        signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(charlie, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.snapshotGasLastCall("PositionManager_permit_twice");
    }

    function test_gas_mint_settleWithBalance_sweep() public {
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

        currency0.transfer(address(lpm), 100e18);
        currency1.transfer(address(lpm), 100e18);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_mint_settleWithBalance_sweep");
    }

    // 不编码 take pair
    function test_gas_decrease_take_take() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory plan = Planner.init();
        plan.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, 1e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = plan.finalizeModifyLiquidityWithTake(config.poolKey, ActionConstants.MSG_SENDER);

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("PositionManager_decrease_take_take");
    }

    function test_gas_subscribe_unsubscribe() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        vm.snapshotGasLastCall("PositionManager_subscribe");

        lpm.unsubscribe(tokenId);
        vm.snapshotGasLastCall("PositionManager_unsubscribe");
    }
}
