// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice 定义各种池操作（action）的库。
/// @dev 这些是建议的常用命令，如有需要应另行定义其它命令
/// 其中部分操作（action）在路由器合约或 Position Manager 合约中不受支持，但仍予以保留，因为它们可能对其它外围合约有用。
library Actions {
    // 池操作
    // 流动性操作
    uint256 internal constant INCREASE_LIQUIDITY = 0x00;
    uint256 internal constant DECREASE_LIQUIDITY = 0x01;
    uint256 internal constant MINT_POSITION = 0x02;
    uint256 internal constant BURN_POSITION = 0x03;

    /// @notice DEPRECATED（已弃用）：易受三明治攻击——请勿使用。
    /// @dev 这种基于 delta 的方式缺少针对最小流动性的滑点保护，使得
    /// 攻击者能够操纵价格并减少所获得的流动性。
    /// 请改用 INCREASE_LIQUIDITY。
    uint256 internal constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x04;

    /// @notice DEPRECATED（已弃用）：易受三明治攻击——请勿使用。
    /// @dev 这种基于 delta 的方式缺少针对最小流动性的滑点保护，使得
    /// 攻击者能够操纵价格并减少所获得的流动性。
    /// 请改用 MINT_POSITION。
    uint256 internal constant MINT_POSITION_FROM_DELTAS = 0x05;

    // 兑换（swap）
    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SWAP_EXACT_IN = 0x07;
    uint256 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 internal constant SWAP_EXACT_OUT = 0x09;

    // 捐赠（donate）
    // 注意：PositionManager 和路由器均不支持此操作
    uint256 internal constant DONATE = 0x0a;

    // 结清 PoolManager 上的 delta
    // 结算
    uint256 internal constant SETTLE = 0x0b;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant SETTLE_PAIR = 0x0d;
    // 提取
    uint256 internal constant TAKE = 0x0e;
    uint256 internal constant TAKE_ALL = 0x0f;
    uint256 internal constant TAKE_PORTION = 0x10;
    uint256 internal constant TAKE_PAIR = 0x11;

    uint256 internal constant CLOSE_CURRENCY = 0x12;
    uint256 internal constant CLEAR_OR_TAKE = 0x13;
    uint256 internal constant SWEEP = 0x14;

    uint256 internal constant WRAP = 0x15;
    uint256 internal constant UNWRAP = 0x16;

    // 铸造/销毁 6909 代币以结清 delta
    // 注意：PositionManager 和路由器均不支持此操作
    uint256 internal constant MINT_6909 = 0x17;
    uint256 internal constant BURN_6909 = 0x18;

    // 许可池专用的操作
    // 销毁本合约持有的某代币的 6909 凭证（claim），并将底层代币提取给接收者
    uint256 internal constant UNWIND_WITH_FALLBACK = 0x19;
}
