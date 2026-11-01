// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    IPermissionsAdapter,
    IAllowlistChecker
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PermissionedPoolsBase, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";

contract PermissionsAdapterTest is PermissionedPoolsBase {
    IPermissionsAdapter public permissionsAdapter;
    address public mockPoolManager;
    address public owner;

    function setUp() public override {
        super.setUp();
        mockPoolManager = makeAddr("mockPoolManager");
        owner = makeAddr("owner");
        bytes memory args = abi.encode(permissionedToken, mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        assembly {
            sstore(permissionsAdapter.slot, create(0, add(initcode, 0x20), mload(initcode)))
        }
        permissionedToken.setTokenAllowlist(address(permissionsAdapter), true);
        vm.prank(owner);
        permissionsAdapter.updateAllowedWrapper(address(this), true);
    }

    function test_InitialState() public view {
        assertEq(IERC20Metadata(address(permissionsAdapter)).name(), "Uniswap v4 MockToken");
        assertEq(IERC20Metadata(address(permissionsAdapter)).symbol(), "v4MT");
        assertEq(IERC20Metadata(address(permissionsAdapter)).decimals(), permissionedToken.decimals());
        assertEq(permissionsAdapter.totalSupply(), 0);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), 0);
        assertEq(address(permissionsAdapter.allowListChecker()), address(allowlistChecker));
        assertEq(permissionsAdapter.POOL_MANAGER(), mockPoolManager);
        assertEq(address(permissionsAdapter.PERMISSIONED_TOKEN()), address(permissionedToken));
    }

    function testRevert_WhenNotOwner(address account, IHooks hooks) public {
        vm.assume(account != owner);
        vm.startPrank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateAllowedWrapper(account, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateAllowListChecker(allowlistChecker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateSwappingEnabled(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateAllowedHook(hooks, true);
        vm.stopPrank();
    }

    function testRevert_WhenNotAllowedWrapper(address wrapper) public {
        vm.assume(wrapper != address(this));
        assertFalse(permissionsAdapter.allowedWrappers(wrapper));
        vm.prank(wrapper);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.UnauthorizedWrapper.selector, wrapper));
        permissionsAdapter.wrapToPoolManager(100);
    }

    function testRevert_WhenInsufficientBalance(uint256 amount, uint256 transferAmount) public {
        vm.assume(amount != 0);
        transferAmount = bound(amount, 0, amount - 1);
        permissionedToken.mint(address(permissionsAdapter), transferAmount);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InsufficientBalance.selector, amount, transferAmount)
        );
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function test_WrapToPoolManager(uint256 amount, uint256 actualAmount) public {
        actualAmount = bound(amount, amount, type(uint256).max);
        permissionedToken.mint(address(permissionsAdapter), actualAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), mockPoolManager, amount);
        permissionsAdapter.wrapToPoolManager(amount);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), amount);
        assertEq(permissionedToken.balanceOf(mockPoolManager), actualAmount - amount);
    }

    function test_UpdateAllowedWrapper(address wrapper, bool allowed) public {
        vm.assume(wrapper != address(this));
        assertFalse(permissionsAdapter.allowedWrappers(wrapper));
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowedWrapperUpdated(wrapper, allowed);
        permissionsAdapter.updateAllowedWrapper(wrapper, allowed);
        assertEq(permissionsAdapter.allowedWrappers(wrapper), allowed);
    }

    function test_UpdateAllowedHook(IHooks hooks, bool allowed) public {
        vm.startPrank(owner);
        if (permissionsAdapter.allowedHooks(hooks) != allowed) {
            vm.expectEmit(true, true, true, true);
            emit IPermissionsAdapter.AllowedHookUpdated(hooks, allowed);
        }
        permissionsAdapter.updateAllowedHook(hooks, allowed);
        assertEq(permissionsAdapter.allowedHooks(hooks), allowed);
        vm.stopPrank();
    }

    function testRevert_WhenNotSupportedInterfaceEOA(IAllowlistChecker newAllowListCheckerEOA) public {
        vm.assume(newAllowListCheckerEOA != allowlistChecker);
        vm.prank(owner);
        vm.expectRevert(); // 预期回滚，且不带错误数据
        permissionsAdapter.updateAllowListChecker(newAllowListCheckerEOA);
    }

    function testRevert_WhenNotSupportedInterfaceContract() public {
        IAllowlistChecker newAllowListCheckerContract = new ImproperAllowlistChecker();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InvalidAllowListChecker.selector, newAllowListCheckerContract)
        );
        permissionsAdapter.updateAllowListChecker(newAllowListCheckerContract);
    }

    /// @dev 符合 ERC-165 的合约对 `0xffffffff` 必须返回 `false`。若某个检查器
    ///      对任意 interfaceId 都返回 `true`，就能绕过直接调用 `supportsInterface` 的检查。新增的
    ///      `ERC165Checker.supportsInterface` 预检查可以捕获这种情况。
    function testRevert_WhenBypassFakeSupportsInterface() public {
        IAllowlistChecker bypassChecker = new BypassAllowlistChecker();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.InvalidAllowListChecker.selector, bypassChecker));
        permissionsAdapter.updateAllowListChecker(bypassChecker);
    }

    function test_UpdateAllowListChecker() public {
        IAllowlistChecker newAllowListChecker = new MockAllowlistChecker();
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowListCheckerUpdated(newAllowListChecker);
        permissionsAdapter.updateAllowListChecker(newAllowListChecker);
        assertEq(address(permissionsAdapter.allowListChecker()), address(newAllowListChecker));
    }

    function test_DepositForVerification(uint256 amount) public {
        address depositor = makeAddr("depositor");
        permissionedToken.setTokenAllowlist(depositor, true);
        permissionedToken.mint(depositor, amount);
        vm.startPrank(depositor);
        permissionedToken.approve(address(permissionsAdapter), amount);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.VerificationDeposit(depositor, amount);
        permissionsAdapter.depositForVerification(amount);
        vm.stopPrank();
        assertEq(permissionedToken.balanceOf(address(permissionsAdapter)), amount);
    }

    /// @dev USDT 风格的底层代币在 transferFrom 中省略了 bool 返回值。直接调用
    ///      `transferFrom` 时，Solidity 会尝试从空的 returndata 中解码 bool，从而回滚（revert）；
    ///      而 `safeTransferFrom` 会把空 returndata 视为成功。
    function test_DepositForVerification_NonReturningUnderlying() public {
        NonReturningToken usdtLike = new NonReturningToken();
        bytes memory args = abi.encode(IERC20(address(usdtLike)), mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        address adapter;
        assembly {
            adapter := create(0, add(initcode, 0x20), mload(initcode))
        }

        address depositor = makeAddr("noReturnDepositor");
        uint256 amount = 1e18;
        usdtLike.mint(depositor, amount);
        vm.prank(depositor);
        usdtLike.approve(adapter, amount);

        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.VerificationDeposit(depositor, amount);
        vm.prank(depositor);
        IPermissionsAdapter(adapter).depositForVerification(amount);

        assertEq(usdtLike.balanceOf(adapter), amount);
    }

    function test_UpdateSwappingEnabled(bool enabled) public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.SwappingEnabledUpdated(enabled);
        permissionsAdapter.updateSwappingEnabled(enabled);
        assertEq(permissionsAdapter.swappingEnabled(), enabled);
    }

    function testRevert_WhenInvalidTransfer(address from, address to) public {
        vm.assume(from != address(0) && from != mockPoolManager);
        vm.assume(to != address(0) && to != mockPoolManager);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.InvalidTransfer.selector, from, to));
        permissionsAdapter.transfer(to, 0);
    }

    function testRevert_PoolManagerSelfTransfer(uint256 mintAmount, uint256 transferAmount) public {
        // Cantina ECO-340：否则 TAKE(adapter, poolManager, ...) 会把原始底层代币解包
        // 回 PoolManager，破坏适配器的记账边界。
        transferAmount = bound(transferAmount, 0, mintAmount);
        permissionedToken.mint(address(permissionsAdapter), mintAmount);
        permissionsAdapter.wrapToPoolManager(mintAmount);

        vm.prank(mockPoolManager);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InvalidTransfer.selector, mockPoolManager, mockPoolManager)
        );
        permissionsAdapter.transfer(mockPoolManager, transferAmount);

        // 适配器与底层代币的状态均未改变
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), mintAmount);
        assertEq(permissionedToken.balanceOf(mockPoolManager), 0);
        assertEq(permissionedToken.balanceOf(address(permissionsAdapter)), mintAmount);
    }

    function test_UnwrapOnPoolManagerTransfer(uint256 mintAmount, uint256 transferAmount, address recipient) public {
        vm.assume(recipient != address(0) && recipient != mockPoolManager && recipient != address(permissionsAdapter));
        assertEq(permissionedToken.balanceOf(recipient), 0);
        permissionedToken.setTokenAllowlist(recipient, true);
        transferAmount = bound(transferAmount, 0, mintAmount);
        permissionedToken.mint(address(permissionsAdapter), mintAmount);
        permissionsAdapter.wrapToPoolManager(mintAmount);
        vm.prank(mockPoolManager);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(mockPoolManager, recipient, transferAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(recipient, address(0), transferAmount);
        permissionsAdapter.transfer(recipient, transferAmount);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), mintAmount - transferAmount);
        assertEq(permissionedToken.balanceOf(recipient), transferAmount);
    }

    function testRevert_UnwrapWhenUnderlyingReturnsFalse() public {
        FalseReturningToken falseToken = new FalseReturningToken();
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(falseToken)));

        falseToken.mint(address(adapter), 100);
        adapter.wrapToPoolManager(100);

        address recipient = makeAddr("recipient");
        vm.prank(mockPoolManager);
        vm.expectRevert("TRANSFER_FAILED");
        IERC20(address(adapter)).transfer(recipient, 50);

        // 销毁与支付是原子性的：没有任何资产被转移。
        assertEq(adapter.totalSupply(), 100);
        assertEq(adapter.balanceOf(mockPoolManager), 100);
        assertEq(falseToken.balanceOf(recipient), 0);
    }

    function testRevert_UnwrapWhenUnderlyingPausedSilentFail() public {
        PausableSilentFailToken pausableToken = new PausableSilentFailToken();
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(pausableToken)));

        pausableToken.mint(address(adapter), 100);
        adapter.wrapToPoolManager(100);
        pausableToken.pause();

        address recipient = makeAddr("recipient");
        vm.prank(mockPoolManager);
        vm.expectRevert("TRANSFER_FAILED");
        IERC20(address(adapter)).transfer(recipient, 50);

        assertEq(adapter.totalSupply(), 100);
        assertEq(adapter.balanceOf(mockPoolManager), 100);
        assertEq(pausableToken.balanceOf(recipient), 0);
        assertEq(pausableToken.balanceOf(address(adapter)), 100);
    }

    function test_UnwrapSucceedsAfterUnpause() public {
        PausableSilentFailToken pausableToken = new PausableSilentFailToken();
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(pausableToken)));

        pausableToken.mint(address(adapter), 100);
        adapter.wrapToPoolManager(100);

        address recipient = makeAddr("recipient");
        vm.prank(mockPoolManager);
        IERC20(address(adapter)).transfer(recipient, 50);

        assertEq(adapter.totalSupply(), 50);
        assertEq(adapter.balanceOf(mockPoolManager), 50);
        assertEq(pausableToken.balanceOf(recipient), 50);
        assertEq(pausableToken.balanceOf(address(adapter)), 50);
    }

    // --- ERC20 元数据回退 ---

    function _assertMetadataFallbacks(IPermissionsAdapter adapter) internal view {
        assertEq(IERC20Metadata(address(adapter)).name(), "Uniswap v4 Permissioned Token");
        assertEq(IERC20Metadata(address(adapter)).symbol(), "v4PT");
        assertEq(IERC20Metadata(address(adapter)).decimals(), 18);
    }

    function test_Constructor_FallsBackWhenMetadataIsMissing() public {
        _assertMetadataFallbacks(_deployAdapterForToken(IERC20(address(new NoMetadataToken()))));
    }

    function test_Constructor_FallsBackWhenMetadataReverts() public {
        _assertMetadataFallbacks(_deployAdapterForToken(IERC20(address(new RevertingMetadataToken()))));
    }

    /// @dev bytes32 返回值不是标准 ABI 编码的字符串，因此解码失败并回退到默认值。
    function test_Constructor_FallsBackOnBytes32Metadata() public {
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(new Bytes32MetadataToken())));
        assertEq(IERC20Metadata(address(adapter)).name(), "Uniswap v4 Permissioned Token");
        assertEq(IERC20Metadata(address(adapter)).symbol(), "v4PT");
        // 此处 decimals() 是合法的 uint8，因此不会回退。
        assertEq(IERC20Metadata(address(adapter)).decimals(), 18);
    }

    function test_Constructor_FallsBackWhenDecimalsDoesNotFitInUint8() public {
        IPermissionsAdapter adapter = _deployAdapterForToken(IERC20(address(new OversizedDecimalsToken())));
        // name/symbol 能正常解码。
        assertEq(IERC20Metadata(address(adapter)).name(), "Uniswap v4 Big");
        assertEq(IERC20Metadata(address(adapter)).symbol(), "v4BIG");
        // decimals 的值过大，按 uint8 解码失败 -> 回退。
        assertEq(IERC20Metadata(address(adapter)).decimals(), 18);
    }

    /// @dev 适配器必须始终有所有者：`unwindPosition` 依据所有者进行权限校验，且其
    ///      按代币的回退路径也会把资产转给所有者，因此所有者为零地址会永久禁用强制退出。
    ///      这才是关键情形——`Ownable.renounceOwnership` 带有 `onlyOwner`，因此所有者是
    ///      唯一可能把它置零的一方。
    function testRevert_WhenRenouncingOwnership_fromOwner() public {
        vm.prank(owner);
        vm.expectRevert(IPermissionsAdapter.RenounceDisabled.selector);
        Ownable2Step(address(permissionsAdapter)).renounceOwnership();

        assertEq(permissionsAdapter.owner(), owner);
    }

    /// @dev 对任何人都回滚，而不仅是所有者：重写版本去掉了 `onlyOwner` 并无条件
    ///      回滚，因此错误是 `RenounceDisabled` 而非 `OwnableUnauthorizedAccount`。
    function testRevert_WhenRenouncingOwnership(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(IPermissionsAdapter.RenounceDisabled.selector);
        Ownable2Step(address(permissionsAdapter)).renounceOwnership();

        assertEq(permissionsAdapter.owner(), owner);
    }

    /// @dev 正常的两步移交流程不受影响。
    function test_transferOwnership_twoStepStillWorks() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        Ownable2Step(address(permissionsAdapter)).transferOwnership(newOwner);
        assertEq(permissionsAdapter.owner(), owner, "not transferred until accepted");

        vm.prank(newOwner);
        Ownable2Step(address(permissionsAdapter)).acceptOwnership();
        assertEq(permissionsAdapter.owner(), newOwner);
    }

    /// @dev 使所有者变为零地址的另一条途径：`transferOwnership(address(0))` 只会设置待定所有者，而
    ///      address(0) 永远无法调用 `acceptOwnership`，因此这种方式同样无法使所有权变为零地址。
    function test_transferOwnership_toZeroCannotComplete() public {
        vm.prank(owner);
        Ownable2Step(address(permissionsAdapter)).transferOwnership(address(0));

        assertEq(permissionsAdapter.owner(), owner);
        assertEq(Ownable2Step(address(permissionsAdapter)).pendingOwner(), address(0));
    }

    function _deployAdapterForToken(IERC20 token) internal returns (IPermissionsAdapter adapter) {
        bytes memory args = abi.encode(token, mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "deployment failed");
        adapter = IPermissionsAdapter(deployed);
        vm.prank(owner);
        adapter.updateAllowedWrapper(address(this), true);
    }
}

/// @dev transfer 时静默返回 false 的 ERC-20：既不回滚，也不改变余额。
contract FalseReturningToken is ERC20 {
    constructor() ERC20("FalseToken", "FT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev 带暂停逻辑的 ERC-20：暂停时 transfer 静默返回 false。
contract PausableSilentFailToken is ERC20 {
    bool public paused;

    constructor() ERC20("PausableToken", "PT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function pause() public {
        paused = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (paused) return false;
        return super.transfer(to, amount);
    }
}

/// @dev 最精简的 IERC20 实现，使下面的 mock 不必继承 OZ ERC20（后者会自动提供元数据）。
abstract contract StubIERC20 is IERC20 {
    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure override returns (bool) {
        return true;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return true;
    }
}

contract NoMetadataToken is StubIERC20 {}

contract RevertingMetadataToken is StubIERC20 {
    function name() external pure returns (string memory) {
        revert("no name");
    }

    function symbol() external pure returns (string memory) {
        revert("no symbol");
    }

    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }
}

/// @dev 旧式 MKR 风格代币：name/symbol 返回 `bytes32` 而不是 `string`。
contract Bytes32MetadataToken is StubIERC20 {
    function name() external pure returns (bytes32) {
        return bytes32("MakerDAO");
    }

    function symbol() external pure returns (bytes32) {
        return bytes32("MKR");
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @dev `decimals()` 返回超出 uint8 范围的 uint256——按 uint8 进行 ABI 解码必然失败。
contract OversizedDecimalsToken is StubIERC20 {
    function name() external pure returns (string memory) {
        return "Big";
    }

    function symbol() external pure returns (string memory) {
        return "BIG";
    }

    function decimals() external pure returns (uint256) {
        return 999;
    }
}

contract ImproperAllowlistChecker is IAllowlistChecker {
    function checkAllowlist(address, address) public pure returns (PermissionFlag) {
        return PermissionFlags.ALL_ALLOWED;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

/// @dev 对所有 interfaceId（包括 `0xffffffff`）都返回 `true`。可绕过简单的直接
///      `supportsInterface` 检查；但会被 ERC-165 规定的预检查拒绝。
contract BypassAllowlistChecker is IAllowlistChecker {
    function checkAllowlist(address, address) public pure returns (PermissionFlag) {
        return PermissionFlags.ALL_ALLOWED;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice USDT 风格的 ERC20：transfer/transferFrom 省略 bool 返回值。用于确认
///         `PermissionsAdapter.depositForVerification` 能兼容非标准的返回值形式。
contract NonReturningToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "NonReturning";
    string public symbol = "NORET";
    uint8 public decimals = 18;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // 故意不返回值
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // 故意不返回值
    }
}
