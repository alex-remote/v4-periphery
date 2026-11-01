// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {BipsLibrary} from "../../src/libraries/BipsLibrary.sol";

contract PaymentsTests is RoutingTestHelpers {
    address bob = makeAddr("BOB");

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
    }

    function test_exactIn_settleAll_revertsSlippage() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, amountIn - 1));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency0, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();
        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, amountIn - 1, amountIn));
        router.executeActions(data);
    }

    function test_exactIn_takeAll_revertsSlippage() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, MAX_SETTLE_AMOUNT));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, expectedAmountOut + 1));

        bytes memory data = plan.encode();
        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, expectedAmountOut + 1, expectedAmountOut)
        );
        router.executeActions(data);
    }

    function test_exactOut_settleAll_revertsSlippage() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), uint128(expectedAmountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountIn - 1));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency0, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();
        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, expectedAmountIn)
        );
        router.executeActions(data);
    }

    function test_exactOut_takeAll_revertsSlippage() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), uint128(expectedAmountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, MAX_SETTLE_AMOUNT));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, amountOut + 1));

        bytes memory data = plan.encode();
        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, amountOut + 1, amountOut));
        router.executeActions(data);
    }

    function test_exactOut_takeAll_settleAll_succeedsExactAmount() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), uint128(expectedAmountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountIn));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, amountOut));

        bytes memory data = plan.encode();
        router.executeActions(data);
    }

    function test_settleFromRouter_takeAll() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        // 预先向路由器注入代币
        key0.currency0.transfer(address(router), amountIn);

        uint256 inputBalanceBefore = key0.currency0.balanceOfSelf();
        uint256 outputBalanceBefore = key0.currency1.balanceOfSelf();

        // 注入的代币已在路由器中
        assertEq(currency0.balanceOf(address(router)), amountIn);
        assertEq(currency1.balanceOf(address(router)), 0);

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();
        router.executeActions(data);

        uint256 inputBalanceAfter = key0.currency0.balanceOfSelf();
        uint256 outputBalanceAfter = key0.currency1.balanceOfSelf();

        // 路由器为空
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        // 调用者的输入代币余额没有变化，但输出代币余额变化了
        assertEq(inputBalanceBefore, inputBalanceAfter);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_settle_takePortion_takeAll() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, amountIn, true));
        // 提取 15 bips 给 Bob
        plan = plan.add(Actions.TAKE_PORTION, abi.encode(key0.currency1, bob, 15));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, 0));

        uint256 inputBalanceBefore = key0.currency0.balanceOfSelf();
        uint256 outputBalanceBefore = key0.currency1.balanceOfSelf();
        uint256 bobBalanceBefore = key0.currency1.balanceOf(bob);

        // 执行前路由器为空
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);

        uint256 inputBalanceAfter = key0.currency0.balanceOfSelf();
        uint256 outputBalanceAfter = key0.currency1.balanceOfSelf();
        uint256 bobBalanceAfter = key0.currency1.balanceOf(bob);

        uint256 expectedFee = expectedAmountOut * 15 / BipsLibrary.BPS_DENOMINATOR;

        // 路由器为空
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        // Bob 得到 expectedFee，调用者得到其余的输出
        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut - expectedFee);
        assertEq(bobBalanceAfter - bobBalanceBefore, expectedFee);
    }

    function test_settle_takePortion_reverts() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, amountIn, true));
        // bips 大于允许的最大 bips
        plan = plan.add(Actions.TAKE_PORTION, abi.encode(key0.currency1, bob, BipsLibrary.BPS_DENOMINATOR + 1));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, 0));

        bytes memory data = plan.encode();

        vm.expectRevert(BipsLibrary.InvalidBips.selector);
        router.executeActions(data);
    }
}
