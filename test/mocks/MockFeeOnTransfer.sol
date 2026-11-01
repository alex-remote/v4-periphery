// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {BipsLibrary} from "../../src/libraries/BipsLibrary.sol";

contract MockFOT is MockERC20 {
    using BipsLibrary for uint256;

    IPositionManager immutable posm;

    uint256 public bips;

    constructor(IPositionManager _posm) MockERC20("FOT Token", "FOT", 18) {
        posm = _posm;
    }

    function setFee(uint256 amountInBips) public {
        bips = amountInBips;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // 对接收者收取 bips% 的手续费
        uint256 amountAfterFee = amount - amount.calculatePortion(bips);

        // 不会溢出，因为所有用户的
        // 余额之和不可能超过 uint256 的最大值。
        unchecked {
            balanceOf[to] += amountAfterFee;
        }

        emit Transfer(from, to, amount);

        return true;
    }
}
