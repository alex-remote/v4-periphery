// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {Planner, Plan} from "../../shared/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {PermissionedPositionManagerTest} from "./PermissionedPositionManager.t.sol";
import {MockPermissionedToken, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {PermissionFlags} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {
    IPermissionsAdapter,
    IERC20 as IERC20Adapter
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice 合约钱包形式的 LP，其 receive() 会遗留一个未结清的 PoolManager delta（原生 ETH 重入）。
contract MaliciousNativeLP {
    IPoolManager public immutable manager;
    bool public armed;

    constructor(IPoolManager _m) {
        manager = _m;
    }

    function arm(bool a) external {
        armed = a;
    }

    function exec(address t, uint256 v, bytes calldata d) external returns (bytes memory) {
        (bool ok, bytes memory ret) = t.call{value: v}(d);
        require(ok, "exec");
        return ret;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            manager.mint(address(this), 0, 1); // 仅在已激活（armed）时，于 unlock 过程中遗留一个未结清的全局 delta
        }
    }
}

/// @notice 合约钱包形式的 LP，其 receive() 会耗尽几乎所有转发进来的 gas，然后回滚。
///         原生代币的提取（take）会回滚，因此交付失败会被捕获，LP 改为获得 ETH 的 6909 claim。
contract GasGriefingLP {
    function exec(address t, uint256 v, bytes calldata d) external returns (bytes memory) {
        (bool ok, bytes memory ret) = t.call{value: v}(d);
        require(ok, "exec");
        return ret;
    }

    receive() external payable {
        // 烧掉相当于一整个区块的 gas（实际中单次调用的上限），然后回滚。
        uint256 g = gasleft();
        uint256 target = g > 30_000_000 ? g - 30_000_000 : g / 2;
        while (gasleft() > target) {}
        revert("griefed");
    }
}

/// @notice 由 LP 提供的 ERC20，其 transfer 会重入 PoolManager.mint 以遗留一个未结清的 delta（审计发现备注 1）。
contract MaliciousPairedToken {
    string public name = "MAL";
    string public symbol = "MAL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    IPoolManager public immutable manager;
    bool public armed;

    constructor(IPoolManager _m) {
        manager = _m;
    }

    function arm(bool a) external {
        armed = a;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        return _x(msg.sender, to, a);
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        return _x(f, to, a);
    }

    function _x(address f, address to, uint256 a) internal returns (bool) {
        if (armed) {
            armed = false;
            manager.mint(address(this), 0, 1); // 仅在已激活（armed）时，于 unlock 过程中遗留一个未结清的全局 delta
        }
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice 由 LP 控制的许可代币：它能通过适配器的白名单路径（借助 MockPermissionedToken），
///         但在已激活时会在 transfer 中遗留一个未结清的 PoolManager delta。将其包装进由 LP 管理的已验证 PA，就构成了
///         “恶意 PA”场景：交付过程中适配器解包时会执行该代币的重入式 transfer。
contract MaliciousPermUnderlying is MockPermissionedToken {
    IPoolManager public immutable mgr;
    bool public armed;

    constructor(IPoolManager _m) {
        mgr = _m;
    }

    function arm(bool a) external {
        armed = a;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _grief();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _grief();
        return super.transferFrom(from, to, amount);
    }

    function _grief() internal {
        if (armed) {
            armed = false;
            mgr.mint(address(this), 0, 1); // 仅在已激活（armed）时，于 unlock 过程中遗留一个未结清的全局 delta
        }
    }
}

contract UnwindReentrancyFixedPoC is PermissionedPositionManagerTest {
    using Planner for Plan;

    function _mintPosition(PoolKey memory key, address owner, uint256 ethValue) internal returns (uint256 tokenId) {
        int24 tl = -60;
        int24 tu = 60;
        uint256 liq = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), 1 ether, 1 ether
        );
        Plan memory p = Planner.init();
        p.add(
            Actions.MINT_POSITION, abi.encode(key, tl, tu, liq, type(uint128).max, type(uint128).max, owner, bytes(""))
        );
        p.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        p.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        if (ethValue > 0) p.add(Actions.SWEEP, abi.encode(Currency.wrap(address(0)), owner));
        tokenId = lpm.nextTokenId();
        bytes memory calls = p.encode();
        if (owner.code.length > 0) {
            MaliciousNativeLP(payable(owner))
                .exec(
                    address(lpm),
                    ethValue,
                    abi.encodeWithSelector(lpm.modifyLiquidities.selector, calls, block.timestamp + 1)
                );
        } else {
            vm.prank(owner);
            lpm.modifyLiquidities{value: ethValue}(calls, block.timestamp + 1);
        }
    }

    function _approveAsContract(address who, address token) internal {
        MaliciousNativeLP(payable(who))
            .exec(token, 0, abi.encodeWithSelector(IERC20.approve.selector, address(permit2), type(uint256).max));
        MaliciousNativeLP(payable(who))
            .exec(
                address(permit2),
                0,
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)", token, address(lpm), type(uint160).max, type(uint48).max
                )
            );
    }

    // 1. 原生代币池 + 恶意合约钱包 LP：强制退出成功；LP 获得 ETH 的 6909 claim。
    function test_forceExit_succeeds_vs_native_contract_LP_griefer() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        MaliciousNativeLP lp = new MaliciousNativeLP(manager);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(lp), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(address(lp), 100 ether);
        vm.deal(address(lp), 100 ether);
        _approveAsContract(address(lp), Currency.unwrap(currency0));

        uint256 tokenId = _mintPosition(key, address(lp), 1 ether);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(lp));

        lp.arm(true); // 收到 ETH 时，其 receive() 会尝试遗留一个未结清的 delta
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed despite native reentrancy");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId); // NFT 已销毁 -> LP 被移除
        assertGt(manager.balanceOf(address(lp), 0), 0, "griefer LP was handed an ETH 6909 claim instead of real ETH");
    }

    // 2. LP 将许可代币与其自己的恶意 ERC20 配对：强制退出成功。
    function test_forceExit_succeeds_vs_malicious_paired_token() public {
        MaliciousPairedToken mal = new MaliciousPairedToken(manager);
        (Currency c0, Currency c1) = address(permissionsAdapter0) < address(mal)
            ? (Currency.wrap(address(permissionsAdapter0)), Currency.wrap(address(mal)))
            : (Currency.wrap(address(mal)), Currency.wrap(address(permissionsAdapter0)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: permissionedHooks});
        manager.initialize(key, SQRT_PRICE_1_1);

        MockPermissionedToken(Currency.unwrap(currency0)).mint(alice, 100 ether);
        mal.mint(alice, 100 ether);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        (bool a0,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    Currency.unwrap(currency0),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a0);
        IERC20(address(mal)).approve(address(permit2), type(uint256).max);
        (bool a1,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    address(mal),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a1);
        vm.stopPrank();

        uint256 tokenId = _mintPosition(key, alice, 0);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        mal.arm(true);
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed despite malicious paired token");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
        assertGt(
            manager.balanceOf(alice, Currency.wrap(address(mal)).toId()),
            0,
            "LP handed a claim of their own malicious token"
        );
    }

    // 3. 原生代币池中的良性 EOA LP 收到的是真实 ETH，而不是 claim。
    function test_forceExit_delivers_real_ETH_to_benign_EOA_LP() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.deal(alice, 100 ether);
        uint256 tokenId = _mintPosition(key, alice, 1 ether);

        uint256 ethBefore = alice.balance;
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit should succeed for a benign EOA");
        assertGt(alice.balance, ethBefore, "benign EOA LP received real ETH");
        assertEq(manager.balanceOf(alice, 0), 0, "no ETH claim minted for the benign case");
    }

    /// @notice 构建一个池：将合法的 adapter0 与一个由 LP 创建并管理、包装了
    ///         恶意许可代币的 PA 配对，然后铸造一个归 LP 所有的头寸。`lpm` 被允许
    ///         包装该恶意 PA。返回该头寸以及调用方需要激活或修改的各个组件。
    function _setupMaliciousPaPool()
        internal
        returns (uint256 tokenId, MaliciousPermUnderlying malU, address paEvil, address evilLp)
    {
        evilLp = makeAddr("EVIL_LP");
        MockAllowlistChecker checker = new MockAllowlistChecker();

        // LP 以管理员身份创建并验证一个 PA，该 PA 包装了 LP 自己的恶意许可代币。
        malU = new MaliciousPermUnderlying(manager);
        vm.prank(evilLp);
        paEvil = permissionsAdapterFactory.createPermissionsAdapter(IERC20Adapter(address(malU)), evilLp, checker);

        // 所有会持有/接收 malU 的地址都必须在其代币白名单中（mock 在 !isAllowed[to] 时回滚）。
        malU.setAllowlist(evilLp, PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(paEvil, PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(address(manager), PermissionFlags.ALL_ALLOWED);
        malU.setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);

        malU.mint(paEvil, 1); // 验证要求适配器持有非零余额
        permissionsAdapterFactory.verifyPermissionsAdapter(paEvil);

        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedHook(permissionedHooks, true);
        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedWrapper(address(lpm), true);

        (Currency c0, Currency c1) = address(permissionsAdapter0) < paEvil
            ? (Currency.wrap(address(permissionsAdapter0)), Currency.wrap(paEvil))
            : (Currency.wrap(paEvil), Currency.wrap(address(permissionsAdapter0)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: permissionedHooks});
        manager.initialize(key, SQRT_PRICE_1_1);

        // 为 LP 在合法适配器的底层代币上注资并加入白名单，malU 上同样如此（已在上面处理过）。
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(evilLp, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(evilLp, 100 ether);
        malU.mint(evilLp, 100 ether);

        vm.startPrank(evilLp);
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        (bool a0,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    Currency.unwrap(currency0),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a0);
        IERC20(address(malU)).approve(address(permit2), type(uint256).max);
        (bool a1,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    address(malU),
                    address(lpm),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(a1);
        vm.stopPrank();

        tokenId = _mintPosition(key, evilLp, 0);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), evilLp);
    }

    // 4. LP 将合法 PA 与另一个由其创建并管理、包装了其自有恶意代币的 PA 配对。
    //    交付过程中适配器解包时会执行该恶意代币的逻辑；强制退出仍必须成功。
    function test_forceExit_succeeds_vs_LP_admined_malicious_PA() public {
        (uint256 tokenId, MaliciousPermUnderlying malU,,) = _setupMaliciousPaPool();

        malU.arm(true); // 适配器解包时，其 transfer 会遗留一个未结清的 delta

        // address(this) 是合法 adapter0 的管理员，因此有权执行强制退出。
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed vs an LP-admined malicious PA");
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    // 5. LP 在铸造后将 lpm 从其恶意 PA 的 allowedWrappers 中移除。allowedWrappers 只在
    //    包装方向上检查，因此强制退出（执行的是解包）不受影响，依然成功。
    function test_forceExit_survives_removed_allowedWrappers() public {
        (uint256 tokenId, MaliciousPermUnderlying malU, address paEvil, address evilLp) = _setupMaliciousPaPool();

        // LP 在铸造后从 allowedWrappers 中移除 PermPosm（lpm）。UR 条目也会以同样的方式
        // 被撤销，但此测试基类没有接入 UR，因此撤销 lpm 才是有意义的情形。allowedWrappers 只限制
        // 包装方向，因此这不会让 unwind 卡死。
        vm.prank(evilLp);
        IPermissionsAdapter(paEvil).updateAllowedWrapper(address(lpm), false);

        malU.arm(true);
        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed even after allowedWrappers is revoked (wrap-only gate)");
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    // 6. 原生代币池中的合约钱包 LP，其 receive() 会耗尽几乎所有转发进来的 gas，然后回滚。
    //    原生代币的提取（take）失败会被 try/catch 捕获，LP 改为获得 ETH 的 6909 claim。
    function test_forceExit_survives_gas_griefing_native_LP() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(permissionsAdapter0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        GasGriefingLP lp = new GasGriefingLP();
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(lp), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(address(lp), 100 ether);
        vm.deal(address(lp), 100 ether);
        _approveAsContract(address(lp), Currency.unwrap(currency0));

        uint256 tokenId = _mintPosition(key, address(lp), 1 ether);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(lp));

        (bool ok,) =
            address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId, uint128(0), uint128(0), bytes("")));
        assertTrue(ok, "force-exit must succeed despite a gas-griefing receive()");

        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
        assertGt(manager.balanceOf(address(lp), 0), 0, "gas-griefer LP was handed an ETH 6909 claim");
    }
}
