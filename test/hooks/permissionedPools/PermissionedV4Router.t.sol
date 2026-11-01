// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {VmSafe} from "forge-std/Vm.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PermitHash} from "permit2/src/libraries/PermitHash.sol";
import {IV4Router} from "../../../src/interfaces/IV4Router.sol";
import {PermissionedRoutingTestHelpers} from "./shared/PermissionedRoutingTestHelpers.sol";
import {Planner} from "../../shared/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {MockPermissionedToken, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {MockPermissionedHooks} from "./mocks/MockPermissionedHooks.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PathKey} from "../../../src/libraries/PathKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockUnapprovedWrapper} from "./mocks/MockUnapprovedWrapper.sol";

contract PermissionedV4RouterTest is PermissionedRoutingTestHelpers {
    using PermitHash for IAllowanceTransfer.PermitSingle;
    using StateLibrary for IPoolManager;

    // 便于在不导入 PermissionedV4Router 的情况下进行测试
    error HookNotImplemented();
    error Unauthorized();
    error HookCallFailed();
    error SliceOutOfBounds();
    error NoVerifiedAdapter();
    error UnverifiedAdapter();
    error InvalidCommandType(uint256 commandType);
    error ExecutionFailed(uint256 commandIndex, bytes output);

    Currency public permissionsAdapter0Currency;
    Currency public permissionsAdapter1Currency;

    // 测试用户
    address public alice = makeAddr("ALICE");
    address public unauthorizedUser = makeAddr("UNAUTHORIZED");

    // 命令
    bytes public COMMAND_V4_SWAP = hex"10";
    bytes public COMMAND_PERMIT2_PERMIT = hex"0a";

    function setUp() public {
        setupPermissionedRouterCurrenciesAndPoolsWithLiquidity(alice);

        permissionsAdapter0Currency = Currency.wrap(address(permissionsAdapter0));
        permissionsAdapter1Currency = Currency.wrap(address(permissionsAdapter1));
        permissionsAdapter0.updateSwappingEnabled(true);
        permissionsAdapter1.updateSwappingEnabled(true);

        plan = Planner.init();

        setupPermissionsAndApprovals();
    }

    function setupPermissionsAndApprovals() internal {
        // 为测试地址设置授权
        _setupApprovals();

        // 为已授权用户设置授权
        vm.startPrank(alice);
        _setupApprovals();
        vm.stopPrank();
    }

    function _setupApprovals() internal {
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint160).max);
        IERC20(Currency.unwrap(currency0)).approve(address(permissionedRouter), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permissionedRouter), type(uint160).max);
        IERC20(Currency.unwrap(currency0)).approve(address(permissionedHooks), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permissionedHooks), type(uint160).max);
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), type(uint160).max);

        permit2.approve(Currency.unwrap(currency0), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency0), address(permissionedHooks), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(permissionedHooks), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, 2 ** 47);
    }

    function getInputAndOutputBalances(PoolKey memory poolKey, bool zeroForOne, address manager_)
        public
        view
        returns (uint256 inputBalance, uint256 outputBalance, uint256 ethBalance)
    {
        if (zeroForOne) {
            inputBalance = poolKey.currency0.balanceOf(manager_);
            outputBalance = poolKey.currency1.balanceOf(manager_);
        } else {
            inputBalance = poolKey.currency1.balanceOf(manager_);
            outputBalance = poolKey.currency0.balanceOf(manager_);
        }
        ethBalance = address(this).balance;
    }

    function getInputAndOutputBalancesPath(Currency[] memory path, address manager_)
        public
        view
        returns (uint256 inputBalance, uint256 outputBalance, uint256 ethBalance)
    {
        inputBalance = path[0].balanceOf(manager_);
        outputBalance = path[path.length - 1].balanceOf(manager_);
        ethBalance = address(this).balance;
    }

    function test_gas_swapExactInputSingle_permissionedTokens() public {
        uint256 amountIn = 1000;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_PermissionedTokens");
    }

    /// @notice 通过许可路由器路由的普通（非许可）兑换（swap）的 gas 成本。
    ///         这就是 UniversalRouter 用户需要支付的成本，因为 V4SwapRouter 继承自 PermissionedV4Router。
    function test_gas_swapExactInputSingle_ordinaryTokens() public {
        uint256 amountIn = 1000;
        // key2 为 currency2/currency3，未安装 hook —— 两侧都不是权限适配器
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key2, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key2.currency0, key2.currency1, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_OrdinaryTokens");
    }

    /// @notice 通过许可路由器在四种不同资产间进行普通 3 跳兑换（swap）的 gas 成本。
    ///         互不相同的中间代币正是多跳兑换开销大的原因：每一个都是路由器此前从未查询过的代币，
    ///         因此都会产生一次冷存储读取，而同一池内的路径则不会产生这一开销。
    function test_gas_swapExactIn3Hops_ordinaryTokens_distinctAssets() public {
        MockERC20[] memory extra = deployTokens(1, 2 ** 128, false);
        Currency currency5 = Currency.wrap(address(extra[0]));
        approveAllContracts(address(extra[0]));
        extra[0].approve(address(permissionedRouter), type(uint256).max);
        extra[0].approve(address(positionManager), type(uint256).max);

        // key2 已覆盖 currency2/currency3；再添加剩余的两段
        createPoolWithLiquidity(currency3, currency4, address(0));
        createPoolWithLiquidity(currency4, currency5, address(0));

        // currency2 -> currency3 -> currency4 -> currency5，无重复
        PathKey[] memory path = new PathKey[](3);
        path[0] = PathKey(currency3, 3000, 60, IHooks(address(0)), bytes(""));
        path[1] = PathKey(currency4, 3000, 60, IHooks(address(0)), bytes(""));
        path[2] = PathKey(currency5, 3000, 60, IHooks(address(0)), bytes(""));

        IV4Router.ExactInputParams memory params =
            IV4Router.ExactInputParams(currency2, path, new uint256[](0), uint128(1000), 0);

        // createPoolWithLiquidity 会在共享的 `plan` 上构建其铸造操作，因此在兑换前需重置
        plan = Planner.init();
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, currency5, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactIn3Hops_OrdinaryTokens_DistinctAssets");
    }

    /*//////////////////////////////////////////////////////////////
                        权限测试
    //////////////////////////////////////////////////////////////*/

    function test_swap_reverts_unauthorized_user() public {
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        IERC20(Currency.unwrap(currency0)).transfer(unauthorizedUser, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(unauthorizedUser, 2 ether);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        Currency currencyA = permissionsAdapter0Currency;
        Currency currencyB = permissionsAdapter1Currency;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) (currencyA, currencyB) = (currencyB, currencyA);

        uint256 amountIn = 1 ether;
        PoolKey memory adapterKey = PoolKey(currencyA, currencyB, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currencyA, currencyB, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    error HookNotAllowed();

    /// @notice 持有已验证适配器但未安装 hook 的池必须在兑换（swap）执行前被拒绝。
    ///         这里使用已授权的兑换者，因此拒绝可归因于 hook，而非 SWAP_ALLOWED。
    function test_swap_reverts_hooklessPoolWithVerifiedAdapter() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        currency4.transfer(alice, 2 ether);

        // 与 key3 的代币相同，但未安装 hook
        Currency currencyA = permissionsAdapter0Currency;
        Currency currencyB = currency4;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) (currencyA, currencyB) = (currencyB, currencyA);
        PoolKey memory hooklessKey = PoolKey(currencyA, currencyB, 3000, 60, IHooks(address(0)));
        manager.initialize(hooklessKey, SQRT_PRICE_1_1);

        // 普通代币输入、许可适配器输出 —— 这是路由器过去从未检查过的方向
        bool zeroForOne = currencyA == currency4;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(hooklessKey, zeroForOne, 1 ether, 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency4, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert(HookNotAllowed.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    /// @notice 不在适配器白名单上的非零 hook 同样必须被拒绝。如果只拒绝
    ///         `address(0)`，就会让空操作（no-op）hook 或未带 BEFORE_SWAP_FLAG 挖出的地址直接通过。
    function test_swap_reverts_unapprovedNonZeroHook() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(insecureKey, true, uint128(1 ether), 0, 0, bytes(""));

        // insecureHooks 已在 setUp 中加入白名单，因此这笔相同的兑换会成功
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(insecureKey.currency0, insecureKey.currency1, ActionConstants.MSG_SENDER);
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        // 在一侧撤销该 hook 后，同样的兑换现在会被拒绝
        setAllowedHooks(permissionsAdapter0Currency, insecureHooks, false);

        plan = Planner.init();
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        data = plan.finalizeSwap(insecureKey.currency0, insecureKey.currency1, ActionConstants.MSG_SENDER);
        vm.prank(alice);
        vm.expectRevert(HookNotAllowed.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    /// @notice 不在适配器 `allowedWrappers` 列表中的包装器（wrapper）无法获得适配器的 delta。
    ///         正是这一点封堵了 ERC-6909 路径：`PoolManager.mint` 会将 delta 转换为可自由
    ///         转让的凭证（claim），全程不经过 `PermissionsAdapter._update`，因此底层
    ///         代币的白名单检查根本不会执行，拒绝该 delta 是唯一的防线。使用未批准 hook 的
    ///         池另有单独的测试覆盖 —— 它们从一开始就无法持有适配器库存。
    function test_unapprovedWrapper_cannotObtainAdapterDelta() public {
        // 该包装器上报的调用者是持有 ALL_ALLOWED 的 alice，因此针对兑换者的白名单检查会通过，
        // 唯一剩下的障碍就是该包装器本身不在 `allowedWrappers` 中
        MockUnapprovedWrapper unapprovedWrapper = new MockUnapprovedWrapper(manager, alice);
        assertTrue(permissionsAdapter0.isAllowed(alice, PermissionFlags.SWAP_ALLOWED));
        assertFalse(permissionsAdapter0.allowedWrappers(address(unapprovedWrapper)));

        bool zeroForOne = key3.currency0 == currency4;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        unapprovedWrapper.swap(
            key3,
            SwapParams(zeroForOne, -1e15, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    error SwappingDisabled();

    function test_swap_revert_trading_disabled() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        permissionsAdapter0.updateSwappingEnabled(false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SwappingDisabled.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        permissionsAdapter0.updateSwappingEnabled(true);
        permissionsAdapter1.updateSwappingEnabled(false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SwappingDisabled.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    /// @notice 单独的 SETTLE+TAKE 会绕过 hook 的兑换暂停，必须由路由器端的检查拦截。
    function test_settle_revert_when_swapping_disabled_on_input_adapter() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        plan = plan.add(Actions.SETTLE, abi.encode(permissionsAdapter0Currency, uint256(100), true));
        plan = plan.add(Actions.TAKE, abi.encode(permissionsAdapter0Currency, alice, uint256(100)));
        bytes memory data = plan.encode();

        permissionsAdapter0.updateSwappingEnabled(false);

        vm.prank(alice);
        vm.expectRevert(SwappingDisabled.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    /// @dev 适配器仅位于输出侧，因此 `_pay` 走标准路径，路由器的
    ///         `_take` 是唯一的防护。`insecureHooks` 不执行任何权限检查，因此此处的回滚（revert）
    ///         只可能来自路由器。当输出适配器禁用兑换时应回滚。
    function test_take_revert_when_swapping_disabled_on_output_adapter() public {
        PoolKey memory mixedInsecureKey =
            createPoolWithLiquidity(permissionsAdapter0Currency, currency2, address(insecureHooks));
        // 上面铸造流动性时会在共享的 plan 上留下其自身的操作（action）
        plan = Planner.init();

        IERC20(Currency.unwrap(currency2)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        bool zeroForOne = mixedInsecureKey.currency0 == currency2;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(mixedInsecureKey, zeroForOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        permissionsAdapter0.updateSwappingEnabled(false);

        vm.prank(alice);
        vm.expectRevert(SwappingDisabled.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    /// @dev 适配器仅位于输出侧，因此 `_pay` 走标准路径，路由器的
    ///         `_take` 是唯一的防护。`insecureHooks` 不执行任何权限检查，因此此处的回滚（revert）
    ///         只可能来自路由器。当 msg.sender 没有兑换权限时应回滚。
    function test_take_revert_when_unauthorized_on_output_adapter() public {
        PoolKey memory mixedInsecureKey =
            createPoolWithLiquidity(permissionsAdapter0Currency, currency2, address(insecureHooks));
        // 上面铸造流动性时会在共享的 plan 上留下其自身的操作（action）
        plan = Planner.init();

        IERC20(Currency.unwrap(currency2)).transfer(alice, 2 ether);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        uint256 amountIn = 100;
        bool zeroForOne = mixedInsecureKey.currency0 == currency2;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(mixedInsecureKey, zeroForOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_succeeds_authorized_user() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_authorized_router() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        uint256 expectedAmountOut = 98;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(adapterKey, true, address(manager));
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(adapterKey, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swap_unauthorized_router_reverts() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        permissionsAdapter0.updateAllowedWrapper(address(permissionedRouter), false);
        permissionsAdapter1.updateAllowedWrapper(address(permissionedRouter), false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_succeeds_authorized_user_mixed_entry() public {
        uint256 amountIn = 100;
        uint256 expectedAmountOut = 98;
        bool zeroToOne = permissionsAdapter1Currency == key1.currency0;
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swap_succeeds_authorized_user_mixed_exit() public {
        IERC20(Currency.unwrap(currency2)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        uint256 expectedAmountOut = 98;
        bool zeroToOne = !(permissionsAdapter1Currency == key1.currency0);
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swap_succeeds_unauthorized_user_mixed_entry() public {
        bool zeroToOne = permissionsAdapter1Currency == key1.currency0;
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }

        // 给未授权用户发放许可代币
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        IERC20(Currency.unwrap(currency1)).transfer(unauthorizedUser, 2 ether);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        uint256 amountIn = 100;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_unauthorized_user_mixed_exit_reverts() public {
        IERC20(Currency.unwrap(currency2)).transfer(unauthorizedUser, 2 ether);

        uint256 amountIn = 100;
        bool zeroToOne = !(permissionsAdapter1Currency == key1.currency0);
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_none_swap_reverts() public {
        // 测试 NONE 权限会阻止兑换操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.NONE);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_router_user_payment_permissioned_token_unauthorized_reverts() public {
        // 测试 LIQUIDITY_ALLOWED 不允许兑换操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, insecureHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.startPrank(alice);
        vm.expectRevert(Unauthorized.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        vm.stopPrank();
    }

    function test_permission_flag_liquidity_allowed_swap_reverts() public {
        // 测试 LIQUIDITY_ALLOWED 不允许兑换操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_all_allowed_swap_succeeds() public {
        // 测试 ALL_ALLOWED 允许兑换操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_combinations_swap() public {
        // 测试兑换的各种权限组合
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        // 测试 SWAP_ALLOWED + LIQUIDITY_ALLOWED（效果应与 ALL_ALLOWED 相同）
        MockPermissionedToken(Currency.unwrap(currency0))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));
        MockPermissionedToken(Currency.unwrap(currency1))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_partial_permissions_swap() public {
        // 测试仅在一个代币上拥有权限不足以进行兑换
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.NONE);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_dynamic_changes_swap() public {
        // 测试权限变更对兑换立即生效
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        // 初始时应成功
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        // 移除权限
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.NONE);

        // 后续操作应失败
        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_edge_cases_swap() public {
        // 测试兑换时权限标志的边界情况
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        // 使用零权限测试（应与 NONE 相同）
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0x0000));
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlag.wrap(0x0000));

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        // 使用最大权限测试（应与 ALL_ALLOWED 相同）
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_all_pool_types_swap() public {
        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(permissionsAdapter0Currency)))
            .setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(permissionsAdapter1Currency)))
            .setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        _test_permission_flag_all_pool_types_swap(key0);
        _test_permission_flag_all_pool_types_swap(key1);
        _test_permission_flag_all_pool_types_swap(key2);
    }

    function _test_permission_flag_all_pool_types_swap(PoolKey memory poolKey) public {
        IERC20(Currency.unwrap(getPermissionedCurrency(poolKey.currency0))).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(getPermissionedCurrency(poolKey.currency1))).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        plan = Planner.init();
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(poolKey, true, uint128(amountIn), 0, 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(poolKey.currency1, 0));
        bytes memory data = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_exact_output_swap() public {
        // 测试精确输出兑换下的权限标志
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountOut = 50;
        uint256 amountInMaximum = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            adapterKey, true, uint128(amountOut), uint128(amountInMaximum), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_multi_hop_swap() public {
        // 测试多跳兑换下的权限标志
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        Currency[] memory path = new Currency[](2);
        path[0] = permissionsAdapter1Currency;
        path[1] = permissionsAdapter0Currency;

        // 为多跳兑换创建路径 key
        PathKey[] memory pathKeys = new PathKey[](1);
        pathKeys[0] = PathKey({
            intermediateCurrency: permissionsAdapter0Currency,
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks,
            hookData: bytes("")
        });

        IV4Router.ExactInputParams memory params =
            IV4Router.ExactInputParams(permissionsAdapter1Currency, pathKeys, new uint256[](0), uint128(amountIn), 0);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_router_user_payment_permissioned_token() public {
        // 测试 SWAP_ALLOWED 允许兑换操作
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 精确输入
    //////////////////////////////////////////////////////////////*/

    function test_swapExactInputSingle_revertsForAmountOut() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;
        // 最小输出数量比实际输出数量高 1
        IV4Router.ExactInputSingleParams memory params = IV4Router.ExactInputSingleParams(
            key0, true, uint128(amountIn), uint128(expectedAmountOut + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, expectedAmountOut + 1, expectedAmountOut)
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactInputSingle_zeroForOne_takeToMsgSender() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactInputSingle_zeroForOne_takeToRecipient() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        uint256 aliceOutputBalanceBefore = getPermissionedCurrency(key0.currency1).balanceOf(alice);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        // 以 alice 作为提取（take）接收者进行兑换
        _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn, alice);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        uint256 aliceOutputBalanceAfter = getPermissionedCurrency(key0.currency1).balanceOf(alice);

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
        assertEq(aliceOutputBalanceAfter - aliceOutputBalanceBefore, expectedAmountOut);
    }

    // 单独来看这并不是真实用例，但当 UniversalRouter 中的一笔 v4 兑换
    // 位于另一笔 v2/v3 兑换之前时会用到
    function test_swapExactInputSingle_zeroForOne_takeAllToRouter() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // 兑换前路由器不持有任何资金
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        // 以路由器作为提取（take）接收者进行兑换
        _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn, ActionConstants.ADDRESS_THIS);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    // 单独来看这并不是真实用例，但当 UniversalRouter 中的一笔 v4 兑换
    // 位于另一笔 v2/v3 兑换之前时会用到
    function test_swapExactInputSingle_zeroForOne_takeToRouter() public {
        uint256 amountIn = 1000;
        uint256 expectedAmountOut = 949;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        Currency inputCurrency = getPermissionedCurrency(key0.currency0);
        Currency outputCurrency = getPermissionedCurrency(key0.currency1);

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountOut * 12 / 10));
        // 将全部未结 delta 提取到路由器地址
        plan = plan.add(
            Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA)
        );
        bytes memory data = plan.encode();
        // 兑换前路由器不持有任何资金
        assertEq(inputCurrency.balanceOf(address(permissionedRouter)), 0);
        assertEq(outputCurrency.balanceOf(address(permissionedRouter)), 0);

        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        // 输出代币被留在了路由器中
        assertEq(outputCurrency.balanceOf(address(permissionedRouter)), expectedAmountOut);
        assertEq(inputCurrency.balanceOf(address(permissionedRouter)), 0);
    }

    function test_swapExactInputSingle_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;
        bool zeroForOne = false;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, zeroForOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(key0.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(key0.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactInput_revertsForAmountOut() public {
        uint256 amountIn = 1000;
        uint256 expectedAmountOut = 949;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);
        params.amountOutMinimum = uint128(expectedAmountOut + 1);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, expectedAmountOut + 1, expectedAmountOut)
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, permissionsAdapter1Currency, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, currency2, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // 检查中间代币余额
        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 6645;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);
        tokenPath.push(currency3);

        // 手动构建路径：前两跳使用 permissionedHooks，最后一跳使用 address(0)（key2 没有 hook）
        PathKey[] memory path = new PathKey[](3);
        path[0] = PathKey(permissionsAdapter1Currency, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[1] = PathKey(currency2, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[2] = PathKey(currency3, 3000, 60, IHooks(address(0)), bytes(""));
        IV4Router.ExactInputParams memory params = IV4Router.ExactInputParams({
            currencyIn: permissionsAdapter0Currency,
            path: path,
            minHopPriceX36: new uint256[](0),
            amountIn: uint128(amountIn),
            amountOutMinimum: uint128(expectedAmountOut)
        });

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, currency3, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // 检查中间代币没有留在路由器中
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency3.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 与 ERC20 -> ETH 精确输入
    //////////////////////////////////////////////////////////////*/

    function test_nativeIn_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, true, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency0, nativeKey.currency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, true, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;
        bool zeroForOne = false;

        // 输出原生代币意味着需要 !zeroForOne
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, zeroForOne, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
    }

    function test_nativeIn_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(nativeKey.currency1);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, nativeKey.currency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
    }

    function test_nativeIn_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        // 已初始化的 nativeKey 为 (native, currency0)
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();
        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, permissionsAdapter1Currency, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // 检查中间代币余额
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        // 已初始化的 nativeKey 为 (native, currency0)
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter1Currency, CurrencyLibrary.ADDRESS_ZERO, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // 检查中间代币余额
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
    }

    function test_swap_nativeIn_settleRouterBalance_swapOpenDelta() public {
        uint256 amountIn = 1000;
        uint256 expectedAmountOut = 949;
        bool zeroForOne = true;

        vm.deal(address(permissionedRouter), amountIn);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, zeroForOne, ActionConstants.OPEN_DELTA, 0, 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode(nativeKey.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(nativeKey.currency1, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        // 调用者未付款，由路由器付款，调用者收到了输出
        assertEq(ethBalanceBefore, ethBalanceAfter);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 精确输出
    //////////////////////////////////////////////////////////////*/

    function test_swapExactOutputSingle_revertsForAmountIn() public {
        // key0（许可适配器）在价格触及全局限制之前最多只能提供 19992 的输出；
        // 这里请求一个可成交的数量，使本测试检验的是 amountInMaximum 防护，而非
        // 全部成交否则回滚的未足额成交防护（V4ExactOutputUnfilled）
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 434604409;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, uint128(amountOut), uint128(expectedAmountIn - 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, expectedAmountIn)
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 434604409;
        bool zeroForOne = true;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(key0.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(key0.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOutputSingle_oneForZero() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;
        bool zeroForOne = false;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_revertsForAmountIn() public {
        // key0（许可适配器）在价格触及全局限制之前最多只能提供 19992 的输出；
        // 这里请求一个可成交的数量，使本测试检验的是 amountInMaximum 防护，而非
        // 全部成交否则回滚的未足额成交防护（V4ExactOutputUnfilled）
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);
        params.amountInMaximum = uint128(expectedAmountIn - 1);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, expectedAmountIn)
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 434604409;

        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, key0.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_2Hops() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 104;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);
        tokenPath.push(currency3);

        // 按 _getExactOutputParamsWithHook 的模式构建路径：
        // path[2] = currency2（跳：currency3→currency2，无 hook 的池）
        // path[1] = adapter1（跳：currency2→adapter1，许可池）
        // path[0] = adapter0（跳：adapter1→adapter0，许可池）
        PathKey[] memory path = new PathKey[](3);
        path[0] = PathKey(permissionsAdapter0Currency, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[1] = PathKey(permissionsAdapter1Currency, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[2] = PathKey(currency2, 3000, 60, IHooks(address(0)), bytes(""));
        IV4Router.ExactOutputParams memory params = IV4Router.ExactOutputParams({
            currencyOut: currency3,
            path: path,
            minHopPriceX36: new uint256[](0),
            amountOut: uint128(amountOut),
            amountInMaximum: uint128(expectedAmountIn)
        });

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, currency3, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency3.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops_permissioned_middle() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(currency4);
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency4, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(currency4.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops_mmiddle_unauthorized_reverts() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        currency4.transfer(unauthorizedUser, 1000);

        tokenPath.push(currency4);
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        bytes memory data = plan.finalizeSwap(currency4, currency2, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactOut_native_3Hops_permissioned_middle() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(nativeKey.currency0);
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency0, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_native_3Hops_mmiddle_unauthorized_reverts() public {
        nativeKey.currency0.transfer(unauthorizedUser, 1000);

        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(nativeKey.currency0);
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        bytes memory data = plan.finalizeSwap(nativeKey.currency0, currency2, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute{value: (nativeKey.currency0.isAddressZero()) ? expectedAmountIn : 0}(
            COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max
        );
    }

    function test_swapExactOutputSingle_swapOpenDelta() public {
        uint256 expectedAmountIn = 946;
        uint256 expectedOutput = 900;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, ActionConstants.OPEN_DELTA, uint128(expectedAmountIn), 0, bytes("")
        );

        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, expectedOutput));
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedOutput);
    }

    function test_swapExactOut_swapOpenDelta() public {
        uint256 expectedAmountIn = 1057;
        uint256 expectedOutput = 1000;

        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);

        IV4Router.ExactOutputParams memory params = _getExactOutputParamsWithHook(
            tokenPath, ActionConstants.OPEN_DELTA, address(permissionedHooks), expectedAmountIn
        );

        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, expectedOutput));
        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedOutput);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 与 ERC20 -> ETH 精确输出
    //////////////////////////////////////////////////////////////*/

    function test_nativeOut_swapExactOutputSingle() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;
        bool zeroForOne = false;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            nativeKey, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_nativeOut_swapExactOut_1Hop() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, expectedAmountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    /*//////////////////////////////////////////////////////////////
                路由器自付款覆盖测试
    //////////////////////////////////////////////////////////////*/

    function test_router_self_payment() public {
        uint256 amountIn = 100000;

        IERC20(Currency.unwrap(key2.currency0)).transfer(address(permissionedRouter), amountIn);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key2, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode(key2.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key2.currency1, 0));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key2, true, address(manager));

        // 执行兑换 —— 这应当在 payer == address(this) 且 permissionedToken == address(0) 的情况下触发 _pay 函数
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key2, true, address(manager));

        // 验证使用的是路由器的余额（兑换后应为 0）
        assertEq(key2.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertGt(outputBalanceBefore - outputBalanceAfter, 0);
    }

    function test_router_self_payment_permissioned_token() public {
        uint256 amountIn = 100000;

        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(permissionedRouter), amountIn);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode((key0.currency0), ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode((key0.currency1), 0));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));

        // 执行兑换 —— 这应当在 payer == address(this) 且 permissionedToken != address(0) 的情况下触发 _pay 函数
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        // 验证使用的是路由器的余额（兑换后应为 0）
        assertEq(getPermissionedCurrency(key0.currency0).balanceOf(address(permissionedRouter)), 0);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertGt(outputBalanceBefore - outputBalanceAfter, 0);
    }

    function test_router_self_payment_permissioned_token_unauthorized_reverts() public {
        uint256 amountIn = 100000;

        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(key0.currency0)))
            .setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(unauthorizedUser), amountIn);

        vm.prank(unauthorizedUser);
        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(permissionedRouter), amountIn);

        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(key0.currency0)))
            .setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode((key0.currency0), ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode((key0.currency1), 0));

        bytes memory data = plan.encode();

        vm.prank(unauthorizedUser);
        vm.expectRevert(Unauthorized.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_command_permit2_permit() public {
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: Currency.unwrap(currency0), amount: 1e18, expiration: uint48(block.timestamp + 3600), nonce: 0
            }),
            spender: address(permissionedRouter),
            sigDeadline: block.timestamp + 3600
        });

        uint256 testKey = uint256(0x22);
        address testSigner = vm.addr(testKey);

        bytes32 digest = generatePermitDigest(permitSingle);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory data = abi.encode(permitSingle, signature);

        vm.prank(testSigner);
        permissionedRouter.execute(COMMAND_PERMIT2_PERMIT, toBytesArray(data), type(uint256).max);
    }

    function test_invalid_command_reverts() public {
        bytes memory data = hex"1234567890";
        vm.expectRevert(abi.encodeWithSelector(InvalidCommandType.selector, uint8(0x07)));
        permissionedRouter.execute(hex"07", toBytesArray(data), type(uint256).max);
    }

    function test_failed_call_reverts() public {
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: Currency.unwrap(currency0), amount: 1e18, expiration: uint48(block.timestamp + 3600), nonce: 0
            }),
            spender: address(permissionedRouter),
            sigDeadline: block.timestamp + 3600
        });
        uint256 testKey = uint256(0x22);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testKey, hex"aa");
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory data = abi.encode(permitSingle, signature);

        vm.expectRevert(abi.encodeWithSelector(ExecutionFailed.selector, 0, hex""));
        permissionedRouter.execute(COMMAND_PERMIT2_PERMIT, toBytesArray(data), type(uint256).max);
    }

    function test_slice_out_of_bounds_reverts() public {
        bytes memory data = hex"1234567890";
        vm.expectRevert(SliceOutOfBounds.selector);
        permissionedRouter.execute(COMMAND_PERMIT2_PERMIT, toBytesArray(data), type(uint256).max);
    }

    function test_hooks() public {
        ModifyLiquidityParams memory modifyLiquidityParams =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, salt: bytes32(0)});
        BalanceDelta balanceDelta = BalanceDelta.wrap(0);

        // 以 manager 身份调用，避免带 OnlyPoolManager 修饰器的 hook 报 NotPoolManager 错误
        vm.startPrank(address(manager));
        // afterSwap 已实现，并另行测试
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterInitialize(address(this), key0, 0, 0);
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.beforeRemoveLiquidity(address(this), key0, modifyLiquidityParams, bytes(""));
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterRemoveLiquidity(
            address(this), key0, modifyLiquidityParams, balanceDelta, balanceDelta, bytes("")
        );
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterAddLiquidity(
            address(this), key0, modifyLiquidityParams, balanceDelta, balanceDelta, bytes("")
        );
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.beforeDonate(address(this), key0, 0, 0, bytes(""));
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterDonate(address(this), key0, 0, 0, bytes(""));
    }

    /*//////////////////////////////////////////////////////////////
                receive / fallback 测试
    //////////////////////////////////////////////////////////////*/

    error InvalidEthSender();

    function test_receive_fallback_reverts() public {
        (bool success, bytes memory data) = address(permissionedRouter).call{value: 1 ether}("");

        assertEq(success, false);
        assertEq(bytes4(data), InvalidEthSender.selector);
    }

    function test_receive_fallback_from_posm() public {
        vm.deal(address(manager), 1 ether);

        vm.prank(address(manager));
        (bool success,) = address(permissionedRouter).call{value: 1 ether}("");
        assertEq(success, true);
    }

    function test_receive_fallback_from_weth() public {
        vm.deal(address(permissionedRouter), 1 ether);

        vm.startPrank(address(permissionedRouter));
        weth9.deposit{value: 1 ether}();
        weth9.approve(address(permissionedRouter), 1 ether);
        weth9.withdraw(1 ether);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            兑换事件测试
    //////////////////////////////////////////////////////////////*/

    function _assertSwapEventMatchesPoolState(VmSafe.Log memory log, PoolKey memory key) private view {
        (,, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee) =
            abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));
        PoolId id = key.toId();
        (uint160 expectedSqrtPrice, int24 expectedTick,, uint24 expectedFee) = manager.getSlot0(id);
        uint128 expectedLiquidity = manager.getLiquidity(id);
        assertEq(sqrtPriceX96, expectedSqrtPrice);
        assertEq(tick, expectedTick);
        assertEq(liquidity, expectedLiquidity);
        assertEq(fee, expectedFee);
    }

    function test_swapExactInputSingle_emitsSwapEvent() public {
        uint256 amountIn = 1 ether;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.recordLogs();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapTopic = MockPermissionedHooks.Swap.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic && logs[i].emitter == address(permissionedHooks)) {
                found = true;
                assertEq(logs[i].topics[1], PoolId.unwrap(adapterKey.toId()));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(this)))));

                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(amount0, -int128(int256(amountIn)));
                assertGt(amount1, 0);

                _assertSwapEventMatchesPoolState(logs[i], adapterKey);
                break;
            }
        }
        assertTrue(found, "Swap event not found");
    }

    function test_swapExactOutputSingle_emitsSwapEvent() public {
        uint256 amountOut = 1000;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(adapterKey, true, uint128(amountOut), type(uint128).max, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.recordLogs();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapTopic = MockPermissionedHooks.Swap.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic && logs[i].emitter == address(permissionedHooks)) {
                found = true;
                assertEq(logs[i].topics[1], PoolId.unwrap(adapterKey.toId()));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(this)))));

                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertLt(amount0, 0);
                assertEq(amount1, int128(int256(amountOut)));

                _assertSwapEventMatchesPoolState(logs[i], adapterKey);
                break;
            }
        }
        assertTrue(found, "Swap event not found");
    }

    function test_swapExactIn_2Hops_emitsSwapEvents() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(permissionsAdapter0Currency, currency2, ActionConstants.MSG_SENDER);

        vm.recordLogs();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapTopic = MockPermissionedHooks.Swap.selector;
        uint256 swapEventCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic && logs[i].emitter == address(permissionedHooks)) {
                swapEventCount++;
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(this)))));
            }
        }
        assertEq(swapEventCount, 2, "Expected 2 Swap events for 2-hop swap");
    }

    /*//////////////////////////////////////////////////////////////
                    池初始化测试
    //////////////////////////////////////////////////////////////*/

    function test_initialize_reverts_no_verified_adapter() public {
        // 两个非许可代币 —— 都不是已验证的适配器
        (Currency c0, Currency c1) = currency2 < currency3 ? (currency2, currency3) : (currency3, currency2);
        PoolKey memory unverifiedKey = PoolKey(c0, c1, 3000, 60, permissionedHooks);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(NoVerifiedAdapter.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        manager.initialize(unverifiedKey, SQRT_PRICE_1_1);
    }

    function test_initialize_succeeds_one_verified_adapter() public {
        Currency adapterCurrency = Currency.wrap(address(permissionsAdapter1));
        (Currency c0, Currency c1) =
            adapterCurrency < currency3 ? (adapterCurrency, currency3) : (currency3, adapterCurrency);
        PoolKey memory oneAdapterKey = PoolKey(c0, c1, 500, 10, permissionedHooks);
        manager.initialize(oneAdapterKey, SQRT_PRICE_1_1);
    }

    function test_initialize_succeeds_two_verified_adapters() public {
        Currency a0 = Currency.wrap(address(permissionsAdapter0));
        Currency a1 = Currency.wrap(address(permissionsAdapter1));
        (Currency c0, Currency c1) = a0 < a1 ? (a0, a1) : (a1, a0);
        PoolKey memory twoAdapterKey = PoolKey(c0, c1, 500, 10, permissionedHooks);
        manager.initialize(twoAdapterKey, SQRT_PRICE_1_1);
    }

    function test_initialize_reverts_unverified_adapter_paired_with_plain_token() public {
        // 为许可代币创建适配器但不进行验证 —— 即 M-03 攻击路径
        // currency0 是 MockPermissionedToken（setup 中前 2 个代币是许可代币）
        IERC20 token = IERC20(Currency.unwrap(currency0));
        MockAllowlistChecker checker = new MockAllowlistChecker();
        address unverifiedAdapter = permissionsAdapterFactory.createPermissionsAdapter(token, address(this), checker);
        // 不进行验证 —— 跳过转入 1 wei 和调用 verifyPermissionsAdapter 这两步

        Currency adapterCurrency = Currency.wrap(unverifiedAdapter);
        (Currency c0, Currency c1) =
            adapterCurrency < currency4 ? (adapterCurrency, currency4) : (currency4, adapterCurrency);
        PoolKey memory attackKey = PoolKey(c0, c1, 3000, 60, permissionedHooks);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(UnverifiedAdapter.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        manager.initialize(attackKey, SQRT_PRICE_1_1);
    }

    /// @dev 封堵 M-03 的残留缺口：仅靠“至少一个已验证适配器”这条规则，在
    /// 一侧为已验证适配器、另一侧为已注册但未验证的适配器时仍会通过。新增的
    /// 逐代币检查必须拒绝这种配置，以免在第二个适配器完成验证之前
    /// 流动性被单边停放在池中。
    function test_initialize_reverts_verified_paired_with_unverified_adapter() public {
        // 为另一个许可代币（currency1）构建一个全新的、未验证的适配器。
        IERC20 token = IERC20(Currency.unwrap(currency1));
        MockAllowlistChecker checker = new MockAllowlistChecker();
        address unverifiedAdapter = permissionsAdapterFactory.createPermissionsAdapter(token, address(this), checker);
        // 不进行验证。

        Currency verifiedAdapterCurrency = Currency.wrap(address(permissionsAdapter0));
        Currency unverifiedAdapterCurrency = Currency.wrap(unverifiedAdapter);
        (Currency c0, Currency c1) = verifiedAdapterCurrency < unverifiedAdapterCurrency
            ? (verifiedAdapterCurrency, unverifiedAdapterCurrency)
            : (unverifiedAdapterCurrency, verifiedAdapterCurrency);
        PoolKey memory attackKey = PoolKey(c0, c1, 3000, 60, permissionedHooks);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(UnverifiedAdapter.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        manager.initialize(attackKey, SQRT_PRICE_1_1);
    }

    receive() external payable {}
    fallback() external {}
}
