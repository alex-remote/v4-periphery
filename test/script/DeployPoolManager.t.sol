// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployPoolManager} from "../../script/01_PoolManager.s.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Test} from "forge-std/Test.sol";

contract DeployPoolManagerTest is Test {
    DeployPoolManager deployer;

    function setUp() public {
        deployer = new DeployPoolManager();
    }

    function test_run_poolManager() public {
        IPoolManager manager = deployer.run();
        // Foundry 会在脚本中设置一个默认的 sender。
        address defaultSender = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;
        // 部署者即为所有者。
        assertEq(_getOwner(manager), defaultSender);
    }

    function _getOwner(IPoolManager manager) public view returns (address owner) {
        // 所有者（owner）存储在 slot 0
        owner = address(uint160(uint256(manager.extsload(0))));
    }
}
