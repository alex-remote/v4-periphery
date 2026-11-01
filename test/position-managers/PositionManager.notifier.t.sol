// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {MockSubscriber} from "../mocks/MockSubscriber.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {INotifier} from "../../src/interfaces/INotifier.sol";
import {MockReturnDataSubscriber, MockRevertSubscriber} from "../mocks/MockBadSubscribers.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";
import {MockReenterHook} from "../mocks/MockReenterHook.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

contract PositionManagerNotifierTest is Test, PosmTestSetup {
    using StateLibrary for IPoolManager;

    MockSubscriber sub;
    MockReturnDataSubscriber badSubscriber;
    PositionConfig config;
    MockRevertSubscriber revertSubscriber;
    MockReenterHook reenterHook;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    PositionConfig reenterConfig;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key,) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);

        // 要求在基础合约 Deployers 中已设置 currency0 和 currency1。
        deployAndApprovePosm(manager);

        sub = new MockSubscriber(lpm);
        badSubscriber = new MockReturnDataSubscriber(lpm);
        revertSubscriber = new MockRevertSubscriber(lpm);
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});

        // 设置重入 hook
        MockReenterHook impl = new MockReenterHook();
        address hookAddr = payable(address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG)));
        vm.etch(hookAddr, address(impl).code);
        reenterHook = MockReenterHook(hookAddr);
        reenterHook.setPosm(lpm);

        PoolKey memory reenterKey = PoolKey(currency0, currency1, 3000, 60, IHooks(reenterHook));
        manager.initialize(reenterKey, SQRT_PRICE_1_1);
        reenterConfig = PositionConfig({poolKey: reenterKey, tickLower: -60, tickUpper: 60});

        // TODO: 测试原生代币（NATIVE）的 poolKey
    }

    function test_subscribe_revertsWithEmptyPositionConfig() public {
        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert("NOT_MINTED");
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
    }

    function test_subscribe_revertsWhenNotApproved() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 本合约未获授权操作 alice 的流动性

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(this)));
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
    }

    function test_subscribe_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);
    }

    /// @notice 订阅到没有代码的地址时回滚（revert）
    function test_subscribe_revert_empty(address _subscriber) public {
        vm.assume(_subscriber.code.length == 0);

        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        vm.expectRevert(INotifier.NoCodeSubscriber.selector);
        lpm.subscribe(tokenId, _subscriber, ZERO_BYTES);
    }

    function test_subscribe_revertsWithAlreadySubscribed() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        // 成功订阅
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);

        vm.expectRevert(abi.encodeWithSelector(INotifier.AlreadySubscribed.selector, tokenId, sub));
        lpm.subscribe(tokenId, address(2), ZERO_BYTES);
    }

    function test_notifyModifyLiquidity_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(
                Actions.INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );
        }

        bytes memory calls = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(sub.notifyModifyLiquidityCount(), 10);
    }

    function test_notifyModifyLiquidity_selfDestruct_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        // 通过把字节码 etch 为 0 来模拟 selfdestruct
        vm.etch(address(sub), ZERO_BYTES);

        uint256 liquidityToAdd = 10e18;
        vm.expectRevert(INotifier.NoCodeSubscriber.selector);
        increaseLiquidity(tokenId, config, liquidityToAdd, ZERO_BYTES);
    }

    function test_notifyModifyLiquidity_args() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 捐赠（donate）以产生手续费收入，供订阅者中检查
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(config.poolKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        uint256 liquidityToAdd = 10e18;
        increaseLiquidity(tokenId, config, liquidityToAdd, ZERO_BYTES);

        assertEq(sub.notifyModifyLiquidityCount(), 1);
        assertEq(sub.liquidityChange(), int256(liquidityToAdd));
        assertEq(int256(sub.feesAccrued().amount0()), int256(feeRevenue0) - 1 wei);
        assertEq(int256(sub.feesAccrued().amount1()), int256(feeRevenue1) - 1 wei);
    }

    function test_transferFrom_unsubscribes() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        IERC721(address(lpm)).transferFrom(alice, bob, tokenId);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_transferFrom_unsubscribes_selfDestruct() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        // 通过把字节码 etch 为 0 来模拟 selfdestruct
        vm.etch(address(sub), ZERO_BYTES);

        // 取消订阅照常发生
        IERC721(address(lpm)).transferFrom(alice, bob, tokenId);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_safeTransferFrom_unsubscribes() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        IERC721(address(lpm)).safeTransferFrom(alice, bob, tokenId);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_safeTransferFrom_unsubscribes_selfDestruct() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        // 通过把字节码 etch 为 0 来模拟 selfdestruct
        vm.etch(address(sub), ZERO_BYTES);

        // 取消订阅照常发生
        IERC721(address(lpm)).safeTransferFrom(alice, bob, tokenId);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_safeTransferFrom_unsubscribes_withData() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        IERC721(address(lpm)).safeTransferFrom(alice, bob, tokenId, "");

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_unsubscribe_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_unsubscribe_isSuccessfulWithBadSubscriber() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(badSubscriber), ZERO_BYTES);

        MockReturnDataSubscriber(badSubscriber).setReturnDataSize(0x600000);
        lpm.unsubscribe(tokenId);

        // 订阅者合约调用失败，因为它消耗了过多 gas
        assertEq(MockReturnDataSubscriber(badSubscriber).notifyUnsubscribeCount(), 0);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_unsubscribe_selfDestructed() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        // 通过把字节码 etch 为 0 来模拟 selfdestruct
        vm.etch(address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_multicall_mint_subscribe() public {
        uint256 tokenId = lpm.nextTokenId();

        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        bytes memory actions = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions, _deadline);
        calls[1] = abi.encodeWithSelector(lpm.subscribe.selector, tokenId, sub, ZERO_BYTES);

        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 100e18);
        assertEq(sub.notifySubscribeCount(), 1);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
    }

    function test_multicall_mint_subscribe_increase() public {
        uint256 tokenId = lpm.nextTokenId();

        // 编码铸造。
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        bytes memory actions = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);

        // 单独编码增加流动性。
        plan = Planner.init();
        plan.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        bytes memory actions2 = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);

        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions, _deadline);
        calls[1] = abi.encodeWithSelector(lpm.subscribe.selector, tokenId, sub, ZERO_BYTES);
        calls[2] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions2, _deadline);

        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 110e18);
        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(sub.notifyModifyLiquidityCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
    }

    function test_unsubscribe_revertsWhenNotSubscribed() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        vm.expectRevert(INotifier.NotSubscribed.selector);
        lpm.unsubscribe(tokenId);
    }

    function test_unsubscribe_twice_reverts() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId);

        vm.expectRevert(INotifier.NotSubscribed.selector);
        lpm.unsubscribe(tokenId);
    }

    function test_subscribe_withData() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        bytes memory subData = abi.encode(address(this));

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), subData);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(abi.decode(sub.subscribeData(), (address)), address(this));
    }

    function test_subscribe_wraps_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        revertSubscriber.setRevert(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(revertSubscriber),
                ISubscriber.notifySubscribe.selector,
                abi.encodeWithSelector(MockRevertSubscriber.TestRevert.selector, "notifySubscribe"),
                abi.encodeWithSelector(INotifier.SubscriptionReverted.selector)
            )
        );
        lpm.subscribe(tokenId, address(revertSubscriber), ZERO_BYTES);
    }

    function test_notifyModifyLiquidiy_wraps_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(revertSubscriber), ZERO_BYTES);

        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(
                Actions.INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );
        }

        bytes memory calls = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(revertSubscriber),
                ISubscriber.notifyModifyLiquidity.selector,
                abi.encodeWithSelector(MockRevertSubscriber.TestRevert.selector, "notifyModifyLiquidity"),
                abi.encodeWithSelector(INotifier.ModifyLiquidityNotificationReverted.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    /// @notice 销毁头寸会自动发出销毁通知
    function test_notifyBurn_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        bytes memory subData = abi.encode(address(this));

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), subData);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), true);
        assertEq(sub.notifyUnsubscribeCount(), 0);

        // 销毁头寸，触发 notifyBurn
        burn(tokenId, config, ZERO_BYTES);

        // 头寸现已取消订阅
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(sub.notifyUnsubscribeCount(), 0);
        assertEq(sub.notifyBurnCount(), 1);
    }

    /// @notice 测试用户无法通过 gas 限制强行规避取消订阅逻辑
    function test_fuzz_unsubscribe_with_gas_limit(uint64 gasLimit) public {
        // 强制设置最低 gas 数量，避免 OutOfGas 回滚
        gasLimit = uint64(bound(gasLimit, 125_000, block.gaslimit));

        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // 授权本合约操作 alice 的流动性
        vm.startPrank(alice);
        IERC721(address(lpm)).approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        uint256 beforeUnsubCount = sub.notifyUnsubscribeCount();

        if (gasLimit < lpm.unsubscribeGasLimit()) {
            // gas 过低，无法完成一次有效的取消订阅
            vm.expectRevert(INotifier.GasLimitTooLow.selector);
            lpm.unsubscribe{gas: gasLimit}(tokenId);
        } else {
            // 提高 gas 限制后成功，且取消订阅已被调用
            lpm.unsubscribe{gas: gasLimit}(tokenId);
            assertEq(sub.notifyUnsubscribeCount(), beforeUnsubCount + 1);
        }
    }

    function test_unsubscribe_reverts_PoolManagerMustBeLocked() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(reenterConfig, 10e18, address(this), ZERO_BYTES);

        bytes memory hookData = abi.encode(lpm.unsubscribe.selector, address(this), tokenId);
        bytes memory actions = getMintEncoded(reenterConfig, 10e18, address(this), hookData);

        // 授权给 hook，此操作不应回滚（revert），因为它没有相应权限
        IERC721(address(lpm)).approve(address(reenterHook), tokenId);
        // 订阅，此操作不应回滚（revert），因为当前没有订阅者
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        // 应当回滚（revert），因为 PoolManager 处于解锁状态
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(reenterHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IPositionManager.PoolManagerMustBeLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(actions, _deadline);
    }

    function test_subscribe_reverts_PoolManagerMustBeLocked() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(reenterConfig, 10e18, address(this), ZERO_BYTES);

        bytes memory hookData = abi.encode(lpm.subscribe.selector, address(this), tokenId);
        bytes memory actions = getMintEncoded(reenterConfig, 10e18, address(this), hookData);

        // 授权给 hook，此操作不应回滚（revert），因为它没有相应权限
        IERC721(address(lpm)).approve(address(reenterHook), tokenId);

        // 应当回滚（revert），因为 PoolManager 处于解锁状态
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(reenterHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IPositionManager.PoolManagerMustBeLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(actions, _deadline);
    }

    function test_transferFrom_reverts_PoolManagerMustBeLocked() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(reenterConfig, 10e18, address(this), ZERO_BYTES);

        bytes memory hookData = abi.encode(IERC721(address(lpm)).transferFrom.selector, address(this), tokenId);
        bytes memory actions = getMintEncoded(reenterConfig, 10e18, address(this), hookData);

        // 授权给 hook，此操作不应回滚（revert），因为它没有相应权限
        IERC721(address(lpm)).approve(address(reenterHook), tokenId);

        // 应当回滚（revert），因为 PoolManager 处于解锁状态
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(reenterHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IPositionManager.PoolManagerMustBeLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(actions, _deadline);
    }
}
