// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IMulticall_v4} from "../../src/interfaces/IMulticall_v4.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {BipsLibrary} from "../../src/libraries/BipsLibrary.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {MockFOT} from "../mocks/MockFeeOnTransfer.sol";

contract PositionManagerModifyLiquiditiesTest is Test, PosmTestSetup, LiquidityFuzzers {
    using StateLibrary for IPoolManager;
    using BipsLibrary for uint256;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;

    PoolKey fotKey;

    PositionConfig config;
    PositionConfig wethConfig;
    PositionConfig nativeConfig;
    PositionConfig fotConfig;

    MockERC20 fotToken;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob,) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // 要求在基础 Deployers 合约中已设置 currency0 和 currency1。
        deployAndApprovePosm(manager);

        seedBalance(alice);
        approvePosmFor(alice);

        // 必须在 posm 之后部署
        // 部署一个可以访问 IPositionManager.modifyLiquiditiesWithoutUnlock 的 hook
        deployPosmHookModifyLiquidities();
        seedBalance(address(hookModifyLiquidities));

        (key, poolId) = initPool(currency0, currency1, IHooks(hookModifyLiquidities), 3000, SQRT_PRICE_1_1);
        wethKey = initPoolUnsorted(Currency.wrap(address(_WETH9)), currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        seedWeth(address(this));
        approvePosmCurrency(Currency.wrap(address(_WETH9)));

        nativeKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
        wethConfig = PositionConfig({
            poolKey: wethKey,
            tickLower: TickMath.minUsableTick(wethKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(wethKey.tickSpacing)
        });
        nativeConfig = PositionConfig({poolKey: nativeKey, tickLower: -120, tickUpper: 120});

        vm.deal(address(this), 1000 ether);

        fotToken = new MockFOT(lpm);
        approvePosmCurrency(Currency.wrap(address(fotToken)));
        seedToken(fotToken, address(this));
        fotKey = initPoolUnsorted(Currency.wrap(address(fotToken)), currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
    }

    /// @dev 未经授权铸造流动性是允许的
    function test_hook_mint() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook 在 beforeSwap 中通过 hookData 铸造一个新头寸
        uint256 hookTokenId = lpm.nextTokenId();
        uint256 newLiquidity = 10e18;
        bytes memory calls = getMintEncoded(config, newLiquidity, address(hookModifyLiquidities), ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // 原有流动性不变
        assertEq(liquidity, initialLiquidity);

        // hook 铸造了它自己的头寸
        liquidity = lpm.getPositionLiquidity(hookTokenId);
        assertEq(liquidity, newLiquidity);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this)); // 原头寸归本合约所有
        assertEq(IERC721(address(lpm)).ownerOf(hookTokenId), address(hookModifyLiquidities)); // hook 的头寸归 hook 所有
    }

    /// @dev hook 必须获得授权才能增加流动性
    function test_hook_increaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // 授权 hook 增加流动性
        IERC721(address(lpm)).approve(address(hookModifyLiquidities), tokenId);

        // hook 在 beforeSwap 中通过 hookData 增加流动性
        uint256 newLiquidity = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + newLiquidity);
    }

    /// @dev hook 获得授权后可以减少流动性
    function test_hook_decreaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // 授权 hook 减少流动性
        IERC721(address(lpm)).approve(address(hookModifyLiquidities), tokenId);

        // hook 在 beforeSwap 中通过 hookData 减少流动性
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToDecrease, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity - liquidityToDecrease);
    }

    /// @dev hook 获得授权后可以收取流动性（手续费）
    function test_hook_collect() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // 授权 hook 收取流动性（手续费）
        IERC721(address(lpm)).approve(address(hookModifyLiquidities), tokenId);

        // 捐赠（donate）以产生收益
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(config.poolKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook 在 beforeSwap 中通过 hookData 收取流动性（手续费）
        bytes memory calls = getCollectEncoded(tokenId, config, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // 流动性不变
        assertEq(liquidity, initialLiquidity);

        // hook 收取了手续费收益
        assertEq(currency0.balanceOf(address(hookModifyLiquidities)), balance0HookBefore + feeRevenue0 - 1 wei); // 精度误差，core 会保留 1 wei
        assertEq(currency1.balanceOf(address(hookModifyLiquidities)), balance1HookBefore + feeRevenue1 - 1 wei);
    }

    /// @dev hook 获得授权后可以销毁流动性
    function test_hook_burn() public {
        // 铸造一些不会在 beforeSwap 中被销毁的流动性
        mint(config, 100e18, address(this), ZERO_BYTES);

        // 将被 hook 销毁的头寸
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);
        // TODO: 改得不那么别扭，因为 HookModifyLiquidites 也具备保存 delta 的能力
        // BalanceDelta mintDelta = getLastDelta();
        BalanceDelta mintDelta = hookModifyLiquidities.deltas(hookModifyLiquidities.numberDeltasReturned() - 1);

        // 授权 hook 销毁流动性
        IERC721(address(lpm)).approve(address(hookModifyLiquidities), tokenId);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook 在 beforeSwap 中通过 hookData 销毁流动性
        bytes memory calls = getBurnEncoded(tokenId, config, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // 流动性已销毁
        assertEq(liquidity, 0);
        // 若该 token 不存在，721 会回滚（revert）
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);

        // hook 领取了被销毁的流动性
        assertEq(
            currency0.balanceOf(address(hookModifyLiquidities)),
            balance0HookBefore + uint128(-mintDelta.amount0() - 1 wei) // 精度误差，因为 core 会保留 1 wei
        );
        assertEq(
            currency1.balanceOf(address(hookModifyLiquidities)),
            balance1HookBefore + uint128(-mintDelta.amount1() - 1 wei)
        );
    }

    // --- 回滚（revert）场景 --- //
    /// @dev hook 未获授权，因此增加流动性应回滚（revert）
    function test_hook_increaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook 在 beforeSwap 中通过 hookData 减少流动性
        uint256 liquidityToAdd = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, ZERO_BYTES);

        // 应回滚（revert），因为 hook 未获授权
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook 未获授权，因此减少流动性应回滚（revert）
    function test_hook_decreaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook 在 beforeSwap 中通过 hookData 减少流动性
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToDecrease, ZERO_BYTES);

        // 应回滚（revert），因为 hook 未获授权
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook 未获授权，因此收取流动性（手续费）应回滚（revert）
    function test_hook_collect_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // 捐赠（donate）以产生收益
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(config.poolKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // hook 在 beforeSwap 中通过 hookData 收取流动性（手续费）
        bytes memory calls = getCollectEncoded(tokenId, config, ZERO_BYTES);

        // 应回滚（revert），因为 hook 未获授权
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook 未获授权，因此销毁流动性应回滚（revert）
    function test_hook_burn_revert() public {
        // 将被 hook 销毁的头寸
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook 在 beforeSwap 中通过 hookData 销毁流动性
        bytes memory calls = getBurnEncoded(tokenId, config, ZERO_BYTES);

        // 应回滚（revert），因为 hook 未获授权
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook 不能在 beforeRemoveLiquidity 中重入 modifyLiquiditiesWithoutUnlock
    function test_hook_increaseLiquidity_reenter_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        uint256 newLiquidity = 10e18;

        // 作为 hookData 传入，使 beforeAddLiquidity 尝试增加流动性
        bytes memory hookCall = getIncreaseEncoded(tokenId, config, newLiquidity, ZERO_BYTES);
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, hookCall);

        // 应回滚（revert），因为 hook 正在重入 modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_wrap_mint_usingContractBalance() public {
        // weth-currency1 池已初始化为 wethKey
        // 输入：eth、currency1
        // 调用 modifyLiquidities 用 weth 和 currency1 铸造流动性
        // 1 _wrap 使用合约余额
        // 2 _mint
        // 3 _settle weth，付款方为合约
        // 4 _close currency1，付款方为调用者
        // 5 _sweep weth，因为 eth 已全部被包装

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.WRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        // weth9 的付款方为合约
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // 另一种代币可以正常 close
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // 我们包装了合约的全部余额，因此以包装后的代币形式 sweep 回来
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        // 高估 eth 数量。
        lpm.modifyLiquidities{value: 102 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // 全部 eth 数量都被“花掉”了，因为其中一部分被包装成 weth 后退还。
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 102 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_openDelta() public {
        // weth-currency1 池已初始化为 wethKey
        // 输入：eth、currency1
        // 调用 modifyLiquidities 用 weth 和 currency1 铸造流动性
        // 1 _mint
        // 2 _wrap 使用未结 delta（open delta）
        // 3 _settle weth，付款方为合约
        // 4 _close currency1，付款方为调用者
        // 5 _sweep eth，因为只包装了未结 delta 对应的数量

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();

        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        planner.add(Actions.WRAP, abi.encode(ActionConstants.OPEN_DELTA));

        // weth9 的付款方为合约
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // 另一种代币可以正常 close
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // 我们只包装了未结 delta 对应的余额，因此以原生代币形式 sweep 回来
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        lpm.modifyLiquidities{value: 102 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // 约花费 100 eth，因为多出的 2 个被退还了。
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 100 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_usingExactAmount() public {
        // weth-currency1 池已初始化为 wethKey
        // 输入：eth、currency1
        // 调用 modifyLiquidities 用 weth 和 currency1 铸造流动性
        // 1 _wrap 指定数量
        // 2 _mint
        // 3 _settle weth，付款方为合约
        // 4 _close currency1，付款方为调用者
        // 5 _sweep weth，因为 eth 已全部被包装

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.WRAP, abi.encode(100 ether));
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        // weth9 的付款方为合约
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // 另一种代币可以正常 close
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // 我们包装了全部 100 eth，因此出于安全考虑以包装后的代币形式 sweep 回来
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        lpm.modifyLiquidities{value: 100 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // 全部 eth 数量都被“花掉”了，因为其中一部分被包装成 weth 后退还。
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 100 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_revertsInsufficientBalance() public {
        // 1 _wrap 的 eth 多于转入的数量

        Plan memory planner = Planner.init();
        // 包装比转入数量更多的 eth。
        planner.add(Actions.WRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        lpm.modifyLiquidities{value: 100 ether}(actions, _deadline);
    }

    function test_unwrap_usingContractBalance() public {
        // weth-currency1 池
        // 输出：eth、currency1
        // 调用 modifyLiquidities 用 weth 和 currency1 铸造流动性
        // 1 _burn
        // 2 _take，将 weth 发送到 lpm 合约
        // 3 _take，将 currency1 发送给 msg sender
        // 4 _unwrap 使用合约余额
        // 5 _sweep，将 eth 发送给 msg sender
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        bytes memory actions = getMintEncoded(wethConfig, liquidityAmount, address(this), ZERO_BYTES);
        lpm.modifyLiquidities(actions, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        // 将 weth 提取到 PositionManager 以便解包
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER));

        actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        assertApproxEqAbs(balanceEthAfter - balanceEthBefore, 100 ether, 1 wei);
        assertApproxEqAbs(balance1After - balance1Before, 100 ether, 1 wei);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_unwrap_openDelta_reinvest() public {
        // weth-currency1 池将一半转投到 eth-currency1 池
        // 输出：eth、currency1
        // 调用 modifyLiquidities 用 weth 和 currency1 铸造流动性
        // 1 _burn (weth-currency1)
        // 2 _take，将 weth 发送到 lpm 合约
        // 4 _mint 到 eth 池
        // 4 _unwrap 使用未结 delta（PoolManager 的 ETH 余额）
        // 3 _take，将剩余的 currency1 发送给 msg sender
        // 5 _settle eth 的未结 delta
        // 5 _sweep 剩余的 weth

        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(wethConfig.tickLower),
            TickMath.getSqrtPriceAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        bytes memory actions = getMintEncoded(wethConfig, liquidityAmount, address(this), ZERO_BYTES);
        lpm.modifyLiquidities(actions, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 balanceWethBefore = _WETH9.balanceOf(address(this));

        uint128 newLiquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(nativeConfig.tickLower),
            TickMath.getSqrtPriceAtTick(nativeConfig.tickUpper),
            50 ether,
            50 ether
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        // 将 weth 提取到 PositionManager 以便解包
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                nativeConfig.poolKey,
                nativeConfig.tickLower,
                nativeConfig.tickUpper,
                newLiquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.OPEN_DELTA));
        // 支付 eth
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.OPEN_DELTA, false));
        // 提取剩余的 currency1
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));

        actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 balanceWethAfter = _WETH9.balanceOf(address(this));

        // Eth 余额不应变化。
        assertEq(balanceEthAfter, balanceEthBefore);
        // 只有一半的原始流动性被再投资。
        assertApproxEqAbs(balance1After - balance1Before, 50 ether, 1 wei);
        assertApproxEqAbs(balanceWethAfter - balanceWethBefore, 50 ether, 1 wei);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_unwrap_revertsInsufficientBalance() public {
        // 1 _unwrap 的数量多于合约中的余额

        Plan memory planner = Planner.init();
        // 解包比合约中余额更多的 eth
        planner.add(Actions.UNWRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        lpm.modifyLiquidities(actions, _deadline);
    }

    function test_mintFromDeltas_fot() public {
        // 使用 1% 的手续费。
        MockFOT(address(fotToken)).setFee(100);
        uint256 tokenId = lpm.nextTokenId();

        uint256 fotBalanceBefore = Currency.wrap(address(fotToken)).balanceOf(address(this));

        uint256 amountAfterTransfer = 990e18;
        uint256 amountToSendFot = 1000e18;

        (uint256 amount0, uint256 amount1) = fotKey.currency0 == Currency.wrap(address(fotToken))
            ? (amountToSendFot, amountAfterTransfer)
            : (amountAfterTransfer, amountToSendFot);

        // 根据转账后的数量计算预期流动性。两种代币的数量相同。
        uint256 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(LIQUIDITY_PARAMS.tickLower),
            TickMath.getSqrtPriceAtTick(LIQUIDITY_PARAMS.tickUpper),
            amountAfterTransfer,
            amountAfterTransfer
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));
        planner.add(
            Actions.MINT_POSITION_FROM_DELTAS,
            abi.encode(
                fotKey,
                LIQUIDITY_PARAMS.tickLower,
                LIQUIDITY_PARAMS.tickUpper,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        bytes memory plan = planner.encode();

        lpm.modifyLiquidities(plan, _deadline);

        uint256 fotBalanceAfter = Currency.wrap(address(fotToken)).balanceOf(address(this));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), expectedLiquidity);
        assertEq(fotBalanceBefore - fotBalanceAfter, 1000e18);
    }

    function test_increaseFromDeltas() public {
        uint128 initialLiquidity = 1000e18;
        uint256 tokenId = lpm.nextTokenId();
        fotConfig = PositionConfig({poolKey: fotKey, tickLower: -120, tickUpper: 120});

        mint(fotConfig, initialLiquidity, address(this), ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity);

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, 10e18, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, 10e18, true));
        planner.add(
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(fotConfig.tickLower),
            TickMath.getSqrtPriceAtTick(fotConfig.tickUpper),
            10e18,
            10e18
        );

        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity + newLiquidity);
    }

    function test_increaseFromDeltas_fot() public {
        uint128 initialLiquidity = 1000e18;
        uint256 tokenId = lpm.nextTokenId();
        fotConfig = PositionConfig({poolKey: fotKey, tickLower: -120, tickUpper: 120});

        mint(fotConfig, initialLiquidity, address(this), ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity);

        // 使用 1% 的手续费。
        MockFOT(address(fotToken)).setFee(100);

        // 将转账扣费（fee on transfer）代币的数量设高 1%。
        (uint256 amount0, uint256 amount1) =
            fotKey.currency0 == Currency.wrap(address(fotToken)) ? (100e18, 99e18) : (99e18, 100e18);

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));
        planner.add(
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        (uint256 amount0AfterTransfer, uint256 amount1AfterTransfer) =
            fotKey.currency0 == Currency.wrap(address(fotToken)) ? (99e18, 100e18) : (100e18, 99e18);

        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(fotConfig.tickLower),
            TickMath.getSqrtPriceAtTick(fotConfig.tickUpper),
            amount0AfterTransfer,
            amount1AfterTransfer
        );

        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity + newLiquidity);
    }

    struct BalanceDiff {
        uint256 _before;
        uint256 _after;
    }

    struct Balance {
        uint256 _0;
        uint256 _1;
    }

    function test_fuzz_mintFromDeltas_burn_fot(
        uint256 bips,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) public {
        bips = bound(bips, 1, 10_000);
        MockFOT(address(fotToken)).setFee(bips);
        tickLower = int24(
            bound(
                tickLower,
                fotKey.tickSpacing * (TickMath.MIN_TICK / fotKey.tickSpacing),
                fotKey.tickSpacing * (TickMath.MAX_TICK / fotKey.tickSpacing)
            )
        );
        tickUpper = int24(
            bound(
                tickUpper,
                fotKey.tickSpacing * (TickMath.MIN_TICK / fotKey.tickSpacing),
                fotKey.tickSpacing * (TickMath.MAX_TICK / fotKey.tickSpacing)
            )
        );

        tickLower = fotKey.tickSpacing * (tickLower / fotKey.tickSpacing);
        tickUpper = fotKey.tickSpacing * (tickUpper / fotKey.tickSpacing);
        vm.assume(tickUpper > tickLower);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(fotKey.toId());
        {
            uint128 maxLiquidityPerTick = Pool.tickSpacingToMaxLiquidityPerTick(fotKey.tickSpacing);
            (uint256 maxAmount0, uint256 maxAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                maxLiquidityPerTick
            );

            maxAmount0 = maxAmount0 == 0 ? 1 : maxAmount0 > STARTING_USER_BALANCE ? STARTING_USER_BALANCE : maxAmount0;
            maxAmount1 = maxAmount1 == 0 ? 1 : maxAmount1 > STARTING_USER_BALANCE ? STARTING_USER_BALANCE : maxAmount1;
            amount0 = bound(amount0, 1, maxAmount0);
            amount1 = bound(amount1, 1, maxAmount1);
        }

        uint256 tokenId = lpm.nextTokenId();

        BalanceDiff memory balance0 = BalanceDiff(fotKey.currency0.balanceOf(address(this)), 0);
        BalanceDiff memory balance1 = BalanceDiff(fotKey.currency1.balanceOf(address(this)), 0);
        BalanceDiff memory balance0PM = BalanceDiff(fotKey.currency0.balanceOf(address(manager)), 0);
        BalanceDiff memory balance1PM = BalanceDiff(fotKey.currency1.balanceOf(address(manager)), 0);

        Plan memory planner = Planner.init();

        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));
        planner.add(
            Actions.MINT_POSITION_FROM_DELTAS,
            abi.encode(
                fotKey,
                tickLower,
                tickUpper,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        // 提取每种代币的多余部分
        planner.add(Actions.TAKE_PAIR, abi.encode(fotKey.currency0, fotKey.currency1, ActionConstants.MSG_SENDER));

        // 由于 stack too deep 需要去掉变量
        // 下面的代码可理解为：
        // bool currency0IsFOT = fotKey.currency0 == Currency.wrap(address(fotToken));
        // bool positionIsEntirelyInOtherToken = currency0IsFOT
        //     ? TickMath.getSqrtPriceAtTick(tickUpper) <= sqrtPriceX96
        //     : TickMath.getSqrtPriceAtTick(tickLower) >= sqrtPriceX96;
        // if (bips == 10000 && !positionIsEntirelyInOtherToken) {
        if (
            bips == 10000
                && !(fotKey.currency0 == Currency.wrap(address(fotToken))
                        ? TickMath.getSqrtPriceAtTick(tickUpper) <= sqrtPriceX96
                        : TickMath.getSqrtPriceAtTick(tickLower) >= sqrtPriceX96)
        ) {
            vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
            lpm.modifyLiquidities(planner.encode(), _deadline);
        } else {
            // 根据 delta 铸造（MINT FROM DELTAS）。
            lpm.modifyLiquidities(planner.encode(), _deadline);

            balance0._after = fotKey.currency0.balanceOf(address(this));
            balance1._after = fotKey.currency1.balanceOf(address(this));
            balance0PM._after = fotKey.currency0.balanceOf(address(manager));
            balance1PM._after = fotKey.currency1.balanceOf(address(manager));

            // 计算扣除手续费后用于创建流动性的预期余额。
            Balance memory expected;
            {
                bool currency0IsFOT = fotKey.currency0 == Currency.wrap(address(fotToken));
                uint256 expectedFee = (currency0IsFOT ? amount0 : amount1).calculatePortion(bips);
                (expected._0, expected._1) = currency0IsFOT
                    ? (balance0._before - balance0._after - expectedFee, balance1._before - balance1._after)
                    : (balance0._before - balance0._after, balance1._before - balance1._after - expectedFee);
            }
            assertEq(expected._0, balance0PM._after - balance0PM._before);
            assertEq(expected._1, balance1PM._after - balance1PM._before);
            {
                // 创建的流动性由余额变化的差值决定
                uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(tickLower),
                    TickMath.getSqrtPriceAtTick(tickUpper),
                    expected._0,
                    expected._1
                );

                assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
                assertEq(lpm.getPositionLiquidity(tokenId), expectedLiquidity);
            }
            // 销毁（BURN）。
            planner = Planner.init();
            // 注意：滑点不包含转账产生的手续费。
            planner.add(
                Actions.BURN_POSITION,
                abi.encode(
                    tokenId, expected._0 == 0 ? 0 : expected._0 - 1, expected._1 == 0 ? 0 : expected._1 - 1, ZERO_BYTES
                )
            );

            planner.add(Actions.TAKE_PAIR, abi.encode(fotKey.currency0, fotKey.currency1, ActionConstants.MSG_SENDER));

            lpm.modifyLiquidities(planner.encode(), _deadline);

            assertEq(lpm.getPositionLiquidity(tokenId), 0);
        }
    }
}
