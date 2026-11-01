// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployPoolModifyLiquidityTest} from "../../script/02_PoolModifyLiquidityTest.s.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Test} from "forge-std/Test.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

// 对一个 Test 合约的测试（笑）
contract DeployPoolModifyLiquidityTestTest is Test {
    DeployPoolModifyLiquidityTest deployer;

    IPoolManager manager;

    function setUp() public {
        manager = new PoolManager(address(this));
        deployer = new DeployPoolModifyLiquidityTest();
    }

    function test_run_modifyLiquidityRouter() public {
        PoolModifyLiquidityTest testModifyLiquidityRouter = deployer.run(address(manager));

        assertEq(address(testModifyLiquidityRouter.manager()), address(manager));
    }
}
