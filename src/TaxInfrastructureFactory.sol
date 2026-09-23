// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "src/Clones.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";
import {IDividend} from "src/lib/dividend/IDividend.sol";

error ZeroTaxProcessorImplementation();
error ZeroDividendImplementation();
error ZeroCoordinator();
error UnexpectedDividendAddress();
error UnknownDividend();

interface IManagedDividend {
    function setKeeper(address keeper, bool allowed) external;
    function setDeferredOrigin(address origin, bool deferred) external;
}

/// @notice Atomically clones and initializes per-token tax infrastructure.
/// @dev Keeping clone creation outside Coordinator prevents the coordinator runtime from
///      embedding TaxProcessor bytecode and exceeding EIP-170's 24 KiB limit.
contract TaxInfrastructureFactory is AccessControl {
    bytes32 public constant COORDINATOR_ROLE = keccak256("COORDINATOR_ROLE");

    address public immutable taxProcessorImplementation;
    address public immutable dividendImplementation;
    address public immutable keeperRegistry;

    mapping(address => bool) public isTaxProcessor;
    mapping(address => bool) public isDividend;

    event TaxInfrastructureCreated(address indexed taxToken, address indexed taxProcessor, address dividend);

    constructor(address taxProcessorImplementation_, address dividendImplementation_, address coordinator) {
        if (taxProcessorImplementation_ == address(0)) revert ZeroTaxProcessorImplementation();
        if (dividendImplementation_ == address(0)) revert ZeroDividendImplementation();
        if (coordinator == address(0)) revert ZeroCoordinator();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COORDINATOR_ROLE, coordinator);
        taxProcessorImplementation = taxProcessorImplementation_;
        dividendImplementation = dividendImplementation_;
        keeperRegistry = coordinator;
    }

    function createInfrastructure(
        TaxProcessorInitParams calldata input,
        address pair,
        address presale,
        uint256 minimumShareBalance
    ) external onlyRole(COORDINATOR_ROLE) returns (address processor, address dividend) {
        if (input.dividendAddress != address(0)) revert UnexpectedDividendAddress();

        TaxProcessorInitParams memory params = input;
        processor = Clones.clone(taxProcessorImplementation);
        isTaxProcessor[processor] = true;

        if (params.dividendBps != 0) {
            dividend = Clones.clone(dividendImplementation);
            isDividend[dividend] = true;
            params.dividendAddress = dividend;
            IDividend(dividend).initialize(params.dividendToken, params.taxToken, minimumShareBalance);
            IDividend(dividend).excludeAddress(pair);
            IDividend(dividend).excludeAddress(processor);
            IDividend(dividend).excludeAddress(presale);
        }

        TaxProcessor(payable(processor)).initialize(params);
        emit TaxInfrastructureCreated(params.taxToken, processor, dividend);
    }

    /// @notice Configure the local Dividend's deferred-share keeper through its permanent owner.
    function setDividendKeeper(address dividend, address keeper, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isDividend[dividend]) revert UnknownDividend();
        IManagedDividend(dividend).setKeeper(keeper, allowed);
    }

    function setDividendDeferredOrigin(address dividend, address origin, bool deferred)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDividend[dividend]) revert UnknownDividend();
        IManagedDividend(dividend).setDeferredOrigin(origin, deferred);
    }

    function emergencyWithdrawDividend(address dividend, address token, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDividend[dividend]) revert UnknownDividend();
        IDividend(dividend).emergencyWithdraw(token, amount, to);
    }
}
