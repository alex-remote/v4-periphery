// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {ERC721PermitHash} from "../../src/libraries/ERC721PermitHash.sol";
import {MockERC721Permit} from "../mocks/MockERC721Permit.sol";
import {IERC721Permit_v4} from "../../src/interfaces/IERC721Permit_v4.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IUnorderedNonce} from "../../src/interfaces/IUnorderedNonce.sol";

contract ERC721PermitTest is Test {
    MockERC721Permit erc721Permit;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    string constant name = "Mock ERC721Permit_v4";
    string constant symbol = "MOCK721";

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        erc721Permit = new MockERC721Permit(name, symbol);
    }

    // --- 测试重写后的授权（approve）---
    function test_fuzz_approve(address spender) public {
        uint256 tokenId = erc721Permit.mint();
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.Approval(address(this), spender, tokenId);
        erc721Permit.approve(spender, tokenId);
        assertEq(erc721Permit.getApproved(tokenId), spender);
    }

    function test_fuzz_approvedOperator_reapproves(address operator, address spender) public {
        uint256 tokenId = erc721Permit.mint();
        erc721Permit.setApprovalForAll(operator, true);
        assertEq(erc721Permit.isApprovedForAll(address(this), operator), true);

        assertEq(erc721Permit.getApproved(tokenId), address(0));
        vm.startPrank(operator);
        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.Approval(address(this), spender, tokenId);
        erc721Permit.approve(spender, tokenId);
        vm.stopPrank();
        assertEq(erc721Permit.getApproved(tokenId), spender);
    }

    function test_fuzz_approve_unauthorizedRevert(address caller) public {
        uint256 tokenId = erc721Permit.mint();
        vm.prank(caller);
        if (caller != address(this)) vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        erc721Permit.approve(address(this), tokenId);
    }

    // --- 测试基于签名的授权（permit）---
    function test_permitTypeHash() public pure {
        assertEq(
            ERC721PermitHash.PERMIT_TYPEHASH,
            keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)")
        );
    }

    function test_fuzz_permitHash(address spender, uint256 tokenId, uint256 nonce, uint256 deadline) public pure {
        bytes32 expectedHash =
            keccak256(abi.encode(ERC721PermitHash.PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
        assertEq(expectedHash, ERC721PermitHash.hashPermit(spender, tokenId, nonce, deadline));
    }

    function test_domainSeparator() public view {
        assertEq(
            erc721Permit.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    block.chainid,
                    address(erc721Permit)
                )
            )
        );
    }

    /// @dev 被授权者（spender）使用 alice 的签名为自己授权
    function test_fuzz_erc721permit_spender(address spender) public {
        vm.assume(spender != alice);
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        bytes32 digest = _getPermitDigest(spender, tokenId, nonce, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 此前不存在任何授权
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, spender), false);

        // nonce 尚未被使用
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // -- 执行 permit -- //
        vm.startPrank(spender);
        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.Approval(alice, spender, tokenId);
        erc721Permit.permit(spender, tokenId, block.timestamp, nonce, signature);
        vm.stopPrank();

        // 授权已设置
        assertEq(erc721Permit.getApproved(tokenId), spender);
        assertEq(erc721Permit.isApprovedForAll(alice, spender), false);

        // nonce 已被使用
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 2); // 2 = 0010
    }

    /// @dev 第三方调用者使用 alice 的签名向 `spender` 授权
    function test_fuzz_erc721permit_caller(address caller, address spender) public {
        vm.assume(spender != alice);
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        bytes32 digest = _getPermitDigest(spender, tokenId, nonce, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 此前不存在任何授权
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, spender), false);

        // nonce 尚未被使用
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // -- 由第三方调用者执行 permit -- //
        vm.startPrank(caller);
        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.Approval(alice, spender, tokenId);
        erc721Permit.permit(spender, tokenId, block.timestamp, nonce, signature);
        vm.stopPrank();

        // 授权已设置
        assertEq(erc721Permit.getApproved(tokenId), spender);
        assertEq(erc721Permit.isApprovedForAll(alice, spender), false);

        // nonce 已被使用
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 2); // 2 = 0010
    }

    function test_fuzz_erc721permit_nonceAlreadyUsed() public {
        vm.prank(alice);
        uint256 tokenIdAlice = erc721Permit.mint();

        // alice 授予 bob 操作者权限
        uint256 nonce = 1;
        _permit(alicePK, tokenIdAlice, bob, nonce);

        // alice 不能重复使用该 nonce
        bytes32 digest = _getPermitDigest(bob, tokenIdAlice, nonce, block.timestamp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(alice);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        erc721Permit.permit(bob, tokenIdAlice, block.timestamp, nonce, signature);
        vm.stopPrank();
    }

    function test_fuzz_erc721permit_nonceAlreadyUsed_twoPositions() public {
        vm.prank(alice);
        uint256 tokenIdAlice = erc721Permit.mint();

        vm.prank(alice);
        uint256 tokenIdAlice2 = erc721Permit.mint();

        // alice 为第一个 token 授予 bob 操作者权限
        uint256 nonce = 1;
        _permit(alicePK, tokenIdAlice, bob, nonce);

        // alice 不能将该 nonce 重复用于第二个 token
        bytes32 digest = _getPermitDigest(bob, tokenIdAlice2, nonce, block.timestamp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(alice);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        erc721Permit.permit(bob, tokenIdAlice2, block.timestamp, nonce, signature);
        vm.stopPrank();
    }

    function test_fuzz_erc721permit_unauthorized() public {
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        bytes32 digest = _getPermitDigest(bob, tokenId, nonce, block.timestamp);

        // bob 尝试为自己签署授权
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 授权未设置
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, bob), false);

        // nonce 尚未被使用
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        vm.startPrank(bob);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        erc721Permit.permit(bob, tokenId, block.timestamp, nonce, signature);
        vm.stopPrank();

        // 授权未设置
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, bob), false);

        // nonce 尚未被使用
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);
    }

    function test_fuzz_erc721Permit_SignatureDeadlineExpired(address spender) public {
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        uint256 deadline = vm.getBlockTimestamp();
        bytes32 digest = _getPermitDigest(spender, tokenId, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 此前不存在任何授权
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, spender), false);

        // nonce 尚未被使用
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // 时间快进以超过截止时间
        skip(1);

        // -- 执行 permit，但截止时间已过 -- //
        vm.startPrank(spender);
        vm.expectRevert(IERC721Permit_v4.SignatureDeadlineExpired.selector);
        erc721Permit.permit(spender, tokenId, deadline, nonce, signature);
        vm.stopPrank();

        // 授权未设置
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, spender), false);

        // nonce 尚未被使用
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);
    }

    // 与 permit 相关的辅助函数
    function _permit(uint256 privateKey, uint256 tokenId, address operator, uint256 nonce) internal {
        bytes32 digest = _getPermitDigest(operator, tokenId, nonce, block.timestamp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(operator);
        erc721Permit.permit(operator, tokenId, block.timestamp, nonce, signature);
    }

    function _getPermitDigest(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                erc721Permit.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(ERC721PermitHash.PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
    }

    // 复制自 UnorderedNonce.sol 中的 private 函数
    function _getBitmapFromNonce(uint256 nonce) private pure returns (uint256 wordPos, uint256 bitPos) {
        wordPos = uint248(nonce >> 8);
        bitPos = uint8(nonce);
    }
}
