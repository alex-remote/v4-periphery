// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {IPositionManager, IPoolInitializer_v4} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {IMulticall_v4} from "../../src/interfaces/IMulticall_v4.sol";
import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {Permit2SignatureHelpers} from "../shared/Permit2SignatureHelpers.sol";
import {Permit2Forwarder, IPermit2Forwarder} from "../../src/base/Permit2Forwarder.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {IERC721Permit_v4} from "../../src/interfaces/IERC721Permit_v4.sol";

contract PositionManagerMulticallTest is Test, Permit2SignatureHelpers, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    // bob 用于 permit2 签名测试
    uint256 bobPK;
    address charlie; // charlie 在 setup() 中不会授权 posm
    uint256 charliePK;

    Permit2Forwarder permit2Forwarder;

    uint160 permitAmount = type(uint160).max;
    // 授权额度的过期时间设得很大
    uint48 permitExpiration = uint48(block.timestamp + 10e18);
    uint48 permitNonce = 0;

    // 重新定义 permit2/src/PermitErrors.sol 中的错误，因为该文件被硬性锁定到某个 solidity 版本
    error InvalidNonce();

    bytes32 PERMIT2_DOMAIN_SEPARATOR;

    PositionConfig config;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");
        (charlie, charliePK) = makeAddrAndKey("CHARLIE");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // 要求在基础合约 Deployers 中已设置 currency0 和 currency1。
        deployAndApprovePosm(manager);

        permit2Forwarder = new Permit2Forwarder(permit2);
        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        seedBalance(alice);
        approvePosmFor(alice);

        seedBalance(bob);
        approvePosmFor(bob);

        // 不为 charlie 授权 posm，但为 allowance transfer 授权 permit2
        seedBalance(charlie);
        vm.startPrank(charlie);
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function test_multicall_initializePool_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // 使用 multicall 初始化池并铸造流动性
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, SQRT_PRICE_1_1);

        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(address(lpm)).multicall(calls);

        // 测试兑换（swap），未回滚（revert），说明池已初始化
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    function test_multicall_initializePool_twice_andMint_succeeds() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});
        manager.initialize(key, SQRT_PRICE_1_1);

        // 使用 multicall 再次初始化该池。
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, SQRT_PRICE_1_1);

        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(address(lpm)).multicall(calls);

        // 测试兑换（swap），未回滚（revert），说明即使 initialize 回滚，铸造仍然成功
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    function test_multicall_initializePool_mint_native() public {
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        // 使用 multicall 初始化池并铸造流动性
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, SQRT_PRICE_1_1);

        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ActionConstants.MSG_SENDER, ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(address(lpm)).multicall{value: 1000 ether}(calls);

        // 测试兑换（swap），未回滚（revert），说明池已初始化
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    // charlie 会在未获授权的情况下尝试减少流动性
    // posm 的 NotApproved(charlie) 应通过 Multicall 向上冒泡
    function test_multicall_bubbleRevert() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        // 使用 multicall 减少流动性
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.startPrank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, charlie));
        lpm.multicall(calls);
        vm.stopPrank();
    }

    // 减少流动性但忘记关闭（close）
    // core 的 CurrencyNotSettled 应通过 Multicall 向上冒泡
    function test_multicall_bubbleRevert_core() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        // 不关闭 delta，以便在 core 中抛出 CurrencyNotSettled
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory actions = planner.encode();

        // 使用 multicall 减少流动性
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        lpm.multicall(calls);
    }

    function test_multicall_permitAndDecrease() public {
        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // Alice 授予 Bob 操作其流动性的权限
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // bob 给自己授予权限并减少流动性
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            IERC721Permit_v4(lpm).permit.selector, bob, tokenId, block.timestamp + 1, nonce, signature
        );
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory actions = getDecreaseEncoded(tokenId, config, liquidityToRemove, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    function test_multicall_permit_mint() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        // 1. 撤销我们自动给 posm 的其中一个代币的许可（permit）
        vm.prank(bob);
        permit2.approve(Currency.unwrap(currency0), address(lpm), 0, 0);

        (uint160 _amount,, uint48 _expiration) =
            permit2.allowance(address(bob), Currency.unwrap(currency0), address(this));

        assertEq(_amount, 0);
        assertEq(_expiration, 0);

        uint256 tokenId = lpm.nextTokenId();
        bytes memory mintCall = getMintEncoded(config, 10e18, bob, ZERO_BYTES);

        // 2 . 调用一次铸造，它会回滚（revert），因为 PositionManager 在 permit2 上没有权限
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, 0));
        vm.prank(bob);
        lpm.modifyLiquidities(mintCall, _deadline);

        // 3. 为那个被撤销的代币编码一个许可（permit）
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, mintCall, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        (_amount,,) = permit2.allowance(address(bob), Currency.unwrap(currency0), address(lpm));

        assertEq(_amount, permitAmount);
        assertEq(liquidity, 10e18);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), bob);
    }

    function test_multicall_permit_batch_mint() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        // 1. 撤销我们自动给 posm 的其中一个代币的许可（permit）
        vm.prank(bob);
        permit2.approve(Currency.unwrap(currency0), address(lpm), 0, 0);
        permit2.approve(Currency.unwrap(currency1), address(lpm), 0, 0);

        (uint160 _amount0,, uint48 _expiration0) =
            permit2.allowance(address(bob), Currency.unwrap(currency0), address(this));

        (uint160 _amount1,, uint48 _expiration1) =
            permit2.allowance(address(bob), Currency.unwrap(currency1), address(this));

        assertEq(_amount0, 0);
        assertEq(_expiration0, 0);
        assertEq(_amount1, 0);
        assertEq(_expiration1, 0);

        uint256 tokenId = lpm.nextTokenId();
        bytes memory mintCall = getMintEncoded(config, 10e18, bob, ZERO_BYTES);

        // 2 . 调用一次铸造，它会回滚（revert），因为 PositionManager 在 permit2 上没有权限
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, 0));
        vm.prank(bob);
        lpm.modifyLiquidities(mintCall, _deadline);

        // 3. 为那个被撤销的代币编码一个许可（permit）
        address[] memory tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitBatchSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permitBatch.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, mintCall, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        (_amount0,,) = permit2.allowance(address(bob), Currency.unwrap(currency0), address(lpm));
        (_amount1,,) = permit2.allowance(address(bob), Currency.unwrap(currency1), address(lpm));
        assertEq(_amount0, permitAmount);
        assertEq(_amount1, permitAmount);
        assertEq(liquidity, 10e18);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), bob);
    }

    /// @notice 测试被抢跑（front-run）的 permit 不会导致带 permit 的 multicall 失败
    function test_multicall_permit_frontrun_suceeds() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        // Charlie 为两个代币签署 permit
        IAllowanceTransfer.PermitSingle memory permit0 =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit0.spender = address(lpm);
        bytes memory sig0 = getPermitSignature(permit0, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        IAllowanceTransfer.PermitSingle memory permit1 =
            defaultERC20PermitAllowance(Currency.unwrap(currency1), permitAmount, permitExpiration, permitNonce);
        permit1.spender = address(lpm);
        bytes memory sig1 = getPermitSignature(permit1, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        // bob 抢跑（front-run）这些 permit
        vm.startPrank(bob);
        lpm.permit(charlie, permit0, sig0);
        lpm.permit(charlie, permit1, sig1);
        vm.stopPrank();

        // bob 的抢跑成功了
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, Currency.unwrap(currency0), address(lpm));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);
        (uint160 _amount1, uint48 _expiration1, uint48 _nonce1) =
            permit2.allowance(charlie, Currency.unwrap(currency1), address(lpm));
        assertEq(_amount1, permitAmount);
        assertEq(_expiration1, permitExpiration);
        assertEq(_nonce1, permitNonce + 1);

        // charlie 尝试通过 multicall(permit, permit, mint) 铸造一个 LP 代币
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(IPermit2Forwarder.permit.selector, charlie, permit0, sig0);
        calls[1] = abi.encodeWithSelector(IPermit2Forwarder.permit.selector, charlie, permit1, sig1);
        bytes memory mintCall = getMintEncoded(config, 10e18, charlie, ZERO_BYTES);
        calls[2] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mintCall, _deadline);

        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // 该代币不存在

        bytes[] memory results = lpm.multicall(calls);
        assertEq(results[0], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));
        assertEq(results[1], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), charlie);
    }

    /// @notice 测试被抢跑（front-run）的 permitBatch 不会导致带 permitBatch 的 multicall 失败
    function test_multicall_permitBatch_frontrun_suceeds() public {
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        // Charlie 为两个代币签署 permitBatch
        address[] memory tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitBatchSignature(permit, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        // bob 抢跑（front-run）这些 permit
        vm.prank(bob);
        lpm.permitBatch(charlie, permit, sig);

        // bob 的抢跑成功了
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, Currency.unwrap(currency0), address(lpm));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);
        (uint160 _amount1, uint48 _expiration1, uint48 _nonce1) =
            permit2.allowance(charlie, Currency.unwrap(currency1), address(lpm));
        assertEq(_amount1, permitAmount);
        assertEq(_expiration1, permitExpiration);
        assertEq(_nonce1, permitNonce + 1);

        // charlie 尝试通过 multicall(permitBatch, mint) 铸造一个 LP 代币
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(lpm.permitBatch.selector, charlie, permit, sig);
        bytes memory mintCall = getMintEncoded(config, 10e18, charlie, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mintCall, _deadline);

        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // 该代币不存在

        bytes[] memory results = lpm.multicall(calls);
        assertEq(results[0], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), charlie);
    }
}
