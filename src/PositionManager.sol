// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPositionDescriptor} from "./interfaces/IPositionDescriptor.sol";
import {ERC721Permit_v4} from "./base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {PoolInitializer_v4} from "./base/PoolInitializer_v4.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {Actions} from "./libraries/Actions.sol";
import {Notifier} from "./base/Notifier.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {SlippageCheck} from "./libraries/SlippageCheck.sol";
import {PositionInfo, PositionInfoLibrary} from "./libraries/PositionInfoLibrary.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {NativeWrapper} from "./base/NativeWrapper.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";

//                                           444444444
//                                444444444444      444444
//                              444              44     4444
//                             44         4      44        444
//                            44         44       44         44
//                           44          44        44         44
//                          44       444444          44        44
//                         444          4444           4444    44
//                         44             4444                 444444444444444444
//                         44             44  4                44444           444444
//        444444444444    44              4                444                      44
//        44        44444444              4             444                         44
//       444              44                          44                           444
//        44               4  4444444444444444444444444           4444444444     4444
//         44              44444444444444444444444444      444               44444
//          444                                  44 44444444444444444444444444
//           4444                             444444444444444444444444
//              4444                      444444    444444444444444
//                 44444              444444        44444444444444444444444
//                     444444444444444    4           44444 44444444444444444444
//                           444                          444444444444444444444444444
//                           444                           44444  44444444444     44444444
//                          444                               4   44444444444444   444444444
//                         4444 444                               44 4444444444444     44444444
//                         44  44444         44444444             44444444444444444444     44444
//                        444 444444        4444  4444             444444444444444444     44  4444
//                 4444   44  44444        44444444444             444444444444444444444    44444444
//                     44444   4444        4444444444             444444444444444444444444     44444
//                 44444 44444 444         444444                4444444444444444444444444       44444
//                       4444 44         44                     4 44444444444444444444444444   444 44444
//                   44444444 444  44   4    4         444444  4 44444444444444444444444444444   4444444
//                        444444    44       44444444444       44444444444444 444444444444444      444444
//                     444444 44   4444      44444       44     44444444444444444444444 4444444      44444
//                   44    444444   44   444444444 444        4444444444444444444444444444444444   4444444
//                       44  4444444444444    44  44  44       4444444444444444444444444444444       444444
//                      44  44444444444444444444444444  4   44 4444444444444444444444444444444    4   444444
//                     4    4444                     4    4 4444444444444444444444444              44 4444444
//                          4444                          4444444444444444444444444    4   4444     44444444
//                          4444                         444444444444444444444444  44444     44444 4444444444
//                          44444  44                  444444444444444444444444444444444444444444444444444444
//                          44444444444               4444444444444444444444444444444444444444444444444444444
//                           4444444444444           44444444444444444444444444444444444444444444444444444444
//                           444444444444444         444444444444444444444444444444444444444444444444444444444
//                            44444444444444444     4444444444444444444444444444444444444444444444444444444444
//                            44444444444444444     44444444444444444444444444444444444444444444444444444444
//                            44444444444444444444  444444444444444444444444444444444444444444444444444444444
//                            444444444444444444444 444444444444444444444444444444444444444444444444444444444
//                              444444444444444444444 4444444444444444444444444444444444444444444444444444444
//                              44444444444444444444444444444444444444444444444444444444444444444444444444444
//                               444444444444444444444444444444444444444444444444444444444444444444444444444
//                                44444444444444444444444444444444444444444444444444444444444444444444444444
//                               44444444444444444444444444444444444444444444444444      444444444444444444
//                             444444444444444444444444444444444444444444444444       44444444444444444444
//                           444   444   444   44  444444444444444444444 4444      444444444444444444444
//                           444  444    44    44  44444444 4444444444444       44444444444444444444444
//                            444 444   4444   4444 4444444444444444         44444444444444444444444444
//                      4444444444444444444444444444444444444444        44444444444444444444444444444
//                       444        4444444444444444444444444       44444444444444444444444444444444
//                          4444444       444444444444         4444444444444444444444444444444444
//                             4444444444                 44444444444444444444444444444444444
//                                444444444444444444444444444444444444444444444444444444
//                                     44444444444444444444444444444444444444444
//                                              4444444444444444444

/// @notice PositionManager（PosM）合约负责在 v4 上创建流动性头寸。
/// PosM 铸造并管理与每个头寸相关联的 ERC721 代币。
contract PositionManager is
    IPositionManager,
    ERC721Permit_v4,
    PoolInitializer_v4,
    Multicall_v4,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouter,
    Notifier,
    Permit2Forwarder,
    NativeWrapper
{
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CalldataDecoder for bytes;
    using SlippageCheck for BalanceDelta;

    /// @inheritdoc IPositionManager
    /// @dev 下一个将被铸造的代币 ID。跳过 0
    uint256 public nextTokenId = 1;

    IPositionDescriptor public immutable tokenDescriptor;

    mapping(uint256 tokenId => PositionInfo info) public positionInfo;
    mapping(bytes25 poolId => PoolKey poolKey) public poolKeys;

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9
    )
        BaseActionsRouter(_poolManager)
        Permit2Forwarder(_permit2)
        ERC721Permit_v4("Uniswap v4 Positions NFT", "UNI-V4-POSM")
        Notifier(_unsubscribeGasLimit)
        NativeWrapper(_weth9)
    {
        tokenDescriptor = _tokenDescriptor;
    }

    /// @notice 若已超过截止时间则回滚（revert）
    /// @param deadline 调用失效的时间戳，由调用者传入
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @notice 若调用者既不是该 ERC721 代币的所有者、也未获得其授权，则回滚（revert）
    /// @param caller 调用者的地址
    /// @param tokenId 该 ERC721 代币的唯一标识符
    /// @dev 传入的 caller 为 msg.sender 或 msgSender() 二者之一
    /// 仅当在 unlockCallback 内部调用时才应使用 msgSender()，除非该代码路径具有重入保护
    modifier onlyIfApproved(address caller, uint256 tokenId) override {
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);
        _;
    }

    /// @notice 强制要求 PoolManager 处于锁定状态。
    modifier onlyIfPoolManagerLocked() override {
        if (poolManager.isUnlocked()) revert PoolManagerMustBeLocked();
        _;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return IPositionDescriptor(tokenDescriptor).tokenURI(this, tokenId);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(unlockData);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        isNotLocked
    {
        _executeActionsWithoutUnlock(actions, params);
    }

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action < Actions.SETTLE) {
            if (action == Actions.INCREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                    params.decodeModifyLiquidityParams();
                _increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
                return;
            } else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                // DEPRECATED - 已弃用：易受三明治攻击，请勿使用。参见 _increaseFromDeltas()。
                (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                    params.decodeIncreaseLiquidityFromDeltasParams();
                _increaseFromDeltas(tokenId, amount0Max, amount1Max, hookData);
                return;
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeModifyLiquidityParams();
                _decrease(tokenId, liquidity, amount0Min, amount1Min, hookData);
                return;
            } else if (action == Actions.MINT_POSITION) {
                (
                    PoolKey calldata poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint256 liquidity,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes calldata hookData
                ) = params.decodeMintParams();
                _mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, _mapRecipient(owner), hookData);
                return;
            } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
                // DEPRECATED - 已弃用：易受三明治攻击，请勿使用。参见 _mintFromDeltas()。
                (
                    PoolKey calldata poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes calldata hookData
                ) = params.decodeMintFromDeltasParams();
                _mintFromDeltas(poolKey, tickLower, tickUpper, amount0Max, amount1Max, _mapRecipient(owner), hookData);
                return;
            } else if (action == Actions.BURN_POSITION) {
                // 若头寸尚未清空，会自动将流动性减少至 0。
                (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeBurnParams();
                _burn(tokenId, amount0Min, amount1Min, hookData);
                return;
            }
        } else {
            if (action == Actions.SETTLE_PAIR) {
                (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
                _settlePair(currency0, currency1);
                return;
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address recipient) = params.decodeCurrencyPairAndAddress();
                _takePair(currency0, currency1, _mapRecipient(recipient));
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.CLOSE_CURRENCY) {
                Currency currency = params.decodeCurrency();
                _close(currency);
                return;
            } else if (action == Actions.CLEAR_OR_TAKE) {
                (Currency currency, uint256 amountMax) = params.decodeCurrencyAndUint256();
                _clearOrTake(currency, amountMax);
                return;
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = params.decodeCurrencyAndAddress();
                _sweep(currency, _mapRecipient(to));
                return;
            } else if (action == Actions.WRAP) {
                uint256 amount = params.decodeUint256();
                _wrap(_mapWrapUnwrapAmount(CurrencyLibrary.ADDRESS_ZERO, amount, Currency.wrap(address(WETH9))));
                return;
            } else if (action == Actions.UNWRAP) {
                uint256 amount = params.decodeUint256();
                _unwrap(_mapWrapUnwrapAmount(Currency.wrap(address(WETH9)), amount, CurrencyLibrary.ADDRESS_ZERO));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    /// @dev 以 0 流动性调用 increase，会将该头寸的全部底层手续费记入调用者名下（credit）
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal virtual onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        // 注意：tokenId 被用作该头寸的 salt，因此每个铸造出的头寸在 PoolManager 中都有唯一的存储。
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        // 滑点检查应基于本金部分的 liquidityDelta，即 liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
    }

    /// @notice DEPRECATED（已弃用）：易受三明治攻击——请勿使用此函数。
    /// @dev 与 _mintFromDeltas 存在相同问题——这种基于 delta 的方式不提供最小
    /// 流动性保护。请改用 _increase()。
    function _increaseFromDeltas(uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
        internal
        virtual
        onlyIfApproved(msgSender(), tokenId)
    {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        uint256 liquidity;
        {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

            // 使用 PoolManager 上的 credit 作为本次铸造的数量。
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(info.tickLower()),
                TickMath.getSqrtPriceAtTick(info.tickUpper()),
                _getFullCredit(poolKey.currency0),
                _getFullCredit(poolKey.currency1)
            );
        }

        // 注意：tokenId 被用作该头寸的 salt，因此每个铸造出的头寸在 PoolManager 中都有唯一的存储。
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        // 滑点检查应基于本金部分的 liquidityDelta，即 liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
    }

    /// @dev 以 0 流动性调用 decrease，会将该头寸的全部底层手续费记入调用者名下（credit）
    function _decrease(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) internal onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        // 注意：tokenId 被用作 salt。
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, -(liquidity.toInt256()), bytes32(tokenId), hookData);
        // 滑点检查应基于本金部分的 liquidityDelta，即 liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
    }

    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal virtual {
        // 铸造凭证代币
        uint256 tokenId;
        // 先将当前的 nextTokenId 赋给 tokenId，再将其递增
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        // 初始化头寸信息
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        positionInfo[tokenId] = info;

        // 若 poolKey 尚未存储，则将其存储。
        // 在 UniswapV4 中，最小 tick 间距为 1，这意味着如果 tick 间距为 0，则说明该池的 poolKey 尚未被设置。
        bytes25 poolId = info.poolId();
        if (poolKeys[poolId].tickSpacing == 0) {
            poolKeys[poolId] = poolKey;
        }

        // 由于这是新头寸，手续费 delta 可以忽略
        (BalanceDelta liquidityDelta,) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        liquidityDelta.validateMaxIn(amount0Max, amount1Max);
    }

    /// @notice DEPRECATED（已弃用）：易受三明治攻击——请勿使用此函数。
    /// @dev amount0Max/amount1Max 参数是多余的，因为已结算的数量本身已经
    /// 充当了上限。而获得的流动性却没有下限。
    /// 如果价格被操纵，实际使用的代币会更少（其余部分会被 sweep 退回），
    /// 铸造出的流动性也更少，而最大值检查永远不会触发。
    /// 请改用 _mint()，它接收明确的流动性数量，并具备适当的滑点保护。
    function _mintFromDeltas(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // 使用 PoolManager 上的 credit 作为本次铸造的数量。
        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _getFullCredit(poolKey.currency0),
            _getFullCredit(poolKey.currency1)
        );

        _mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev 此函数与 ERC721Permit_v4._burn 构成重载
    function _burn(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        internal
        onlyIfApproved(msgSender(), tokenId)
    {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        uint256 liquidity = uint256(_getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper()));

        address owner = ownerOf(tokenId);

        // 清除头寸信息。
        positionInfo[tokenId] = PositionInfoLibrary.EMPTY_POSITION_INFO;
        // 销毁该代币。
        _burn(tokenId);

        // 只有在流动性非零时才能调用 modify。
        BalanceDelta feesAccrued;
        if (liquidity > 0) {
            BalanceDelta liquidityDelta;
            // 不使用 _modifyLiquidity，因为销毁时无需对此次修改发出通知。
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: -(liquidity.toInt256()),
                salt: bytes32(tokenId)
            });
            (liquidityDelta, feesAccrued) = poolManager.modifyLiquidity(poolKey, params, hookData);
            emit ModifyPosition(
                poolKey.toId(), msgSender(), params.tickLower, params.tickUpper, params.liquidityDelta, params.salt
            );
            // 滑点检查应基于本金部分的 liquidityDelta，即 liquidityDelta - feesAccrued
            (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
        }

        // 先删除，再通知订阅者
        if (info.hasSubscriber()) _removeSubscriberAndNotifyBurn(tokenId, owner, info, liquidity, feesAccrued);
    }

    function _settlePair(Currency currency0, Currency currency1) internal {
        // 结算时，锁定者即为付款方
        address caller = msgSender();
        _settle(currency0, caller, _getFullDebt(currency0));
        _settle(currency1, caller, _getFullDebt(currency1));
    }

    function _takePair(Currency currency0, Currency currency1, address recipient) internal {
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
    }

    function _close(Currency currency) internal {
        // 本合约地址已代表用户/所有者应用了所有 delta
        // 由于整个批量调用过程中都有滑点检查，关闭（close）这整个 delta 是安全的。
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);

        // 锁定者即为付款方或接收方
        address caller = msgSender();
        if (currencyDelta < 0) {
            // 由于池的总供应量存在上限，此处的类型转换是安全的
            _settle(currency, caller, uint256(-currencyDelta));
        } else {
            _take(currency, caller, uint256(currencyDelta));
        }
    }

    /// @dev 集成方可以选择通过 clear 放弃正的 delta
    /// 如果放弃的数量超过用户指定的最大值，则改为提取该数量
    /// 如果没有 credit，则不进行任何调用。
    function _clearOrTake(Currency currency, uint256 amountMax) internal {
        uint256 delta = _getFullCredit(currency);
        if (delta == 0) return;

        // 如果 delta 小于或等于用户指定的上限，则放弃该 delta
        if (delta <= amountMax) {
            poolManager.clear(currency, delta);
        } else {
            _take(currency, msgSender(), delta);
        }
    }

    /// @notice 将本合约中指定代币的全部余额清扫（sweep）给接收者
    function _sweep(Currency currency, address to) internal virtual {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }

    /// @dev 如果该头寸绑定了订阅者，此函数会通知该订阅者
    function _modifyLiquidity(
        PositionInfo info,
        PoolKey memory poolKey,
        int256 liquidityChange,
        bytes32 salt,
        bytes calldata hookData
    ) internal returns (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) {
        (liquidityDelta, feesAccrued) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: info.tickLower(), tickUpper: info.tickUpper(), liquidityDelta: liquidityChange, salt: salt
            }),
            hookData
        );

        emit ModifyPosition(poolKey.toId(), msgSender(), info.tickLower(), info.tickUpper(), liquidityChange, salt);

        if (info.hasSubscriber()) {
            _notifyModifyLiquidity(uint256(salt), liquidityChange, feesAccrued);
        }
    }

    // 抽象函数 DeltaResolver._pay 的实现
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            // 由于池的总供应量存在上限，从 uint256 转换为 uint160 是安全的
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }

    /// @notice 供 Notifier 使用的内部辅助函数
    function _setSubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setSubscribe();
    }

    /// @notice 供 Notifier 使用的内部辅助函数
    function _setUnsubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setUnsubscribe();
    }

    /// @dev 重写 solmate 的 transferFrom，以便在需要时通知订阅者
    /// @dev 若 PoolManager 处于锁定状态则会回滚（revert）
    function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
        super.transferFrom(from, to, id);
        if (positionInfo[id].hasSubscriber()) _unsubscribe(id);
    }

    /// @inheritdoc IPositionManager
    function getPoolAndPositionInfo(uint256 tokenId) public view returns (PoolKey memory poolKey, PositionInfo info) {
        info = positionInfo[tokenId];
        poolKey = poolKeys[info.poolId()];
    }

    /// @inheritdoc IPositionManager
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);
        liquidity = _getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper());
    }

    function _getLiquidity(uint256 tokenId, PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionId = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(tokenId));
        liquidity = poolManager.getPositionLiquidity(poolKey.toId(), positionId);
    }
}
