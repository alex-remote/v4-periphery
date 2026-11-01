// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {EIP712_v4} from "./EIP712_v4.sol";
import {ERC721PermitHash} from "../libraries/ERC721PermitHash.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {IERC721Permit_v4} from "../interfaces/IERC721Permit_v4.sol";
import {UnorderedNonce} from "./UnorderedNonce.sol";

/// @title 支持 permit 的 ERC721
/// @notice 支持通过签名进行授权（即 permit）的非同质化代币
abstract contract ERC721Permit_v4 is ERC721, IERC721Permit_v4, EIP712_v4, UnorderedNonce {
    using SignatureVerification for bytes;

    /// @notice 计算 nameHash 和 versionHash
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) EIP712_v4(name_) {}

    /// @notice 检查区块时间戳是否早于签名的截止时间
    modifier checkSignatureDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert SignatureDeadlineExpired();
        _;
    }

    /// @inheritdoc IERC721Permit_v4
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable
        checkSignatureDeadline(deadline)
    {
        // .verify 函数会检查 owner 不为 0 地址
        address owner = _ownerOf[tokenId];

        bytes32 digest = ERC721PermitHash.hashPermit(spender, tokenId, nonce, deadline);
        signature.verify(_hashTypedData(digest), owner);

        _useUnorderedNonce(owner, nonce);
        _approve(owner, spender, tokenId);
    }

    /// @inheritdoc IERC721Permit_v4
    function permitForAll(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external payable checkSignatureDeadline(deadline) {
        bytes32 digest = ERC721PermitHash.hashPermitForAll(operator, approved, nonce, deadline);
        signature.verify(_hashTypedData(digest), owner);

        _useUnorderedNonce(owner, nonce);
        _approveForAll(owner, operator, approved);
    }

    /// @notice 启用或禁用第三方（“操作者”，operator）管理
    /// `msg.sender` 全部资产的授权
    /// @dev 触发 ApprovalForAll 事件。合约必须（MUST）允许
    /// 每个所有者拥有多个操作者。
    /// @dev 重写 Solmate ERC721 的 setApprovalForAll，使 setApprovalForAll() 与 permit() 共用 _approveForAll 方法
    /// @param operator 要加入已授权操作者集合的地址
    /// @param approved 为 true 表示授权该操作者，为 false 表示撤销授权
    function setApprovalForAll(address operator, bool approved) public override {
        _approveForAll(msg.sender, operator, approved);
    }

    function _approveForAll(address owner, address operator, bool approved) internal {
        isApprovedForAll[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    /// @notice 更改或重新确认某个 NFT 的被授权地址
    /// @dev 重写 Solmate ERC721 的 approve，使 approve() 与 permit() 共用 _approve 方法
    /// 传入零地址作为 spender 可用于移除所有现存的授权
    /// 除非 `msg.sender` 是该 NFT 当前的所有者，
    /// 或当前所有者的已授权操作者，否则抛出错误。
    /// @param spender 新的被授权 NFT 控制者
    /// @param id 要授权的 NFT 的 tokenId
    function approve(address spender, uint256 id) public override {
        address owner = _ownerOf[id];

        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert Unauthorized();

        _approve(owner, spender, id);
    }

    function _approve(address owner, address spender, uint256 id) internal {
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        return
            spender == ownerOf(tokenId) || getApproved[tokenId] == spender
                || isApprovedForAll[ownerOf(tokenId)][spender];
    }
}
