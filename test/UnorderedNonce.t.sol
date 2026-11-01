// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UnorderedNonce, IUnorderedNonce} from "../src/base/UnorderedNonce.sol";
import {MockUnorderedNonce} from "./mocks/MockUnorderedNonce.sol";

contract UnorderedNonceTest is Test {
    MockUnorderedNonce unorderedNonce;

    function setUp() public {
        unorderedNonce = new MockUnorderedNonce();
    }

    function testLowNonces() public {
        unorderedNonce.spendNonce(address(this), 5);
        unorderedNonce.spendNonce(address(this), 0);
        unorderedNonce.spendNonce(address(this), 1);

        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 1);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 5);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 0);
        unorderedNonce.spendNonce(address(this), 4);
    }

    function testNonceWordBoundary() public {
        unorderedNonce.spendNonce(address(this), 255);
        unorderedNonce.spendNonce(address(this), 256);

        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 255);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 256);
    }

    function testHighNonces() public {
        unorderedNonce.spendNonce(address(this), 2 ** 240);
        unorderedNonce.spendNonce(address(this), 2 ** 240 + 1);

        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 2 ** 240);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 2 ** 240 + 1);

        unorderedNonce.spendNonce(address(this), 2 ** 240 + 2);
    }

    function testInvalidateFullWord() public {
        unorderedNonce.batchSpendNonces(0, 2 ** 256 - 1);

        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 0);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 1);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 254);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 255);
        unorderedNonce.spendNonce(address(this), 256);
    }

    function testInvalidateNonzeroWord() public {
        unorderedNonce.batchSpendNonces(1, 2 ** 256 - 1);

        unorderedNonce.spendNonce(address(this), 0);
        unorderedNonce.spendNonce(address(this), 254);
        unorderedNonce.spendNonce(address(this), 255);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 256);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 511);
        unorderedNonce.spendNonce(address(this), 512);
    }

    function test_fuzz_InvalidateNonzeroWord(uint256 word, uint256 nonce) public {
        word = bound(word, 0, 1000e18);
        // 用掉一整个 word
        // word = 0，位 [0, 256)
        // word = 1，位 [256, 512)
        // word = 2，位 [512, 768)，以此类推
        unorderedNonce.batchSpendNonces(word, 2 ** 256 - 1);

        // 将 nonce 限定在 0 到该 word 之后 256 位的范围内
        nonce = bound(nonce, 0, (word + 2) * 256);

        if ((word * 256) <= nonce && nonce < ((word + 1) * 256)) {
            vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        }
        unorderedNonce.spendNonce(address(this), nonce);
    }

    function test_fuzz_UsingNonceTwiceFails(uint256 nonce) public {
        unorderedNonce.spendNonce(address(this), nonce);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), nonce);
    }

    function test_fuzz_UseTwoRandomNonces(uint256 first, uint256 second) public {
        unorderedNonce.spendNonce(address(this), first);
        if (first == second) {
            vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
            unorderedNonce.spendNonce(address(this), second);
        } else {
            unorderedNonce.spendNonce(address(this), second);
        }
    }

    function test_fuzz_revokeNonce(uint256 nonce) public {
        unorderedNonce.revokeNonce(nonce);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.revokeNonce(nonce);
    }

    function test_fuzz_revokeNonce_twoNonces(uint256 first, uint256 second) public {
        unorderedNonce.revokeNonce(first);
        if (first == second) vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.revokeNonce(second);
    }
}
