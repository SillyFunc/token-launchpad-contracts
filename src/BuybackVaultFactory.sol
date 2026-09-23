// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "src/Clones.sol";
import {BuybackVault, BuybackConfig} from "src/BuybackVault.sol";

error ZeroImplementation();
error ZeroCoordinator();
error UnknownVault();

/// @notice 克隆 BuybackVault。仅 Coordinator 可创建/初始化，保证发币与金库在同一笔交易内完成。
contract BuybackVaultFactory is AccessControl {
    bytes32 public constant COORDINATOR_ROLE = keccak256("COORDINATOR_ROLE");

    address public immutable implementation;
    address public immutable keeperRegistry;

    mapping(address => bool) public isVault;

    event BuybackVaultCreated(address indexed vault);

    constructor(address implementation_, address coordinator) {
        if (implementation_ == address(0)) revert ZeroImplementation();
        if (coordinator == address(0)) revert ZeroCoordinator();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COORDINATOR_ROLE, coordinator);
        implementation = implementation_;
        keeperRegistry = coordinator;
    }

    function createVault() external onlyRole(COORDINATOR_ROLE) returns (address vault) {
        vault = Clones.clone(implementation);
        isVault[vault] = true;
        emit BuybackVaultCreated(vault);
    }

    function initializeVault(
        address vault,
        address token,
        address pair,
        address router,
        address wbnb,
        BuybackConfig calldata config
    ) external onlyRole(COORDINATOR_ROLE) {
        if (!isVault[vault]) revert UnknownVault();
        BuybackVault(payable(vault)).initialize(token, pair, router, wbnb, keeperRegistry, config);
    }
}
