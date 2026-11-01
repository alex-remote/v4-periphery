// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockMulticall, RevertContract} from "./mocks/MockMulticall.sol";

contract MulticallTest is Test {
    MockMulticall multicall;

    function setUp() public {
        multicall = new MockMulticall();
    }

    function test_multicall() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 10, 20);
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 1, 2);

        bytes[] memory results = multicall.multicall(calls);

        (uint256 a, uint256 b) = abi.decode(results[0], (uint256, uint256));
        assertEq(a, 10);
        assertEq(b, 20);

        (a, b) = abi.decode(results[1], (uint256, uint256));
        assertEq(a, 1);
        assertEq(b, 2);
    }

    function test_multicall_firstRevert() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            MockMulticall(multicall).functionThatRevertsWithString.selector, "First call failed"
        );
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 1, 2);

        vm.expectRevert("First call failed");
        multicall.multicall(calls);
    }

    function test_multicall_secondRevert() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 1, 2);
        calls[1] = abi.encodeWithSelector(
            MockMulticall(multicall).functionThatRevertsWithString.selector, "Second call failed"
        );

        vm.expectRevert("Second call failed");
        multicall.multicall(calls);
    }

    function test_multicall_payableStoresMsgValue() public {
        assertEq(address(multicall).balance, 0);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).payableStoresMsgValue.selector);
        multicall.multicall{value: 100}(calls);
        assertEq(address(multicall).balance, 100);
        assertEq(multicall.msgValue(), 100);
    }

    function test_multicall_returnSender() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).returnSender.selector);
        bytes[] memory results = multicall.multicall(calls);
        address sender = abi.decode(results[0], (address));
        assertEq(sender, address(this));
    }

    function test_multicall_returnSender_prank() public {
        address alice = makeAddr("ALICE");

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).returnSender.selector, alice);
        vm.prank(alice);
        bytes[] memory results = multicall.multicall(calls);
        address sender = abi.decode(results[0], (address));
        assertEq(sender, alice);
    }

    function test_multicall_double_send() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).payableStoresMsgValue.selector);
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).payableStoresMsgValue.selector);

        multicall.multicall{value: 100}(calls);
        assertEq(address(multicall).balance, 100);
        assertEq(multicall.msgValue(), 100);
    }

    function test_multicall_unpayableRevert() public {
        // 第一个调用是 payable 的，第二个不是，因而会导致回滚（revert）
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).payableStoresMsgValue.selector);
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 10, 20);

        vm.expectRevert();
        multicall.multicall{value: 100}(calls);
    }

    function test_multicall_bothPayable() public {
        // msg.value 会同时提供给两个调用
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).payableStoresMsgValue.selector);
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).payableStoresMsgValueDouble.selector);

        multicall.multicall{value: 100}(calls);
        assertEq(address(multicall).balance, 100);
        assertEq(multicall.msgValue(), 100);
        assertEq(multicall.msgValueDouble(), 200);
    }

    // 回滚（revert）冒泡
    function test_multicall_bubbleRevert_string() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] =
            abi.encodeWithSelector(MockMulticall(multicall).functionThatRevertsWithString.selector, "errorString");

        vm.expectRevert("errorString");
        multicall.multicall(calls);
    }

    function test_multicall_bubbleRevert_4bytes() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).revertWith4Bytes.selector);

        // 回滚（revert）被捕获
        vm.expectRevert(MockMulticall.Error4Bytes.selector);
        multicall.multicall(calls);

        // 确认回滚数据的预期长度
        try multicall.revertWith4Bytes() {}
        catch (bytes memory reason) {
            assertEq(reason.length, 4);
        }
    }

    function test_fuzz_multicall_bubbleRevert_36bytes(uint8 num) public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).revertWith36Bytes.selector, num);

        // 回滚（revert）被捕获
        vm.expectRevert(abi.encodeWithSelector(MockMulticall.Error36Bytes.selector, num));
        multicall.multicall(calls);

        // 确认回滚数据的预期长度
        try multicall.revertWith36Bytes(num) {}
        catch (bytes memory reason) {
            assertEq(reason.length, 36);
        }
    }

    function test_fuzz_multicall_bubbleRevert_68bytes(uint256 a, uint256 b) public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).revertWith68Bytes.selector, a, b);

        // 回滚（revert）被捕获
        vm.expectRevert(abi.encodeWithSelector(MockMulticall.Error68Bytes.selector, a, b));
        multicall.multicall(calls);

        // 确认回滚数据的预期长度
        try multicall.revertWith68Bytes(a, b) {}
        catch (bytes memory reason) {
            assertEq(reason.length, 68);
        }
    }

    function test_fuzz_multicall_bubbleRevert_arbitraryBytes(uint16 length) public {
        length = uint16(bound(length, 0, 4096));
        bytes memory data = new bytes(length);
        for (uint256 i = 0; i < data.length; i++) {
            data[i] = bytes1(uint8(i));
        }

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).revertWithBytes.selector, data);

        // 回滚（revert）被捕获
        vm.expectRevert(abi.encodeWithSelector(MockMulticall.ErrorBytes.selector, data));
        multicall.multicall(calls);

        // 确认回滚数据的预期长度
        try multicall.revertWithBytes(data) {}
        catch (bytes memory reason) {
            // 0 字节的错误默认包含 64 字节数据（长度和指针？）+ 4 字节选择器
            if (length == 0) {
                assertEq(reason.length, 68);
            } else {
                uint256 expectedLength = 64 + 4; // 默认长度 + 选择器
                // 每 32 字节数据会使 reason 增加 32 字节
                expectedLength += (((data.length - 1) / 32) + 1) * 32;
                assertEq(reason.length, expectedLength);
            }
        }
    }

    function test_multicall_bubbleRevert_externalRevertString() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).externalRevertString.selector, "errorString");

        vm.expectRevert("errorString");
        multicall.multicall(calls);
    }

    function test_multicall_bubbleRevert_externalRevertSimple() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).externalRevertError1.selector);

        vm.expectRevert(RevertContract.Error1.selector);
        multicall.multicall(calls);
    }

    function test_multicall_bubbleRevert_externalRevertWithParams(uint256 a, uint256 b) public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).externalRevertError2.selector, a, b);

        vm.expectRevert(abi.encodeWithSelector(RevertContract.Error2.selector, a, b));
        multicall.multicall(calls);
    }
}
