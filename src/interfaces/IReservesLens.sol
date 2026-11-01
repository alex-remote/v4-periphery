// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ReservesLens 接口
/// @notice 计算 v4 池的聚合核心流动性曲线所代表的代币数量
/// @dev 核心数量是当前价格下的流动性本金，不包括未收取的 LP 手续费、协议费、
///      捐赠（donation）以及由 hook 管理的资产。hook 上报的储备与有效流动性会单独返回，
///      不得视为由核心推导出的值。当结果需要存储或跨时间比较时，
///      调用应使用显式的 RPC 区块标签（block tag）。
interface IReservesLens {
    /// @notice 可选的 URC-3 hook 统计数据的状态
    /// @dev DIRECT 表示解析得到的提供者就是 hook 本身（无论是由 address(0) 解析而来还是显式
    ///      传入）；EXTERNAL 表示一个独立的第三方提供者。INSUFFICIENT_GAS 表示未尝试探测或统计调用，
    ///      因为在经过 EIP-150 的 63/64 削减后，剩余 gas 无法保证其所需的 gas 配额（stipend）
    ///      （会在开始时检查一次，并在每次统计调用前再次检查，因为内存扩展开销会随调用帧中
    ///      先前的工作量增长）；核心字段仍然有效，调用者可以提供更多 gas 重试。
    enum HookStatsStatus {
        NO_HOOK,
        NOT_SUPPORTED,
        DIRECT,
        EXTERNAL,
        INVALID_PROVIDER,
        CALL_FAILED,
        INVALID_RESPONSE,
        INSUFFICIENT_GAS
    }

    /// @notice 完整的池流动性 TVL 快照
    struct PoolTVL {
        /// @notice 由 PoolManager 流动性状态推导出的、不含手续费的 token0 本金
        uint256 coreAmount0;
        /// @notice 由 PoolManager 流动性状态推导出的、不含手续费的 token1 本金
        uint256 coreAmount1;
        /// @notice hook 上报的 token0 管理资产；仅在 DIRECT 或 EXTERNAL 状态下有意义
        uint256 hookReserves0;
        /// @notice hook 上报的 token1 管理资产；仅在 DIRECT 或 EXTERNAL 状态下有意义
        uint256 hookReserves1;
        /// @notice hook 上报的、可立即用于兑换（swap）的 token0 流动性
        uint256 hookEffective0;
        /// @notice hook 上报的、可立即用于兑换（swap）的 token1 流动性
        uint256 hookEffective1;
        /// @notice 用于核心计算的池 sqrt 价格
        uint160 sqrtPriceX96;
        /// @notice 用于核心计算的池 tick
        int24 tick;
        /// @notice PoolManager 存储的活跃核心流动性
        uint128 activeLiquidity;
        /// @notice 评估此快照时所在的区块号
        uint256 blockNumber;
        /// @notice 被查询 hook 统计数据的 URC-3 提供者（如有）
        address statsProvider;
        /// @notice 从 hook 地址解码出的十四个 v4 权限位
        uint16 hookPermissions;
        /// @notice 是否有任一 return-delta 权限位允许自定义记账
        bool hasCustomAccounting;
        /// @notice hook 上报字段的可用性与来源
        HookStatsStatus statsStatus;
    }

    /// @notice 与 v3 TickLens 字段布局兼容的已初始化 tick 数据
    struct PopulatedTick {
        int24 tick;
        int128 liquidityNet;
        uint128 liquidityGross;
    }

    /// @notice 当所提供的 key 所标识的池未初始化时抛出
    error PoolNotInitialized(PoolId poolId);

    /// @notice 当 tick 间距超出 v4-core 的范围时抛出
    error InvalidTickSpacing(int24 tickSpacing);

    /// @notice 当分页调用的工作量预算超出支持范围时抛出
    error InvalidScanBudget(uint32 maxReads);

    /// @notice 当所提供的 manager 对批量 extsload 返回格式错误的响应时抛出
    error ManagerBatchReadFailed(address manager, bytes32 firstSlot, bytes32 lastSlot, uint256 count);

    /// @notice 当重建出的流动性与 PoolManager 状态不一致时抛出
    error LiquidityInvariantFailed(PoolId poolId);

    /// @notice 当已初始化的 tick 与其 bitmap 条目或池边界不一致时抛出
    error TickInvariantFailed(PoolId poolId, int256 tick);

    /// @notice 当续传游标（continuation cursor）的编码无效时抛出
    error InvalidCursor();

    /// @notice 当续传游标的版本不受支持时抛出
    error UnsupportedCursorVersion(uint8 version);

    /// @notice 当游标被用于不同的链、manager 或池时抛出
    error CursorContextMismatch();

    /// @notice 当各页在不同区块上评估时抛出
    error CursorBlockMismatch(uint256 expected, uint256 actual);

    /// @notice 当恢复所用游标中的价格、tick 或活跃流动性与 manager 的实时状态不匹配时抛出
    /// @dev 用于捕获伪造的快照字段以及同一区块内的状态漂移（例如各页基于 pending 标签评估）
    error CursorStateMismatch();

    /// @notice 当并行的批量输入长度不一致时抛出
    error InputLengthMismatch();

    /// @notice 在一次调用中计算完整的池快照，并探测池的 hook 以获取 URC-3 统计数据
    /// @dev getPoolTVL(manager, key, address(0)) 的便捷形式；gas 相关注意事项见该重载
    /// @param manager 被读取状态的 PoolManager。调用者负责选择规范的（canonical）manager。
    /// @param key 由 PoolManager.Initialize 发出的完整池 key
    /// @return result 不含手续费的核心数量，以及单独标注的可选 hook 统计数据
    function getPoolTVL(IPoolManager manager, PoolKey calldata key) external view returns (PoolTVL memory result);

    /// @notice 在一次调用中计算完整的池快照
    /// @dev 会扫描完整的已初始化 tick 域。对于 tick 间距为 1 的池，即使池为空，仅 bitmap 字的读取
    ///      就需约 32M gas，超过了 30M 的区块级 gas 上限（尽管大多数提供商对 eth_call 的上限
    ///      更高，例如 geth 默认为 50M）；对于较小的 tick 间距或模拟 gas 上限较低的提供商，
    ///      请使用 getPoolTVLPaged。
    /// @param manager 被读取状态的 PoolManager。调用者负责选择规范的（canonical）manager。
    /// @param key 由 PoolManager.Initialize 发出的完整池 key
    /// @param statsProvider 可选的外部 URC-3 提供者，或传 address(0) 以直接探测 hook
    /// @return result 不含手续费的核心数量，以及单独标注的可选 hook 统计数据
    function getPoolTVL(IPoolManager manager, PoolKey calldata key, address statsProvider)
        external
        view
        returns (PoolTVL memory result);

    /// @notice 计算多个池的完整快照，并探测每个池的 hook 以获取 URC-3 统计数据
    /// @dev 等同于所有提供者均为零地址时的 getPoolTVLBatch(manager, keys, statsProviders) 的便捷形式
    /// @param manager 被读取状态的 PoolManager
    /// @param keys 完整的池 key 列表
    function getPoolTVLBatch(IPoolManager manager, PoolKey[] calldata keys)
        external
        view
        returns (PoolTVL[] memory results);

    /// @notice 计算同一个 PoolManager 上多个池的完整快照
    /// @dev 单个开销过高的池会使整个批次回滚（revert）。对于大型或不可信的批次，建议改用独立的 RPC 调用。
    /// @param manager 被读取状态的 PoolManager
    /// @param keys 完整的池 key 列表
    /// @param statsProviders 每个 key 对应一个可选的 URC-3 提供者；使用 address(0) 以直接探测各个 hook
    function getPoolTVLBatch(IPoolManager manager, PoolKey[] calldata keys, address[] calldata statsProviders)
        external
        view
        returns (PoolTVL[] memory results);

    /// @notice 返回一个压缩 bitmap 字中的所有已初始化 tick
    /// @dev 字段布局与 v3 TickLens 一致，并适配 v4 的 PoolManager 与 PoolKey。
    function getPopulatedTicksInWord(IPoolManager manager, PoolKey calldata key, int16 wordPos)
        external
        view
        returns (PopulatedTick[] memory populatedTicks);

    /// @notice 使用默认分页预算计算池快照的有界部分，并探测池的 hook
    /// @dev getPoolTVLPaged(manager, key, address(0), cursor, 0) 的便捷形式；游标处理要求见该
    ///      重载
    /// @param manager 被读取状态的 PoolManager
    /// @param key 由 PoolManager.Initialize 发出的完整池 key
    /// @param cursor 传空值表示开始，否则传入上一页返回的原样不透明游标
    function getPoolTVLPaged(IPoolManager manager, PoolKey calldata key, bytes calldata cursor)
        external
        view
        returns (PoolTVL memory result, bytes memory nextCursor, bool done);

    /// @notice 计算池快照的有界部分
    /// @dev 传入空游标以开始，并将返回的游标原样传回。所有页必须使用相同的显式区块
    ///      标签。中间结果不完整，不得视为 TVL。此无状态合约无法认证游标的来源，
    ///      因此分页功能面向链下调用者。恢复时会将游标中的
    ///      价格、tick 和活跃流动性字段与 manager 的实时状态核对，但扫描
    ///      位置和数量累加器会被原样信任：调用者自行构造的游标只会给该调用者自己
    ///      产生无意义的结果。切勿将基于第三方游标恢复得到的结果视为可信。
    /// @param manager 被读取状态的 PoolManager
    /// @param key 由 PoolManager.Initialize 发出的完整池 key
    /// @param statsProvider 可选的外部 URC-3 提供者，或传 address(0) 以直接探测 hook
    /// @param cursor 传空值表示开始，否则传入上一页返回的原样不透明游标
    /// @param maxReads 本页 bitmap/tick 存储读取工作量的近似预算；传 0 表示选择默认预算，
    ///                 即 512 次读取（每页约 2M gas）
    /// @return result 仅当 done 为 true 时才是完整的
    /// @return nextCursor 不透明的续传游标，done 为 true 时为空
    /// @return done 是否已生成完整结果
    function getPoolTVLPaged(
        IPoolManager manager,
        PoolKey calldata key,
        address statsProvider,
        bytes calldata cursor,
        uint32 maxReads
    ) external view returns (PoolTVL memory result, bytes memory nextCursor, bool done);
}
