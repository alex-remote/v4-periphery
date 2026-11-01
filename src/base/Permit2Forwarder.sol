// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPermit2Forwarder, IAllowanceTransfer} from "../interfaces/IPermit2Forwarder.sol";

/// @notice Permit2Forwarder 允许通过许可（permit）将本合约设为 permit2 上的被授权者
/// @dev 本合约并不强制要求被授权者必须是本合约，但这是预期的使用场景
contract Permit2Forwarder is IPermit2Forwarder {
    /// @notice 用于转发授权的 Permit2 合约
    IAllowanceTransfer public immutable permit2;

    constructor(IAllowanceTransfer _permit2) {
        permit2 = _permit2;
    }

    /// @inheritdoc IPermit2Forwarder
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        external
        payable
        returns (bytes memory err)
    {
        // 使用 try/catch，以防有人抢先执行（front-run）该 permit，导致 multicall 遭到 DoS
        try permit2.permit(owner, permitSingle, signature) {}
        catch (bytes memory reason) {
            err = reason;
        }
    }

    /// @inheritdoc IPermit2Forwarder
    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata _permitBatch, bytes calldata signature)
        external
        payable
        returns (bytes memory err)
    {
        // 使用 try/catch，以防有人抢先执行（front-run）该 permit，导致 multicall 遭到 DoS
        try permit2.permit(owner, _permitBatch, signature) {}
        catch (bytes memory reason) {
            err = reason;
        }
    }
}
