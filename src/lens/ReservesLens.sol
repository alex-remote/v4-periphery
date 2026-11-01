// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC165Checker} from "openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../interfaces/IReservesLens.sol";
import {IHookStats} from "../interfaces/external/IHookStats.sol";

/// @title ReservesLens
/// @notice 无状态的 view 合约，用于查询 v4 core 流动性 TVL 以及可选的 URC-3 hook 统计数据
/// @dev 通过按升序遍历已初始化的 tick、依次应用每个 tick 的
///      liquidityNet，并对每个非零流动性区间使用 core 的 SqrtPriceMath，来重建聚合流动性曲线。原始 PoolManager 状态通过
///      extsload 读取；因此本合约与兼容的 v4 PoolManager 部署所采用的 StateLibrary 存储布局
///      相耦合。PoolManager 由每次调用传入，这样不含构造函数的字节码就可以在每条兼容链上
///      部署到同一个确定性地址。调用者负责选择规范（canonical）的
///      PoolManager，并从其 Initialize 事件中获取完整的 PoolKey。
contract ReservesLens is IReservesLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 private constant CURSOR_VERSION = 1;
    uint256 private constant CURSOR_LENGTH = 15 * 32;
    uint32 private constant MIN_PAGE_READS = 2;
    uint32 private constant MAX_PAGE_READS = 4096;
    /// @dev 调用者传入 maxReads == 0 时使用的分页预算；每页约 2M gas，可满足任何 eth_call 限制
    uint32 private constant DEFAULT_PAGE_READS = 512;
    uint256 private constant BITMAP_BATCH_SIZE = 256;
    uint256 private constant HOOK_STATS_GAS_LIMIT = 500_000;
    /// @dev 在信任该接口之前，ERC165Checker 最多发起三次各 30k gas 的探测
    uint256 private constant ERC165_PROBE_GAS = 90_000;
    /// @dev 探测 hook 统计数据前必须剩余的 gas：包括 ERC165 探测、三次有上限的统计调用，以及它们之间的
    ///      本地开销，并按比例上调，使 EIP-150 的 63/64 转发规则不会导致任何单次调用 gas 不足
    uint256 private constant HOOK_STATS_GAS_BUDGET = ((3 * HOOK_STATS_GAS_LIMIT + ERC165_PROBE_GAS + 15_000) * 64) / 63;
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint16 private constant CUSTOM_ACCOUNTING_MASK = (1 << 4) - 1;

    struct ScanState {
        uint8 version;
        uint256 blockNumber;
        bytes32 contextHash;
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint128 activeLiquidity;
        int16 wordPos;
        uint16 bitPos;
        bool hasPreviousTick;
        int24 previousTick;
        uint128 runningLiquidity;
        uint256 amount0;
        uint256 amount1;
        bool observedCurrentLiquidity;
        uint128 currentLiquidity;
    }

    enum StaticCallStatus {
        SUCCESS,
        FAILED,
        INVALID_RESPONSE,
        INSUFFICIENT_GAS
    }

    /// @inheritdoc IReservesLens
    function getPoolTVL(IPoolManager manager, PoolKey calldata key) external view returns (PoolTVL memory result) {
        return _getPoolTVL(manager, key, address(0));
    }

    /// @inheritdoc IReservesLens
    function getPoolTVL(IPoolManager manager, PoolKey calldata key, address statsProvider)
        external
        view
        returns (PoolTVL memory result)
    {
        return _getPoolTVL(manager, key, statsProvider);
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLBatch(IPoolManager manager, PoolKey[] calldata keys)
        external
        view
        returns (PoolTVL[] memory results)
    {
        results = new PoolTVL[](keys.length);
        for (uint256 i; i < keys.length; i++) {
            results[i] = _getPoolTVL(manager, keys[i], address(0));
        }
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLBatch(IPoolManager manager, PoolKey[] calldata keys, address[] calldata statsProviders)
        external
        view
        returns (PoolTVL[] memory results)
    {
        if (keys.length != statsProviders.length) revert InputLengthMismatch();
        results = new PoolTVL[](keys.length);
        for (uint256 i; i < keys.length; i++) {
            results[i] = _getPoolTVL(manager, keys[i], statsProviders[i]);
        }
    }

    /// @inheritdoc IReservesLens
    function getPopulatedTicksInWord(IPoolManager manager, PoolKey calldata key, int16 wordPos)
        external
        view
        returns (PopulatedTick[] memory populatedTicks)
    {
        PoolId poolId = key.toId();
        _initialize(manager, key.tickSpacing, poolId);
        uint256 bitmap = manager.getTickBitmap(poolId, wordPos);
        uint256 remaining = bitmap;
        uint256 count;
        while (remaining != 0) {
            count++;
            remaining &= remaining - 1;
        }

        populatedTicks = new PopulatedTick[](count);
        for (uint256 i; bitmap != 0; i++) {
            uint8 bit = BitMath.leastSignificantBit(bitmap);
            populatedTicks[i] = _readPopulatedTick(manager, poolId, key.tickSpacing, wordPos, bit);
            bitmap &= bitmap - 1;
        }
    }

    function _getPoolTVL(IPoolManager manager, PoolKey calldata key, address statsProvider)
        private
        view
        returns (PoolTVL memory result)
    {
        PoolId poolId = key.toId();
        ScanState memory state = _initialize(manager, key.tickSpacing, poolId);
        state = _scanComplete(manager, key.tickSpacing, poolId, state);
        result = _result(state, key);
        _readHookStats(result, key, statsProvider);
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLPaged(IPoolManager manager, PoolKey calldata key, bytes calldata cursor)
        external
        view
        returns (PoolTVL memory result, bytes memory nextCursor, bool done)
    {
        return _getPoolTVLPaged(manager, key, address(0), cursor, DEFAULT_PAGE_READS);
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLPaged(
        IPoolManager manager,
        PoolKey calldata key,
        address statsProvider,
        bytes calldata cursor,
        uint32 maxReads
    ) external view returns (PoolTVL memory result, bytes memory nextCursor, bool done) {
        if (maxReads == 0) maxReads = DEFAULT_PAGE_READS;
        return _getPoolTVLPaged(manager, key, statsProvider, cursor, maxReads);
    }

    function _getPoolTVLPaged(
        IPoolManager manager,
        PoolKey calldata key,
        address statsProvider,
        bytes calldata cursor,
        uint32 maxReads
    ) private view returns (PoolTVL memory result, bytes memory nextCursor, bool done) {
        if (maxReads < MIN_PAGE_READS || maxReads > MAX_PAGE_READS) revert InvalidScanBudget(maxReads);

        PoolId poolId = key.toId();
        ScanState memory state;
        if (cursor.length == 0) {
            state = _initialize(manager, key.tickSpacing, poolId);
        } else {
            if (cursor.length != CURSOR_LENGTH) revert InvalidCursor();
            state = abi.decode(cursor, (ScanState));
            if (state.version != CURSOR_VERSION) revert UnsupportedCursorVersion(state.version);
            if (state.contextHash != _contextHash(manager, poolId)) revert CursorContextMismatch();
            if (state.blockNumber != block.number) revert CursorBlockMismatch(state.blockNumber, block.number);
            if (state.bitPos > 256) revert InvalidCursor();
            _verifyCursorSnapshot(manager, poolId, state);
        }

        (state, done) = _scan(manager, key.tickSpacing, poolId, state, maxReads);
        result = _result(state, key);
        if (done) {
            _readHookStats(result, key, statsProvider);
        } else {
            nextCursor = abi.encode(state);
        }
    }

    function _initialize(IPoolManager manager, int24 tickSpacing, PoolId poolId)
        private
        view
        returns (ScanState memory state)
    {
        if (tickSpacing < TickMath.MIN_TICK_SPACING || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing(tickSpacing);
        }

        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(poolId);

        uint128 activeLiquidity = manager.getLiquidity(poolId);
        int24 minCompressed = TickMath.minUsableTick(tickSpacing) / tickSpacing;

        state = ScanState({
            version: CURSOR_VERSION,
            blockNumber: block.number,
            contextHash: _contextHash(manager, poolId),
            sqrtPriceX96: sqrtPriceX96,
            currentTick: currentTick,
            activeLiquidity: activeLiquidity,
            wordPos: int16(minCompressed >> 8),
            bitPos: 0,
            hasPreviousTick: false,
            previousTick: 0,
            runningLiquidity: 0,
            amount0: 0,
            amount1: 0,
            observedCurrentLiquidity: false,
            currentLiquidity: 0
        });
    }

    function _scan(IPoolManager manager, int24 tickSpacing, PoolId poolId, ScanState memory state, uint32 maxReads)
        private
        view
        returns (ScanState memory, bool done)
    {
        int16 maxWord = _maxWord(tickSpacing);
        uint32 reads;

        while (state.wordPos <= maxWord) {
            if (reads >= maxReads) return (state, false);

            uint256 bitmap = manager.getTickBitmap(poolId, state.wordPos);
            reads++;
            // 从 word 中间恢复；移位 256 的结果为零，因此 bitPos 为 256 的游标会完全跳过该 word
            if (state.bitPos != 0) bitmap &= type(uint256).max << state.bitPos;

            bool wordDone;
            (reads, wordDone) = _processWord(manager, tickSpacing, poolId, state, bitmap, reads, maxReads);
            if (!wordDone) return (state, false);

            state.wordPos = int16(int256(state.wordPos) + 1);
            state.bitPos = 0;
        }

        _validateComplete(poolId, state);
        return (state, true);
    }

    function _scanComplete(IPoolManager manager, int24 tickSpacing, PoolId poolId, ScanState memory state)
        private
        view
        returns (ScanState memory)
    {
        int16 maxWord = _maxWord(tickSpacing);
        int256 nextWord = state.wordPos;

        while (nextWord <= maxWord) {
            uint256 remaining = uint256(int256(maxWord) - nextWord + 1);
            uint256 count = remaining < BITMAP_BATCH_SIZE ? remaining : BITMAP_BATCH_SIZE;
            bytes32[] memory slots = new bytes32[](count);
            for (uint256 i; i < count; i++) {
                slots[i] = _tickBitmapSlot(poolId, int16(nextWord + int256(i)));
            }
            bytes32[] memory bitmaps = manager.extsload(slots);
            if (bitmaps.length != count) {
                revert ManagerBatchReadFailed(address(manager), slots[0], slots[count - 1], count);
            }

            for (uint256 i; i < count; i++) {
                state.wordPos = int16(nextWord + int256(i));
                _processWord(manager, tickSpacing, poolId, state, uint256(bitmaps[i]), 0, type(uint32).max);
            }
            nextWord += int256(count);
        }

        state.wordPos = int16(int256(maxWord) + 1);
        state.bitPos = 0;
        _validateComplete(poolId, state);
        return state;
    }

    /// @dev 处理一个位图 word 中的每个已初始化 tick，每个 tick 从预算中扣除一次读取。
    ///      预算耗尽时返回 done=false，并将 state.bitPos 定位到尚未处理的那个比特上。
    function _processWord(
        IPoolManager manager,
        int24 tickSpacing,
        PoolId poolId,
        ScanState memory state,
        uint256 bitmap,
        uint32 reads,
        uint32 maxReads
    ) private view returns (uint32, bool done) {
        while (bitmap != 0) {
            uint8 bit = BitMath.leastSignificantBit(bitmap);
            if (reads >= maxReads) {
                state.bitPos = bit;
                return (reads, false);
            }
            _processInitializedTick(manager, tickSpacing, poolId, state, bit);
            reads++;
            bitmap &= bitmap - 1;
            state.bitPos = uint16(bit) + 1;
        }
        return (reads, true);
    }

    function _maxWord(int24 tickSpacing) private pure returns (int16) {
        return int16((TickMath.maxUsableTick(tickSpacing) / tickSpacing) >> 8);
    }

    function _validateComplete(PoolId poolId, ScanState memory state) private pure {
        if (state.runningLiquidity != 0) revert LiquidityInvariantFailed(poolId);
        uint128 reconstructed = state.observedCurrentLiquidity ? state.currentLiquidity : 0;
        if (reconstructed != state.activeLiquidity) revert LiquidityInvariantFailed(poolId);
    }

    function _processInitializedTick(
        IPoolManager manager,
        int24 tickSpacing,
        PoolId poolId,
        ScanState memory state,
        uint8 bit
    ) private view {
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int256 compressed = int256(state.wordPos) * 256 + int256(uint256(bit));
        int256 tickValue = compressed * int256(tickSpacing);
        if (tickValue < minTick || tickValue > maxTick) revert TickInvariantFailed(poolId, tickValue);

        int24 tick = int24(tickValue);
        (, int128 liquidityNet) = _readTick(manager, poolId, tick);
        if (liquidityNet == 0) return;

        if (state.hasPreviousTick) _accumulateInterval(state, state.previousTick, tick);
        state.runningLiquidity = _addLiquidity(poolId, state.runningLiquidity, liquidityNet);
        state.previousTick = tick;
        state.hasPreviousTick = true;
    }

    function _accumulateInterval(ScanState memory state, int24 tickA, int24 tickB) private pure {
        if (state.currentTick >= tickA && state.currentTick < tickB) {
            state.currentLiquidity = state.runningLiquidity;
            state.observedCurrentLiquidity = true;
        }
        if (state.runningLiquidity == 0) return;

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickA);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickB);
        if (state.currentTick < tickA) {
            state.amount0 += SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, state.runningLiquidity, false);
        } else if (state.currentTick < tickB) {
            state.amount0 += SqrtPriceMath.getAmount0Delta(state.sqrtPriceX96, sqrtB, state.runningLiquidity, false);
            state.amount1 += SqrtPriceMath.getAmount1Delta(sqrtA, state.sqrtPriceX96, state.runningLiquidity, false);
        } else {
            state.amount1 += SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, state.runningLiquidity, false);
        }
    }

    function _addLiquidity(PoolId poolId, uint128 liquidity, int128 delta) private pure returns (uint128 next) {
        int256 value = int256(uint256(liquidity)) + int256(delta);
        if (value < 0 || uint256(value) > type(uint128).max) revert LiquidityInvariantFailed(poolId);
        next = uint128(uint256(value));
    }

    function _result(ScanState memory state, PoolKey calldata key) private pure returns (PoolTVL memory result) {
        address hook = address(key.hooks);
        result.coreAmount0 = state.amount0;
        result.coreAmount1 = state.amount1;
        result.sqrtPriceX96 = state.sqrtPriceX96;
        result.tick = state.currentTick;
        result.activeLiquidity = state.activeLiquidity;
        result.blockNumber = state.blockNumber;
        result.hookPermissions = uint16(uint160(hook) & ALL_HOOK_MASK);
        result.hasCustomAccounting = result.hookPermissions & CUSTOM_ACCOUNTING_MASK != 0;
        result.statsStatus = hook == address(0) ? HookStatsStatus.NO_HOOK : HookStatsStatus.NOT_SUPPORTED;
    }

    function _readTick(IPoolManager manager, PoolId poolId, int24 tick)
        private
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        (liquidityGross, liquidityNet) = manager.getTickLiquidity(poolId, tick);
        if (liquidityGross == 0) revert TickInvariantFailed(poolId, tick);
    }

    function _readPopulatedTick(IPoolManager manager, PoolId poolId, int24 tickSpacing, int16 wordPos, uint8 bit)
        private
        view
        returns (PopulatedTick memory populated)
    {
        int256 tickValue = (int256(wordPos) * 256 + int256(uint256(bit))) * int256(tickSpacing);
        if (tickValue < TickMath.minUsableTick(tickSpacing) || tickValue > TickMath.maxUsableTick(tickSpacing)) {
            revert TickInvariantFailed(poolId, tickValue);
        }
        populated.tick = int24(tickValue);
        (populated.liquidityGross, populated.liquidityNet) = _readTick(manager, poolId, populated.tick);
    }

    function _readHookStats(PoolTVL memory result, PoolKey calldata key, address suppliedProvider) private view {
        address hook = address(key.hooks);
        if (hook == address(0)) {
            result.statsStatus = HookStatsStatus.NO_HOOK;
            return;
        }

        address provider = suppliedProvider == address(0) ? hook : suppliedProvider;
        result.statsProvider = provider;

        // gas 不足的 ERC165 探测或统计调用，其失败方式与提供者（provider）自身故障无法区分，因此
        // 报告的状态将取决于调用者的 gas 预算而非链上状态。预先检查整个探测序列所需的
        // gas 余量，不足时降级为 INSUFFICIENT_GAS；此时 core 字段已经填充完毕。
        if (gasleft() < HOOK_STATS_GAS_BUDGET) {
            result.statsStatus = HookStatsStatus.INSUFFICIENT_GAS;
            return;
        }

        if (!ERC165Checker.supportsInterface(provider, type(IHookStats).interfaceId)) {
            result.statsStatus = provider == hook ? HookStatsStatus.NOT_SUPPORTED : HookStatsStatus.INVALID_PROVIDER;
            return;
        }

        (StaticCallStatus hookStatus, bytes32 hookWord,) =
            _boundedStaticcall(provider, abi.encodeCall(IHookStats.hook, ()), 32);
        if (hookStatus != StaticCallStatus.SUCCESS) {
            result.statsStatus = _hookFailureStatus(hookStatus);
            return;
        }
        uint256 reportedHook = uint256(hookWord);
        if (reportedHook > type(uint160).max || address(uint160(reportedHook)) != hook) {
            result.statsStatus = HookStatsStatus.INVALID_PROVIDER;
            return;
        }

        (StaticCallStatus reservesStatus, bytes32 reserves0, bytes32 reserves1) =
            _boundedStaticcall(provider, abi.encodeCall(IHookStats.getReserves, (key)), 64);
        if (reservesStatus != StaticCallStatus.SUCCESS) {
            result.statsStatus = _hookFailureStatus(reservesStatus);
            return;
        }

        (StaticCallStatus effectiveStatus, bytes32 effective0, bytes32 effective1) =
            _boundedStaticcall(provider, abi.encodeCall(IHookStats.getEffectiveLiquidity, (key)), 64);
        if (effectiveStatus != StaticCallStatus.SUCCESS) {
            result.statsStatus = _hookFailureStatus(effectiveStatus);
            return;
        }

        result.hookReserves0 = uint256(reserves0);
        result.hookReserves1 = uint256(reserves1);
        result.hookEffective0 = uint256(effective0);
        result.hookEffective1 = uint256(effective1);
        if (result.hookEffective0 > result.hookReserves0 || result.hookEffective1 > result.hookReserves1) {
            result.hookReserves0 = 0;
            result.hookReserves1 = 0;
            result.hookEffective0 = 0;
            result.hookEffective1 = 0;
            result.statsStatus = HookStatsStatus.INVALID_RESPONSE;
            return;
        }

        result.statsStatus = provider == hook ? HookStatsStatus.DIRECT : HookStatsStatus.EXTERNAL;
    }

    function _hookFailureStatus(StaticCallStatus status) private pure returns (HookStatsStatus) {
        if (status == StaticCallStatus.INSUFFICIENT_GAS) return HookStatsStatus.INSUFFICIENT_GAS;
        return status == StaticCallStatus.FAILED ? HookStatsStatus.CALL_FAILED : HookStatsStatus.INVALID_RESPONSE;
    }

    /// @dev 将对不受信任提供者的调用限制在 HOOK_STATS_GAS_LIMIT 以内，使恶意提供者无法耗尽
    ///      调用者的全部预算。EIP-150 最多转发剩余 gas 的 63/64，因此只有在剩余 gas 足够时，
    ///      所请求的上限才会被满足。HOOK_STATS_GAS_BUDGET 会在探测序列开始前作为
    ///      快速路径进行检查，但从该检查到最后一次统计调用之间的内存扩展开销会随空闲内存
    ///      指针增长（大规模扫描或批量查询后内存按二次方计价），因此任何常量开销估计都无法
    ///      得到保证。因此 gas 不足的调用会降级为 INSUFFICIENT_GAS 状态，而不是回滚（revert）掉
    ///      调用者已完成的 core 扫描，并且绝不会被误判为 CALL_FAILED。
    function _boundedStaticcall(address target, bytes memory input, uint256 expectedSize)
        private
        view
        returns (StaticCallStatus status, bytes32 word0, bytes32 word1)
    {
        if (gasleft() < (HOOK_STATS_GAS_LIMIT * 64) / 63 + 1_000) {
            return (StaticCallStatus.INSUFFICIENT_GAS, bytes32(0), bytes32(0));
        }

        bool success;
        uint256 returnSize;
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            success := staticcall(HOOK_STATS_GAS_LIMIT, target, add(input, 0x20), mload(input), output, 0x40)
            returnSize := returndatasize()
            word0 := mload(output)
            word1 := mload(add(output, 0x20))
        }
        if (!success) return (StaticCallStatus.FAILED, bytes32(0), bytes32(0));
        if (returnSize != expectedSize) return (StaticCallStatus.INVALID_RESPONSE, bytes32(0), bytes32(0));
        return (StaticCallStatus.SUCCESS, word0, word1);
    }

    function _contextHash(IPoolManager manager, PoolId poolId) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(manager), PoolId.unwrap(poolId)));
    }

    /// @dev 将恢复的游标中的快照字段锚定到 manager 的实时状态。扫描位置和数量
    ///      累加字段本质上只能信任调用者（只有重新扫描才能验证它们），但价格、tick
    ///      和活跃流动性的重读成本很低，因此恢复后的分页绝不会返回伪造的快照元数据，
    ///      同一区块内的状态漂移（例如针对 pending 标签求值的分页）也会在此处显式失败，而不会
    ///      表现为归咎于该池的下游不变量错误。
    function _verifyCursorSnapshot(IPoolManager manager, PoolId poolId, ScanState memory state) private view {
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(poolId);
        if (
            sqrtPriceX96 != state.sqrtPriceX96 || currentTick != state.currentTick
                || manager.getLiquidity(poolId) != state.activeLiquidity
        ) revert CursorStateMismatch();
    }

    /// @dev pools[poolId].tickBitmap[wordPos] 的原始存储槽，供 _scanComplete 中的批量 extsload 使用；单个 word 的
    ///      读取则改用 StateLibrary 的 getter 函数
    function _tickBitmapSlot(PoolId poolId, int16 wordPos) private pure returns (bytes32) {
        bytes32 mappingSlot = bytes32(uint256(StateLibrary._getPoolStateSlot(poolId)) + StateLibrary.TICK_BITMAP_OFFSET);
        return keccak256(abi.encodePacked(int256(wordPos), mappingSlot));
    }
}
