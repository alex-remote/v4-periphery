// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";
import {IUniswapV4DeployerCompetition} from "./interfaces/IUniswapV4DeployerCompetition.sol";

/// @title UniswapV4DeployerCompetition
/// @notice 一个以众包方式寻找最佳 Uniswap V4 地址所需 salt 的合约
contract UniswapV4DeployerCompetition is IUniswapV4DeployerCompetition {
    using VanityAddressLib for address;

    /// @dev 目前为止找到的最佳地址对应的 salt
    bytes32 public bestAddressSalt;
    /// @dev 目前为止找到的最佳地址的提交者
    address public bestAddressSubmitter;

    /// @dev 竞赛的截止时间
    uint256 public immutable competitionDeadline;
    /// @dev V4 合约的初始化代码（init code）哈希
    bytes32 public immutable initCodeHash;

    /// @dev 在独占部署截止时间之前，可以发起 v4 PoolManager 部署的部署者。
    /// @dev 此截止时间过后，任何人都可以部署。
    address public immutable deployer;
    /// @dev 截止时间之后，由 deployer 独占部署的截止时间
    uint256 public immutable exclusiveDeployDeadline;

    constructor(
        bytes32 _initCodeHash,
        uint256 _competitionDeadline,
        address _exclusiveDeployer,
        uint256 _exclusiveDeployLength
    ) {
        initCodeHash = _initCodeHash;
        competitionDeadline = _competitionDeadline;
        exclusiveDeployDeadline = _competitionDeadline + _exclusiveDeployLength;
        deployer = _exclusiveDeployer;
    }

    /// @inheritdoc IUniswapV4DeployerCompetition
    function updateBestAddress(bytes32 salt) external {
        if (block.timestamp > competitionDeadline) {
            revert CompetitionOver(block.timestamp, competitionDeadline);
        }

        address saltSubAddress = address(bytes20(salt));
        if (saltSubAddress != msg.sender && saltSubAddress != address(0)) revert InvalidSender(salt, msg.sender);

        address newAddress = Create2.computeAddress(salt, initCodeHash);
        address _bestAddress = bestAddress();
        if (!newAddress.betterThan(_bestAddress)) {
            revert WorseAddress(newAddress, _bestAddress, newAddress.score(), _bestAddress.score());
        }

        bestAddressSalt = salt;
        bestAddressSubmitter = msg.sender;

        emit NewAddressFound(newAddress, msg.sender, newAddress.score());
    }

    /// @inheritdoc IUniswapV4DeployerCompetition
    function deploy(bytes memory bytecode) external {
        if (keccak256(bytecode) != initCodeHash) {
            revert InvalidBytecode();
        }

        if (block.timestamp <= competitionDeadline) {
            revert CompetitionNotOver(block.timestamp, competitionDeadline);
        }

        if (msg.sender != deployer && block.timestamp <= exclusiveDeployDeadline) {
            // 截止时间过后任何人都可以部署
            revert NotAllowedToDeploy(msg.sender, deployer);
        }

        // 合约的所有者必须编码在字节码中
        Create2.deploy(0, bestAddressSalt, bytecode);
    }

    /// @dev 返回目前为止找到的最佳地址
    function bestAddress() public view returns (address) {
        return Create2.computeAddress(bestAddressSalt, initCodeHash);
    }
}
