// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IExecutionControls {
    function executionFlags() external view returns (uint8);
}

error ExecutionPaused(uint8 operation);

/// @dev Shared bit definitions; inlined, with no separately deployed library.
library ExecutionControls {
    uint8 internal constant TAX = 1;
    uint8 internal constant LIQUIDITY = 2;
    uint8 internal constant BUYBACK = 4;
    uint8 internal constant ALL = TAX | LIQUIDITY | BUYBACK;

    function requireEnabled(address registry, uint8 operation) internal view {
        if ((IExecutionControls(registry).executionFlags() & operation) != operation) {
            revert ExecutionPaused(operation);
        }
    }
}
