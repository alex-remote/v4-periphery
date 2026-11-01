// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice 精确输出是全有或全无的。当池在达到价格限制之前流动性耗尽时，
///         v4 兑换（swap）可能只部分成交；路由器必须以 `V4ExactOutputUnfilled` 回滚（revert），
///         而不是悄无声息地交付少于所请求 `amountOut` 的数量。这些测试通过路由器，针对一个刻意构造的
///         浅流动性池执行真实的精确输出兑换。
contract V4RouterExactOutputUnfilledTest is RoutingTestHelpers {
    PoolKey internal thinKey;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
        // 流动性只位于单个 tick 间距区间内，因此在价格离开该区间之前，
        // 1e18 的精确输出请求无法完全成交
        thinKey = _createThinPool(currency0, currency1, 500, 0, 60);
    }

    function test_exactOutputSingle_revertsOnUnderfill() public {
        // 通过卖出 currency1 买入 currency0（oneForZero）；该浅流动性区间无法交付 1e18 的输出
        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(thinKey, false, 1 ether, type(uint128).max, 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency0, ActionConstants.MSG_SENDER);

        vm.expectPartialRevert(IV4Router.V4ExactOutputUnfilled.selector);
        router.executeActions(data);
    }

    function test_exactOutput_multiHop_revertsOnUnderfill() public {
        // 两跳路径 currency2 -> currency1 -> currency0，其最后一跳（currency1 -> currency0）
        // 是浅流动性池；最后一跳无法交付 1e18 的 currency0
        tokenPath.push(currency2);
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, 1 ether);
        // 通过覆盖路径中最后一跳的 fee/tickSpacing，使其经过浅流动性池
        params.path[1].fee = 500;
        params.path[1].tickSpacing = 60;

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, currency0, ActionConstants.MSG_SENDER);

        vm.expectPartialRevert(IV4Router.V4ExactOutputUnfilled.selector);
        router.executeActions(data);
    }

    /// @notice 当路径中重复出现某个代币时，中间跳的成交不足不能留给结算阶段去发现。
    ///         这里中间的 currency1 -> currency0 这一跳成交不足，并且由于 currency0
    ///         同时也是该路由的输入代币，差额会并入由
    ///         SETTLE_ALL 支付的输入欠款中——因此不会残留非零 delta 导致结算失败，而
    ///         循环结束后的 amountInMaximum 检查也只会看到最后一跳自身的输入。
    function test_exactOutput_revertsOnIntermediateUnderfill_repeatedCurrency() public {
        // 最终交付的那一跳使用深流动性池，因此只有中间一跳是浅流动性的
        createPoolWithLiquidity(currency0, currency2, address(0));

        // 实际经济路由为 currency0 -> currency1 -> currency0 -> currency2
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, 1 ether);
        // 让中间的 currency1 -> currency0 这一跳经过浅流动性池
        params.path[1].fee = 500;
        params.amountInMaximum = 0.8 ether;

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, ActionConstants.MSG_SENDER);

        vm.expectPartialRevert(IV4Router.V4ExactOutputUnfilled.selector);
        router.executeActions(data);
    }

    function test_exactOutputSingle_fullFillSucceeds() public {
        // 深流动性池（key0）可完全成交，不受新增防护检查的影响
        uint256 amountOut = 1 ether;
        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), type(uint128).max, 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (, uint256 outputBalanceBefore,, uint256 outputBalanceAfter) =
            _finalizeAndExecuteSwap(currency0, currency1, 2 ether);

        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut, "exact output delivered in full");
        assertEq(currency0.balanceOf(address(router)), 0, "router holds no input residual");
        assertEq(currency1.balanceOf(address(router)), 0, "router holds no output residual");
    }

    function _createThinPool(Currency a, Currency b, uint24 fee, int24 lower, int24 upper)
        internal
        returns (PoolKey memory key)
    {
        if (Currency.unwrap(a) > Currency.unwrap(b)) (a, b) = (b, a);
        key = PoolKey(a, b, fee, 60, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(a)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(b)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, 200 ether, 0), "0x");
    }
}
