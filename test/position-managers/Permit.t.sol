// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721Permit_v4} from "../../src/interfaces/IERC721Permit_v4.sol";
import {ERC721Permit_v4} from "../../src/base/ERC721Permit_v4.sol";
import {IUnorderedNonce} from "../../src/interfaces/IUnorderedNonce.sol";

import {PositionConfig} from "../shared/PositionConfig.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";

import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract PermitTest is Test, PosmTestSetup {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    PositionConfig config;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // 要求在基础 Deployers 合约中已设置 currency0 和 currency1。
        deployAndApprovePosm(manager);

        seedBalance(alice);
        seedBalance(bob);

        approvePosmFor(alice);
        approvePosmFor(bob);

        // 定义一个可复用的区间
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_domainSeparator() public view {
        assertEq(
            ERC721Permit_v4(address(lpm)).DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                    keccak256("Uniswap v4 Positions NFT"), // EIP712.sol 中这些存储是 private 的，所以需要硬编码
                    block.chainid,
                    address(lpm)
                )
            )
        );
    }

    function test_permit_increaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        uint256 tokenIdAlice = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);

        // alice 授予 bob 权限
        permit(alicePK, tokenIdAlice, bob, 1);

        // bob 可以为 alice 的 token 增加流动性
        uint256 liquidityToAdd = 0.4444e18;
        vm.startPrank(bob);
        increaseLiquidity(tokenIdAlice, config, liquidityToAdd, ZERO_BYTES);
        vm.stopPrank();

        // alice 的头寸流动性已增加
        uint256 liquidity = lpm.getPositionLiquidity(tokenIdAlice);

        assertEq(liquidity, liquidityAlice + liquidityToAdd);
    }

    function test_permit_decreaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice 授予 bob 操作者权限
        permit(alicePK, tokenIdAlice, bob, 1);

        // bob 可以为 alice 的 token 减少流动性
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenIdAlice, config, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        // alice 的头寸流动性已减少
        uint256 liquidity = lpm.getPositionLiquidity(tokenIdAlice);

        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    function test_permit_collect() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // 捐赠（donate）以产生手续费收入
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // alice 授予 bob 操作者权限
        permit(alicePK, tokenIdAlice, bob, 1);

        // TODO: 测试由获得许可的操作者收取到接收者

        // bob 将手续费收取给自己
        address recipient = bob;
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.startPrank(bob);
        collect(tokenIdAlice, config, ZERO_BYTES);
        vm.stopPrank();

        assertApproxEqAbs(currency0.balanceOf(recipient), balance0BobBefore + currency0Revenue, 1 wei);
        assertApproxEqAbs(currency1.balanceOf(recipient), balance1BobBefore + currency1Revenue, 1 wei);
    }

    // --- 失败场景 --- //
    function test_permit_notOwnerRevert() public {
        // 对非自己所有的 token 调用 permit 会失败

        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob 不能为自己签发 alice 的 token 的许可（permit）
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(bob);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.stopPrank();
    }

    /// @dev 未经授权的调用者不能增加他人的头寸
    function test_noPermit_increaseLiquidityRevert() public {
        // 若所有者未许可（permit），增加流动性会失败
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob 不能为 alice 的 token 增加流动性
        uint256 liquidityToAdd = 0.4444e18;
        bytes memory decrease = getIncreaseEncoded(tokenIdAlice, config, liquidityToAdd, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(decrease, _deadline);
        vm.stopPrank();
    }

    function test_noPermit_decreaseLiquidityRevert() public {
        // 若所有者未许可（permit），decreaseLiquidity 会失败
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob 不能为 alice 的 token 减少流动性
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory decrease = getDecreaseEncoded(tokenIdAlice, config, liquidityToRemove, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(decrease, _deadline);
        vm.stopPrank();
    }

    function test_noPermit_collectRevert() public {
        // 若所有者未许可（permit），collect 会失败
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // 捐赠（donate）以产生手续费收入
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // bob 不能收取手续费
        bytes memory collect = getCollectEncoded(tokenIdAlice, config, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(collect, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @notice 撤销某个 nonce 会使其无法再在 permit() 中使用
    function test_fuzz_noPermit_revokeRevert(uint256 nonce) public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice 撤销该 nonce
        vm.prank(alice);
        lpm.revokeNonce(nonce);

        // alice 授予 bob 被授权者权限
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
    }

    // Bob 可以使用 alice 的签名进行许可（permit）并减少流动性
    function test_permit_operatorSelfPermit() public {
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice 授予 Bob 操作其流动性的权限
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // bob 给自己授予权限
        vm.prank(bob);
        lpm.permit(bob, tokenId, block.timestamp + 1, nonce, signature);

        // bob 可以为 alice 的 token 减少流动性
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenId, config, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    // Charlie 使用 Alice 的签名为 Bob 授予权限
    function test_permit_thirdParty() public {
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice 授予 Bob 操作其流动性的权限
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // charlie 授予 Bob 操作 alice 的 token 的权限
        address charlie = makeAddr("CHARLIE");
        vm.prank(charlie);
        lpm.permit(bob, tokenId, block.timestamp + 1, nonce, signature);

        // bob 可以为 alice 的 token 减少流动性
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenId, config, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }
}
