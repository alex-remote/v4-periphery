// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IUniswapV4DeployerCompetition
/// @notice UniswapV4DeployerCompetition 合约的接口
interface IUniswapV4DeployerCompetition {
    event NewAddressFound(address indexed bestAddress, address indexed submitter, uint256 score);

    error InvalidBytecode();
    error CompetitionNotOver(uint256 currentTime, uint256 deadline);
    error CompetitionOver(uint256 currentTime, uint256 deadline);
    error NotAllowedToDeploy(address sender, address deployer);
    error WorseAddress(address newAddress, address bestAddress, uint256 newScore, uint256 bestScore);
    error InvalidSender(bytes32 salt, address sender);

    /// @notice 如果新地址的靓号（vanity）得分更高，则更新最佳地址
    /// @param salt 用于通过 CREATE2 计算新地址的 salt
    /// @dev salt 的前 20 个字节必须是 address(0) 或 msg.sender
    function updateBestAddress(bytes32 salt) external;

    /// @notice 部署 Uniswap v4 PoolManager 合约
    /// @param bytecode Uniswap v4 PoolManager 合约的字节码
    /// @dev 字节码必须与 initCodeHash 匹配
    function deploy(bytes memory bytecode) external;
}
