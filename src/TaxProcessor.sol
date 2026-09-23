// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {TransferHelper} from "src/TransferHelper.sol";
import {IPancakePair, IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {IDividend} from "src/lib/dividend/IDividend.sol";
import {
    ITaxProcessor,
    TaxProcessorInitParams,
    PackedFeeConfig,
    PackedFeeConfigV2
} from "src/lib/interfaces/ITaxProcessor.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

error AlreadyInitialized();
error NotDeployer();
error TaxTokenRequired();
error RouterRequired();
error FeeReceiverRequired();
error MarketReceiverRequired();
error DividendRequired();
error UnsupportedDividendToken();
error InvalidDistribution();
error InvalidProtocolFee();
error InvalidCommission();
error NotTaxToken();
error KeeperRegistryRequired();
error UnauthorizedTaxKeeper();
error InvalidTaxAmount();
error UnsafeMinQuoteOut();
error InvalidProcessingDeadline();
error QuoteTokenUnavailable();
error InsufficientQuoteOutput();
error AccountingInvariant();
error LiquidityUnavailable();
error InvalidLiquidityBounds();
error InvalidMainPool();
error InsufficientLiquidityOutput();
error InvalidBurnAmount();

/// @notice Asynchronous four-channel tax processor for FlapTaxTokenV3.
/// @dev User transfers only enqueue tax. A role-gated keeper later performs bounded swaps,
///      liquidity minting and quote-token burns. Fixed-recipient dispatch is permissionless.
contract TaxProcessor is ITaxProcessor, ReentrancyGuard {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint16 private constant BPS = 10_000;
    uint64 public constant MAX_DEADLINE_DELAY = 10 minutes;
    address private constant DEAD = address(0xdead);

    address private immutable _deployer;
    address private immutable _implementation;
    bool private _initialized;

    address public immutable override swapRegistry;
    address public immutable keeperRegistry;

    address public override taxToken;
    address public override router;
    address public override feeReceiver;
    address public override marketAddress;
    address public override dividendAddress;
    address public override commissionReceiver;
    address public override converter;
    address public override dividendToken;
    address public quoteToken;
    uint256 public override liqExpectedOutputAmount;

    uint16 private _marketBps;
    uint16 private _deflationBps;
    uint16 private _lpBps;
    uint16 private _dividendBps;
    uint16 private _feeRate;
    uint16 public override commissionBps;

    uint256 public override feeQuoteBalance;
    uint256 public override lpQuoteBalance;
    uint256 public override marketQuoteBalance;
    uint256 public override pendingDividendQuoteTokenBalance;
    uint256 public override dividendTokenBalance;
    uint256 public override commissionQuoteBalance;
    uint256 public pendingDeflationQuoteBalance;
    uint256 public lpTokenBalance;

    uint256 public override totalDividendTokenSent;
    uint256 public override totalQuoteAddedToLiquidity;
    uint256 public override totalTokenAddedToLiquidity;
    uint256 public override totalQuoteSentToMarketing;
    uint256 public totalQuoteSentToReceiver;
    uint256 public totalTaxTokenBurned;
    uint256 public totalQuoteBurned;
    int8 public pendingDirection;

    event Initialized(address indexed taxToken, address indexed dividendAddress);
    event TaxQueued(uint256 taxAmount, uint256 pendingBalance);
    event TaxProcessed(uint256 taxAmount, uint256 quoteOut, uint256 burned, uint256 lpReserved, int8 direction);
    event TaxForwarded(address indexed receiver, uint256 amount, bool isNative);
    event DividendDeposited(address indexed dividend, uint256 amount);
    event DividendDepositDeferred(address indexed dividend, uint256 amount);
    event LiquidityAdded(uint256 tokenAmount, uint256 quoteAmount, uint256 liquidity);
    event DeflationQuoteBurned(uint256 quoteAmount, uint256 taxTokenOut);

    receive() external payable {}

    constructor(address keeperRegistry_) {
        if (keeperRegistry_ == address(0)) revert KeeperRegistryRequired();
        _deployer = msg.sender;
        _implementation = address(this);
        swapRegistry = address(0);
        keeperRegistry = keeperRegistry_;
    }

    modifier onlyTaxToken() {
        if (msg.sender != taxToken) revert NotTaxToken();
        _;
    }

    modifier onlyKeeper() {
        if (!IAccessControl(keeperRegistry).hasRole(KEEPER_ROLE, msg.sender)) revert UnauthorizedTaxKeeper();
        _;
    }

    function initialize(TaxProcessorInitParams memory params) external override {
        if (_initialized) revert AlreadyInitialized();
        // Direct deployments remain deployer-initialized for tests and operational recovery.
        // Minimal proxies are initialized atomically by TaxInfrastructureFactory.
        if (address(this) == _implementation && msg.sender != _deployer) revert NotDeployer();
        if (params.taxToken == address(0)) revert TaxTokenRequired();
        if (params.router == address(0)) revert RouterRequired();
        if (params.feeReceiver == address(0)) revert FeeReceiverRequired();
        if (uint256(params.marketBps) + params.deflationBps + params.lpBps + params.dividendBps != BPS) {
            revert InvalidDistribution();
        }
        if (params.marketBps != 0 && params.marketAddress == address(0)) revert MarketReceiverRequired();
        if (params.dividendBps != 0 && params.dividendAddress == address(0)) revert DividendRequired();
        if (params.feeRate > BPS) revert InvalidProtocolFee();
        if (params.commissionBps > BPS) revert InvalidCommission();
        if (params.commissionBps != 0 && params.commissionReceiver == address(0)) revert InvalidCommission();

        _initialized = true;
        taxToken = params.taxToken;
        router = params.router;
        feeReceiver = params.feeReceiver;
        marketAddress = params.marketAddress;
        dividendAddress = params.dividendAddress;
        commissionReceiver = params.commissionReceiver;
        converter = params.converter;
        quoteToken = params.quoteToken;
        liqExpectedOutputAmount = params.liqExpectedOutputAmount;

        _marketBps = params.marketBps;
        _deflationBps = params.deflationBps;
        _lpBps = params.lpBps;
        _dividendBps = params.dividendBps;
        _feeRate = params.feeRate;
        commissionBps = params.commissionBps;

        address resolvedQuote = getQuoteToken();
        if (resolvedQuote == address(0)) revert QuoteTokenUnavailable();
        address resolvedDividend = params.dividendToken == address(0) ? resolvedQuote : params.dividendToken;
        if (resolvedDividend != resolvedQuote) revert UnsupportedDividendToken();
        dividendToken = resolvedDividend;

        emit Initialized(params.taxToken, params.dividendAddress);
    }

    /// @notice Pull tax tokens from the token and return the previous keeper direction signal.
    function processTaxTokens(uint256 taxAmount) external override onlyTaxToken returns (int8 direction) {
        if (taxAmount == 0) return 0;
        direction = pendingDirection;
        if (direction != 0) pendingDirection = 0;

        uint256 beforeBalance = IERC20(taxToken).balanceOf(address(this));
        TransferHelper.safeTransferFrom(taxToken, msg.sender, address(this), taxAmount);
        uint256 received = IERC20(taxToken).balanceOf(address(this)) - beforeBalance;
        emit TaxQueued(received, pendingTaxTokens());
    }

    /// @notice Split and process one queued DEX-tax batch. All price-sensitive work is keeper gated.
    function processPendingTax(uint256 amountIn, uint256 minQuoteOut, uint64 deadline)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 out)
    {
        if (amountIn == 0 || amountIn > pendingTaxTokens()) revert InvalidTaxAmount();
        _checkDeadline(deadline);

        (
            uint256 feeTokens,
            uint256 commissionTokens,
            uint256 marketTokens,
            uint256 burnTokens,
            uint256 lpTokens,
            uint256 dividendTokens
        ) = _splitTax(amountIn);

        uint256 lpReserve = lpTokens / 2;
        uint256 lpSwap = lpTokens - lpReserve;
        uint256 swapAmount = feeTokens + commissionTokens + marketTokens + lpSwap + dividendTokens;
        if (burnTokens != 0) {
            totalTaxTokenBurned += burnTokens;
            TransferHelper.safeTransfer(taxToken, DEAD, burnTokens);
        }
        lpTokenBalance += lpReserve;

        if (swapAmount != 0) {
            if (minQuoteOut == 0) revert UnsafeMinQuoteOut();
            out = _swap(taxToken, getQuoteToken(), swapAmount, minQuoteOut, deadline);
            _creditSwapOutput(out, swapAmount, commissionTokens, marketTokens, lpSwap, dividendTokens);
            _reconcileQuoteDonation();
        }

        int8 direction;
        if (swapAmount != 0 && liqExpectedOutputAmount != 0) {
            if (out > liqExpectedOutputAmount) direction = -1;
            else if (out < liqExpectedOutputAmount) direction = 1;
        }
        pendingDirection = direction;

        _dispatch();
        emit TaxProcessed(amountIn, out, burnTokens, lpReserve, direction);
    }

    /// @notice Account bonding-curve quote tax using the same configured channel ownership.
    function processBondingCurveTax(uint256 quoteAmount) external override onlyTaxToken nonReentrant {
        if (quoteAmount == 0) return;
        address quote = getQuoteToken();
        uint256 beforeBalance = IERC20(quote).balanceOf(address(this));
        TransferHelper.safeTransferFrom(quote, msg.sender, address(this), quoteAmount);
        uint256 received = IERC20(quote).balanceOf(address(this)) - beforeBalance;
        _creditQuoteSplit(received);
        _reconcileQuoteDonation();
        _dispatch();
    }

    /// @notice Retry fixed-recipient transfers and dividend deposits without executing a trade.
    function dispatch() external override nonReentrant {
        _reconcileQuoteDonation();
        _dispatch();
    }

    /// @notice Pair reserved LP tax tokens with already-accounted quote and burn minted LP.
    /// @dev Token-side transfer is measured because FlapTaxTokenV3 taxes this sell into its pool.
    function addPendingLiquidity(
        uint256 tokenAmount,
        uint256 minQuoteAmount,
        uint256 maxQuoteAmount,
        uint256 minLiquidity,
        uint64 deadline
    ) external nonReentrant onlyKeeper returns (uint256 quoteAmount, uint256 liquidity) {
        _checkDeadline(deadline);
        if (tokenAmount == 0 || tokenAmount > lpTokenBalance || lpQuoteBalance == 0) revert LiquidityUnavailable();
        if (minQuoteAmount == 0 || minQuoteAmount > maxQuoteAmount || minLiquidity == 0) {
            revert InvalidLiquidityBounds();
        }

        (address pairAddress, uint256 tokenReserve, uint256 quoteReserve) = _poolReserves();
        lpTokenBalance -= tokenAmount;
        uint256 actualToken = _transferTokenToPair(pairAddress, tokenAmount);
        quoteAmount = actualToken * quoteReserve / tokenReserve;
        if (quoteAmount < minQuoteAmount || quoteAmount > maxQuoteAmount || quoteAmount > lpQuoteBalance) {
            revert InvalidLiquidityBounds();
        }

        lpQuoteBalance -= quoteAmount;
        totalTokenAddedToLiquidity += actualToken;
        totalQuoteAddedToLiquidity += quoteAmount;
        TransferHelper.safeTransfer(getQuoteToken(), pairAddress, quoteAmount);
        liquidity = IPancakePair(pairAddress).mint(DEAD);
        if (liquidity < minLiquidity) revert InsufficientLiquidityOutput();
        emit LiquidityAdded(actualToken, quoteAmount, liquidity);
    }

    /// @notice Convert bonding-curve deflation quote into tax token and burn it.
    function processPendingBurn(uint256 quoteAmount, uint256 minTaxTokenOut, uint64 deadline)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 out)
    {
        if (quoteAmount == 0 || quoteAmount > pendingDeflationQuoteBalance) revert InvalidBurnAmount();
        if (minTaxTokenOut == 0) revert UnsafeMinQuoteOut();
        _checkDeadline(deadline);

        pendingDeflationQuoteBalance -= quoteAmount;
        out = _swap(getQuoteToken(), taxToken, quoteAmount, minTaxTokenOut, deadline);
        totalQuoteBurned += quoteAmount;
        totalTaxTokenBurned += out;
        TransferHelper.safeTransfer(taxToken, DEAD, out);
        emit DeflationQuoteBurned(quoteAmount, out);
    }

    function _splitTax(uint256 amount)
        internal
        view
        returns (
            uint256 feeTokens,
            uint256 commissionTokens,
            uint256 marketTokens,
            uint256 burnTokens,
            uint256 lpTokens,
            uint256 dividendTokens
        )
    {
        feeTokens = amount * _feeRate / BPS;
        uint256 afterFee = amount - feeTokens;
        commissionTokens = afterFee * commissionBps / BPS;
        uint256 distributable = afterFee - commissionTokens;
        marketTokens = distributable * _marketBps / BPS;
        burnTokens = distributable * _deflationBps / BPS;
        lpTokens = distributable * _lpBps / BPS;
        dividendTokens = distributable * _dividendBps / BPS;
        // Channel floors may leave at most a few wei. Assign that dust to the always-valid
        // protocol receiver instead of accidentally activating a configured-zero channel.
        feeTokens += distributable - marketTokens - burnTokens - lpTokens - dividendTokens;
    }

    function _creditSwapOutput(
        uint256 out,
        uint256 denominator,
        uint256 commissionTokens,
        uint256 marketTokens,
        uint256 lpSwap,
        uint256 dividendTokens
    ) internal {
        uint256 commissionOut = out * commissionTokens / denominator;
        uint256 marketOut = out * marketTokens / denominator;
        uint256 lpOut = out * lpSwap / denominator;
        uint256 dividendOut = out * dividendTokens / denominator;
        uint256 feeOut = out - commissionOut - marketOut - lpOut - dividendOut;
        // feeTokens may be zero; assigning integer dust to the protocol fee keeps every wei owned.
        feeQuoteBalance += feeOut;
        commissionQuoteBalance += commissionOut;
        marketQuoteBalance += marketOut;
        lpQuoteBalance += lpOut;
        pendingDividendQuoteTokenBalance += dividendOut;
    }

    function _creditQuoteSplit(uint256 amount) internal {
        (
            uint256 feeAmount,
            uint256 commissionAmount,
            uint256 marketAmount,
            uint256 deflationAmount,
            uint256 lpAmount,
            uint256 dividendAmount
        ) = _splitTax(amount);
        feeQuoteBalance += feeAmount;
        commissionQuoteBalance += commissionAmount;
        marketQuoteBalance += marketAmount;
        pendingDeflationQuoteBalance += deflationAmount;
        lpQuoteBalance += lpAmount;
        pendingDividendQuoteTokenBalance += dividendAmount;
    }

    function _dispatch() internal {
        uint256 feeAmount = feeQuoteBalance;
        uint256 commissionAmount = commissionQuoteBalance;
        uint256 marketAmount = marketQuoteBalance;
        uint256 dividendAmount = pendingDividendQuoteTokenBalance;
        feeQuoteBalance = 0;
        commissionQuoteBalance = 0;
        marketQuoteBalance = 0;
        pendingDividendQuoteTokenBalance = 0;

        if (feeAmount != 0) _forwardQuote(feeReceiver, feeAmount);
        if (commissionAmount != 0) _forwardQuote(commissionReceiver, commissionAmount);
        if (marketAmount != 0) {
            totalQuoteSentToMarketing += marketAmount;
            _forwardQuote(marketAddress, marketAmount);
        }
        if (dividendAmount != 0) _depositDividend(dividendAmount);
    }

    function _depositDividend(uint256 amount) internal {
        address quote = getQuoteToken();
        uint256 beforeBalance = IERC20(quote).balanceOf(address(this));
        TransferHelper.safeApprove(quote, dividendAddress, 0);
        TransferHelper.safeApprove(quote, dividendAddress, amount);
        (bool called, bytes memory data) = dividendAddress.call(abi.encodeCall(IDividend.deposit, (amount)));
        TransferHelper.safeApprove(quote, dividendAddress, 0);
        uint256 afterBalance = IERC20(quote).balanceOf(address(this));
        uint256 consumed = beforeBalance > afterBalance ? beforeBalance - afterBalance : 0;
        if (consumed > amount) revert AccountingInvariant();
        if (consumed != 0) {
            totalDividendTokenSent += consumed;
            emit DividendDeposited(dividendAddress, consumed);
        }
        uint256 unconsumed = amount - consumed;
        if (unconsumed != 0) {
            pendingDividendQuoteTokenBalance += unconsumed;
            emit DividendDepositDeferred(dividendAddress, unconsumed);
        }
        // A false/malformed result is tolerated only because balance delta is authoritative.
        called;
        data;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint64 deadline)
        internal
        returns (uint256 out)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert QuoteTokenUnavailable();
        address weth_ = weth();
        address[] memory path;
        if (tokenIn == weth_ || tokenOut == weth_) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = weth_;
            path[2] = tokenOut;
        }

        uint256 beforeBalance = IERC20(tokenOut).balanceOf(address(this));
        TransferHelper.safeApprove(tokenIn, router, 0);
        TransferHelper.safeApprove(tokenIn, router, amountIn);
        IPancakeRouter02(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, minOut, path, address(this), deadline);
        TransferHelper.safeApprove(tokenIn, router, 0);
        out = IERC20(tokenOut).balanceOf(address(this)) - beforeBalance;
        if (out < minOut) revert InsufficientQuoteOutput();
    }

    function _forwardQuote(address receiver, uint256 amount) internal {
        totalQuoteSentToReceiver += amount;
        address quote = getQuoteToken();
        if (quote != weth()) {
            TransferHelper.safeTransfer(quote, receiver, amount);
            emit TaxForwarded(receiver, amount, false);
            return;
        }

        IWETH(quote).withdraw(amount);
        (bool ok,) = receiver.call{value: amount}("");
        if (ok) {
            emit TaxForwarded(receiver, amount, true);
            return;
        }
        IWETH(quote).deposit{value: amount}();
        TransferHelper.safeTransfer(quote, receiver, amount);
        emit TaxForwarded(receiver, amount, false);
    }

    function _poolReserves() internal view returns (address pairAddress, uint256 tokenReserve, uint256 quoteReserve) {
        pairAddress = IFlapTaxTokenV3(taxToken).mainPool();
        IPancakePair pair = IPancakePair(pairAddress);
        address token0 = pair.token0();
        address token1 = pair.token1();
        address quote = getQuoteToken();
        if (!((token0 == taxToken && token1 == quote) || (token1 == taxToken && token0 == quote))) {
            revert InvalidMainPool();
        }
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        tokenReserve = token0 == taxToken ? reserve0 : reserve1;
        quoteReserve = token0 == taxToken ? reserve1 : reserve0;
        if (tokenReserve == 0 || quoteReserve == 0) revert LiquidityUnavailable();
    }

    function _transferTokenToPair(address pairAddress, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBalance = IERC20(taxToken).balanceOf(pairAddress);
        TransferHelper.safeTransfer(taxToken, pairAddress, amount);
        received = IERC20(taxToken).balanceOf(pairAddress) - beforeBalance;
    }

    function _reconcileQuoteDonation() internal {
        uint256 accounted = feeQuoteBalance + commissionQuoteBalance + marketQuoteBalance + lpQuoteBalance
            + pendingDividendQuoteTokenBalance + pendingDeflationQuoteBalance + dividendTokenBalance;
        uint256 actual = IERC20(getQuoteToken()).balanceOf(address(this));
        if (actual < accounted) revert AccountingInvariant();
        feeQuoteBalance += actual - accounted;
    }

    function _checkDeadline(uint64 deadline) internal view {
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_DELAY) {
            revert InvalidProcessingDeadline();
        }
    }

    function pendingTaxTokens() public view returns (uint256) {
        uint256 balance = IERC20(taxToken).balanceOf(address(this));
        if (balance < lpTokenBalance) revert AccountingInvariant();
        return balance - lpTokenBalance;
    }

    function isWeth() public view returns (bool) {
        return quoteToken == address(0) || quoteToken == weth();
    }

    function weth() public view override returns (address) {
        return router != address(0) ? IPancakeRouter02(router).WETH() : address(0);
    }

    function getQuoteToken() public view override returns (address) {
        return isWeth() ? weth() : quoteToken;
    }

    function flapBlackHole() external pure override returns (address) {
        return DEAD;
    }

    function dividendQuoteBalance() external view override returns (uint256) {
        return pendingDividendQuoteTokenBalance;
    }

    function totalQuoteSentToDividend() external view override returns (uint256) {
        return totalDividendTokenSent;
    }

    function requiresMEVProtection() external pure override returns (bool) {
        return true;
    }

    function feeConfig() external view override returns (PackedFeeConfig memory) {
        return PackedFeeConfig({
            marketBps: _marketBps,
            deflationBps: _deflationBps,
            lpBps: _lpBps,
            dividendBps: _dividendBps,
            feeRate: _feeRate,
            isWeth: isWeth()
        });
    }

    function feeConfigV2() external view override returns (PackedFeeConfigV2 memory) {
        return PackedFeeConfigV2({
            marketBps: _marketBps,
            deflationBps: _deflationBps,
            lpBps: _lpBps,
            dividendBps: _dividendBps,
            feeRate: _feeRate,
            isWeth: isWeth(),
            commissionBps: commissionBps,
            dividendToken: dividendToken
        });
    }
}
