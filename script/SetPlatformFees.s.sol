// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";

interface ICoordinatorFeeAdmin {
    function creationFee() external view returns (uint256);
    function reservationFee() external view returns (uint256);
    function setCreationFee(uint256 fee) external;
    function setReservationFee(uint256 fee) external;
}

/// @notice Updates the platform's creation and vanity-address reservation fees.
/// @dev The broadcaster must hold CoordinatorFactory.DEFAULT_ADMIN_ROLE. Each changed fee is a separate
///      CoordinatorFactory transaction because the deployed contract exposes separate setters.
contract SetPlatformFees is Script {
    error ZeroCoordinator();
    error CoordinatorHasNoCode(address coordinator);
    error ZeroCreationFee();
    error ZeroReservationFee();

    /// @param coordinatorAddress The deployed CoordinatorFactory address.
    /// @param newCreationFee New creation fee in BNB wei; must be non-zero.
    /// @param newReservationFee New address-reservation fee in BNB wei; must be non-zero.
    function run(address coordinatorAddress, uint256 newCreationFee, uint256 newReservationFee) external {
        if (coordinatorAddress == address(0)) revert ZeroCoordinator();
        if (coordinatorAddress.code.length == 0) revert CoordinatorHasNoCode(coordinatorAddress);
        if (newCreationFee == 0) revert ZeroCreationFee();
        if (newReservationFee == 0) revert ZeroReservationFee();

        ICoordinatorFeeAdmin coordinator = ICoordinatorFeeAdmin(coordinatorAddress);
        bool updateCreationFee = coordinator.creationFee() != newCreationFee;
        bool updateReservationFee = coordinator.reservationFee() != newReservationFee;

        // Do not create an unnecessary broadcast session or transaction when both values already match.
        if (!updateCreationFee && !updateReservationFee) return;

        vm.startBroadcast();
        if (updateCreationFee) coordinator.setCreationFee(newCreationFee);
        if (updateReservationFee) coordinator.setReservationFee(newReservationFee);
        vm.stopBroadcast();
    }
}
