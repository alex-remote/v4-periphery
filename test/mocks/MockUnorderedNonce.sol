// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UnorderedNonce} from "../../src/base/UnorderedNonce.sol";

contract MockUnorderedNonce is UnorderedNonce {
    function spendNonce(address owner, uint256 nonce) external {
        _useUnorderedNonce(owner, nonce);
    }

    /// @dev 在单个字（word）上批量消耗 nonce。仅限测试使用
    function batchSpendNonces(uint256 wordPos, uint256 mask) external {
        nonces[msg.sender][wordPos] |= mask;
    }
}
