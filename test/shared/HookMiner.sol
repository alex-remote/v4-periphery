// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice 用于挖掘 hook 地址的极简库
library HookMiner {
    // 用于截取地址低 14 位的掩码
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK; // 0000 ... 0000 0011 1111 1111 1111

    // 查找 salt 的最大迭代次数，避免无限循环或 MemoryOOG
    // （随意设定）
    uint256 constant MAX_LOOP = 160_444;

    /// @notice 查找一个 salt，使生成的 hook 地址带有期望的 `flags`
    /// @param deployer 将部署该 hook 的地址。在 `forge test` 中，它是测试合约 `address(this)` 或 prank 所用的地址
    /// 在 `forge script` 中，它应为 `0x4e59b44847b379578588920cA78FbF26c0B4956C`（CREATE2 Deployer Proxy）
    /// @param flags hook 地址期望的标志位。示例：`uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`
    /// @param creationCode hook 合约的创建字节码。示例：`type(Counter).creationCode`
    /// @param constructorArgs hook 合约经过编码的构造函数参数。示例：`abi.encode(address(manager))`
    /// @return (hookAddress, salt) 使用 `salt` 并按如下语法部署时，hook 会部署到 `hookAddress`：`new Hook{salt: salt}(<constructor arguments>)`
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address, bytes32)
    {
        flags = flags & FLAG_MASK; // 通过掩码仅保留低 14 位
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        address hookAddress;
        for (uint256 salt; salt < MAX_LOOP; salt++) {
            hookAddress = computeAddress(deployer, salt, creationCodeWithArgs);

            // 如果 hook 地址的低 14 位与期望的标志位一致，且该地址上没有字节码，则找到了匹配项
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("HookMiner: could not find salt");
    }

    /// @notice 预先计算通过 CREATE2 部署的合约地址
    /// @param deployer 将部署该 hook 的地址。在 `forge test` 中，它是测试合约 `address(this)` 或 prank 所用的地址
    /// 在 `forge script` 中，它应为 `0x4e59b44847b379578588920cA78FbF26c0B4956C`（CREATE2 Deployer Proxy）
    /// @param salt 用于部署该 hook 的 salt
    /// @param creationCodeWithArgs hook 合约的创建字节码，末尾附加了编码后的构造函数参数。示例：`abi.encodePacked(type(Counter).creationCode, abi.encode(constructorArg1, constructorArg2))`
    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
