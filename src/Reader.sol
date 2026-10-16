// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";
import {BuybackVault, BuybackReadiness} from "src/BuybackVault.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {IPancakePair} from "src/lib/interfaces/IPancakeRouter02.sol";
import {PackedFeeConfigV2} from "src/lib/interfaces/ITaxProcessor.sol";

interface IReaderPoolState {
    function getPoolStateData() external view returns (uint8, uint16, uint16, uint256, uint256, uint256);
}

error InvalidReaderCoordinator();
error ReaderUnknownToken(address token);
error ReaderInvalidPair();

/// @notice Shared, read-only snapshots. Funds and execution authority remain in the original contracts.
/// @dev Schema 1 targets the execution-controls release; legacy deployments use their existing read adapter.
contract Reader {
    CoordinatorFactory public immutable coordinator;

    struct Contracts {
        address token;
        address pair;
        address taxProcessor;
        address vault;
        address wbnb;
    }

    struct Controls {
        uint8 executionFlags;
    }

    struct Pool {
        uint256 reserveToken;
        uint256 reserveWbnb;
        uint256 totalSupply;
        uint8 state;
        uint16 buyTaxRate;
        uint16 sellTaxRate;
        uint256 taxExpirationTime;
    }

    struct Tax {
        uint256 pendingAmount;
        PackedFeeConfigV2 feeConfig;
    }

    struct Liquidity {
        uint256 pendingToken;
        uint256 pendingWbnb;
    }

    struct Buyback {
        uint256 balance;
        uint256 executableAmount;
        uint8 mode;
        uint8 readiness;
        uint64 nextExecuteTime;
    }

    struct Snapshot {
        uint8 schemaVersion;
        uint256 blockNumber;
        uint256 blockTimestamp;
        Contracts contracts;
        Controls controls;
        Pool pool;
        Tax tax;
        Liquidity liquidity;
        Buyback buyback;
    }

    constructor(address coordinator_) {
        if (coordinator_.code.length == 0) revert InvalidReaderCoordinator();
        coordinator = CoordinatorFactory(coordinator_);
        // A missing/new ABI must fail at setup, not silently masquerade as unpaused legacy data.
        if (coordinator.executionFlags() > 7) revert InvalidReaderCoordinator();
    }

    function getTokenSnapshot(address token) external view returns (Snapshot memory snapshot) {
        if (coordinator.tokenCreators(token) == address(0)) revert ReaderUnknownToken(token);
        address processor = coordinator.tokenTaxProcessors(token);
        address wbnb = TaxProcessor(payable(processor)).getQuoteToken();
        address pair = IFlapTaxTokenV3(token).mainPool();
        address vault = coordinator.tokenVaults(token);

        snapshot.schemaVersion = 1;
        snapshot.blockNumber = block.number;
        snapshot.blockTimestamp = block.timestamp;
        snapshot.contracts = Contracts(token, pair, processor, vault, wbnb);
        snapshot.controls.executionFlags = coordinator.executionFlags();
        snapshot.pool = _pool(token, pair, wbnb);
        snapshot.tax.pendingAmount = TaxProcessor(payable(processor)).pendingTaxTokens();
        snapshot.tax.feeConfig = TaxProcessor(payable(processor)).feeConfigV2();
        snapshot.liquidity.pendingToken = TaxProcessor(payable(processor)).lpTokenBalance();
        snapshot.liquidity.pendingWbnb = TaxProcessor(payable(processor)).lpQuoteBalance();
        if (vault != address(0)) snapshot.buyback = _buyback(vault);
    }

    function _pool(address token, address pair, address wbnb) private view returns (Pool memory pool) {
        address token0 = IPancakePair(pair).token0();
        address token1 = IPancakePair(pair).token1();
        if (!((token0 == token && token1 == wbnb) || (token0 == wbnb && token1 == token))) {
            revert ReaderInvalidPair();
        }
        (uint112 reserve0, uint112 reserve1,) = IPancakePair(pair).getReserves();
        (pool.reserveToken, pool.reserveWbnb) =
            token0 == token ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        pool.totalSupply = IERC20(pair).totalSupply();
        (pool.state, pool.buyTaxRate, pool.sellTaxRate,, pool.taxExpirationTime,) =
            IReaderPoolState(token).getPoolStateData();
    }

    function _buyback(address vault) private view returns (Buyback memory buyback) {
        BuybackVault instance = BuybackVault(payable(vault));
        BuybackReadiness readiness;
        buyback.balance = vault.balance;
        (buyback.executableAmount, readiness) = instance.previewBuyback();
        buyback.readiness = uint8(readiness);
        buyback.mode = uint8(instance.mode());
        buyback.nextExecuteTime = instance.nextExecuteTime();
    }
}
