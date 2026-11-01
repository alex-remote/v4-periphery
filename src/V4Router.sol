// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {PathKey} from "./libraries/PathKey.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {BipsLibrary} from "./libraries/BipsLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title UniswapV4Router
/// @notice 抽象合约，包含通过 Uniswap v4 池进行路由所需的全部内部逻辑
/// @dev 在本合约中执行操作（action）的入口是调用 `BaseActionsRouter._executeActions`
/// 继承合约应在希望执行这些操作的时点调用 _executeActions
abstract contract V4Router is IV4Router, BaseActionsRouter, DeltaResolver {
    using SafeCast for *;
    using CalldataDecoder for bytes;
    using BipsLibrary for uint256;

    uint256 private constant PRECISION = 1e36;

    constructor(IPoolManager _poolManager) BaseActionsRouter(_poolManager) {}

    function _handleAction(uint256 action, bytes calldata params) internal override {
        // 兑换（swap）操作与支付操作分放在不同的代码块中，以提高 gas 效率
        if (action < Actions.SETTLE) {
            if (action == Actions.SWAP_EXACT_IN) {
                IV4Router.ExactInputParams calldata swapParams = params.decodeSwapExactInParams();
                _swapExactInput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                IV4Router.ExactInputSingleParams calldata swapParams = params.decodeSwapExactInSingleParams();
                _swapExactInputSingle(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT) {
                IV4Router.ExactOutputParams calldata swapParams = params.decodeSwapExactOutParams();
                _swapExactOutput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                IV4Router.ExactOutputSingleParams calldata swapParams = params.decodeSwapExactOutSingleParams();
                _swapExactOutputSingle(swapParams);
                return;
            }
        } else {
            if (action == Actions.SETTLE_ALL) {
                (Currency currency, uint256 maxAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullDebt(currency);
                if (amount > maxAmount) revert V4TooMuchRequested(maxAmount, amount);
                _settle(currency, msgSender(), amount);
                return;
            } else if (action == Actions.TAKE_ALL) {
                (Currency currency, uint256 minAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullCredit(currency);
                if (amount < minAmount) revert V4TooLittleReceived(minAmount, amount);
                _take(currency, msgSender(), amount);
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE_PORTION) {
                (Currency currency, address recipient, uint256 bips) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _getFullCredit(currency).calculatePortion(bips));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    function _swapExactInputSingle(IV4Router.ExactInputSingleParams calldata params) private {
        uint128 amountIn = params.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn =
                _getFullCredit(params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1).toUint128();
        }
        uint128 amountOut = _swapOutput(
            _swap(params.poolKey, params.zeroForOne, -int256(uint256(amountIn)), params.hookData), params.zeroForOne
        );
        if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        if (params.minHopPriceX36 != 0) {
            uint256 priceX36 = uint256(amountOut) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooLittleReceivedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactInput(IV4Router.ExactInputParams calldata params) private {
        unchecked {
            // 缓存变量以节省 gas
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = params.amountIn;
            if (amountIn == ActionConstants.OPEN_DELTA) amountIn = _getFullCredit(currencyIn).toUint128();
            PathKey calldata pathKey;

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                // 输出 delta 总是为正，除非与某些带 hook 的池交互
                amountOut =
                    _swapOutput(_swap(poolKey, zeroForOne, -int256(uint256(amountIn)), pathKey.hookData), zeroForOne);

                if (perHopPriceLength != 0) {
                    uint256 priceX36 = amountOut * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i];
                    if (priceX36 < minPrice) revert V4TooLittleReceivedPerHop(i, minPrice, priceX36);
                }

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        }
    }

    function _swapExactOutputSingle(IV4Router.ExactOutputSingleParams calldata params) private {
        uint128 amountOut = params.amountOut;
        if (amountOut == ActionConstants.OPEN_DELTA) {
            amountOut =
                _getFullDebt(params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0).toUint128();
        }
        BalanceDelta delta = _swap(params.poolKey, params.zeroForOne, int256(uint256(amountOut)), params.hookData);
        // 精确输出是“全有或全无”的：如果池在到达价格限制之前流动性耗尽，
        // 实际交付的数量可能少于请求数量。数量不足时回滚（revert）可确保“精确输出”名副其实；
        // 允许超额交付（仅可能通过带 hook 的池发生）。
        uint128 amountOutActual = _swapOutput(delta, params.zeroForOne);
        if (amountOutActual < amountOut) revert V4ExactOutputUnfilled(amountOut, amountOutActual);
        uint128 amountIn = _swapInput(delta, params.zeroForOne);
        if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        if (params.minHopPriceX36 != 0) {
            uint256 priceX36 = uint256(amountOutActual) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooMuchRequestedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactOutput(IV4Router.ExactOutputParams calldata params) private {
        unchecked {
            // 缓存变量以节省 gas
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            if (amountOut == ActionConstants.OPEN_DELTA) {
                amountOut = _getFullDebt(currencyOut).toUint128();
            }

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                // 输出 delta 总是为正，除非与某些带 hook 的池交互
                BalanceDelta delta = _swap(poolKey, !oneForZero, int256(uint256(amountOut)), pathKey.hookData);
                uint128 amountOutActual = _swapOutput(delta, !oneForZero);
                // 每一跳都必须完全成交。PoolManager 在整个解锁周期内对每种代币只记录一个净 delta，
                // 因此中间跳的数量不足可能被同一代币的贷记（credit）抵消，从而被静默结算，
                // 而不会回滚（revert）。
                if (amountOutActual < amountOut) {
                    revert V4ExactOutputUnfilled(amountOut, amountOutActual);
                }
                amountIn = _swapInput(delta, !oneForZero);

                if (perHopPriceLength != 0) {
                    uint256 priceX36 = uint256(amountOutActual) * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i - 1];
                    if (priceX36 < minPrice) revert V4TooMuchRequestedPerHop(i - 1, minPrice, priceX36);
                }
                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        }
    }

    /// @notice 在通过某个池进行兑换（swap）之前对其进行校验
    /// @dev 默认不执行任何操作。每次兑换调用一次，即多跳路由中的每一跳都会调用。
    ///      继承的路由器可重写此函数，以拒绝其不得交易的池。
    function _validatePoolKey(PoolKey memory poolKey) internal view virtual {}

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        private
        returns (BalanceDelta delta)
    {
        _validatePoolKey(poolKey);

        // 为保护 exactOut 兑换，本合约不对外提供 sqrtPriceLimit 功能
        delta = poolManager.swap(
            poolKey,
            SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            hookData
        );
    }

    /// @notice 一次兑换所消耗的正输入数量，由其余额 delta 推导得出。
    /// @dev 被花费代币的 delta 为负（欠池的），因此取反得到正数量。
    function _swapInput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()))).toUint128();
    }

    /// @notice 一次兑换所产出的正输出数量，由其余额 delta 推导得出。对于
    ///         精确输出兑换，这是“实际实现”（REALIZED）的输出数量；当池在到达价格限制之前
    ///         缺乏足够流动性完成成交时，该值可能小于请求的数量。
    function _swapOutput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (zeroForOne ? delta.amount1() : delta.amount0()).toUint128();
    }
}
