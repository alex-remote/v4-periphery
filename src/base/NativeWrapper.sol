// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title 原生代币包装器（Native Wrapper）
/// @notice 用于包装和解包原生代币
abstract contract NativeWrapper is ImmutableState {
    /// @notice WETH9 的地址
    IWETH9 public immutable WETH9;

    /// @notice 当非预期的地址向本合约发送 ETH 时抛出
    error InvalidEthSender();

    constructor(IWETH9 _weth9) {
        WETH9 = _weth9;
    }

    /// @dev 调用前数量应已确保 <= 本合约当前的余额。
    function _wrap(uint256 amount) internal {
        if (amount > 0) WETH9.deposit{value: amount}();
    }

    /// @dev 调用前数量应已确保 <= 本合约当前的余额。
    function _unwrap(uint256 amount) internal {
        if (amount > 0) WETH9.withdraw(amount);
    }

    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }
}
