// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWETH9
interface IWETH9 is IERC20 {
    /// @notice 存入 ether 以换取包装后的 ether
    function deposit() external payable;

    /// @notice 取出包装后的 ether 以换回 ether
    function withdraw(uint256) external;
}
