// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {INotifier} from "../../src/interfaces/INotifier.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice 在 `notifyUnsubscribe` 期间覆写 `getApproved[tokenId]` 的订阅者。
/// @dev `approve` 没有 `onlyIfPoolManagerLocked` 守卫，因此即使在活跃的 unlock 回调内部，
///      该写入也会生效。两种攻击者形态都能通过 `ERC721Permit_v4.approve` 的权限检查：
///      订阅者本身就是所有者（合约 LP 为自己订阅），或者它持有 `setApprovalForAll`。
///      必须正常返回 —— `_unsubscribe` 用 try/catch 包裹回调，因此回滚（revert）会把
///      劫持用的 SSTORE 一并撤销。将 `approveTarget` 设为 admin 可写回相同的值，从而单独考察
///      写入的值本身而非重入这一行为；设置 `approveDuringCallback = false` 则作为
///      行为上无害的对照组。
contract MockApprovalHijackSubscriber is ISubscriber {
    IERC721 public immutable posm;
    bool public immutable approveDuringCallback;
    /// @dev `address(0)` 是哨兵值，表示“授权给自己”。
    address public immutable approveTarget;

    uint256 public notifyUnsubscribeCount;
    uint256 public gasUsedByApprove;

    constructor(address _posm, bool _approveDuringCallback, address _approveTarget) {
        posm = IERC721(_posm);
        approveDuringCallback = _approveDuringCallback;
        approveTarget = _approveTarget;
    }

    /// @notice 供合约 LP 形态使用，此时订阅者自身就是头寸所有者。
    function subscribeSelf(uint256 tokenId) external {
        INotifier(address(posm)).subscribe(tokenId, address(this), "");
    }

    function notifySubscribe(uint256, bytes memory) external {}

    function notifyUnsubscribe(uint256 tokenId) external {
        if (approveDuringCallback) {
            uint256 gasBefore = gasleft();
            posm.approve(approveTarget == address(0) ? address(this) : approveTarget, tokenId);
            gasUsedByApprove = gasBefore - gasleft();
        }
        notifyUnsubscribeCount++;
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}
}
