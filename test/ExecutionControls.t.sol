// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";

contract ExecutionControlsTest is Test {
    CoordinatorFactory coordinator;
    event ExecutionControlsUpdated(uint8 executionFlags);

    function setUp() public {
        coordinator = new CoordinatorFactory(address(1), address(2), address(3));
    }

    function test_executionControlsDefaultEnabled() public view {
        (bool ok, bytes memory data) = address(coordinator).staticcall(abi.encodeWithSignature("executionFlags()"));
        assertTrue(ok && data.length == 32, "Coordinator must expose execution controls");
        assertEq(abi.decode(data, (uint8)), 7);
    }

    function testFuzz_adminCanSetEveryCombination(bool tax, bool liquidity, bool buyback) public {
        uint8 expected = (tax ? 1 : 0) | (liquidity ? 2 : 0) | (buyback ? 4 : 0);
        vm.expectEmit(false, false, false, true, address(coordinator));
        emit ExecutionControlsUpdated(expected);
        coordinator.setExecutionControls(tax, liquidity, buyback);
        assertEq(coordinator.executionFlags(), expected);
        assertTrue(coordinator.factoryEnabled(), "maintenance switches must not disable token creation");
    }

    function test_keeperCannotChangeControls() public {
        address keeper = address(0xCA11);
        coordinator.grantRole(coordinator.KEEPER_ROLE(), keeper);
        vm.prank(keeper);
        vm.expectRevert();
        coordinator.setExecutionControls(false, false, false);
        assertEq(coordinator.executionFlags(), 7);
    }

    function test_creationAndMaintenanceControlsAreIndependent() public {
        coordinator.setFactoryEnabled(false);
        assertEq(coordinator.executionFlags(), 7);
        coordinator.setExecutionControls(false, false, false);
        coordinator.setFactoryEnabled(true);
        assertEq(coordinator.executionFlags(), 0);
    }
}
