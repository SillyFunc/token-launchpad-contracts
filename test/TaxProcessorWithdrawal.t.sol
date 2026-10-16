// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {TransferHelper} from "src/TransferHelper.sol";
import {TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";

interface ITaxProcessorExit {
    function withdrawAll(address recipient) external;
}

contract ExitToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public pools;
    address public mainPool;
    address public failedRecipient;
    address public hookRecipient;
    address public transferHook;
    bytes public hookData;
    bool public hookTaxQueued;

    function setPool(address pool) external {
        pools[pool] = true;
        if (mainPool == address(0)) mainPool = pool;
    }

    function failTransfersTo(address recipient) external {
        failedRecipient = recipient;
    }

    function setTransferHook(address recipient, address hook, bytes calldata data) external {
        hookRecipient = recipient;
        transferHook = hook;
        hookData = data;
    }

    /// @dev Model Flap's authorized token -> processor callback with actual balance movement.
    function queueTaxesFromHook(address processor, uint256 amount) external {
        require(msg.sender == address(this), "token callback only");
        if (hookTaxQueued) return;
        hookTaxQueued = true;
        allowance[address(this)][processor] = amount;
        TaxProcessor(payable(processor)).processTaxTokens(amount);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to == hookRecipient && transferHook != address(0)) {
            (bool called,) = transferHook.call(hookData);
            require(called, "transfer hook failed");
        }
        return to != failedRecipient;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ExitWrappedBNB is ExitToken {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "unwrap failed");
    }
}

contract ExitRouter {
    address public immutable WETH;

    constructor(address wrapped) {
        WETH = wrapped;
    }
}

contract TaxProcessorExitHarness is TaxProcessor {
    constructor(address registry) TaxProcessor(registry) {}

    function seedLpTokens(uint256 amount) external {
        lpTokenBalance = amount;
    }

    function seedQuoteBalances(
        uint256 fee,
        uint256 commission,
        uint256 market,
        uint256 lp,
        uint256 pendingDividend,
        uint256 dividend,
        uint256 burn
    ) external {
        feeQuoteBalance = fee;
        commissionQuoteBalance = commission;
        marketQuoteBalance = market;
        lpQuoteBalance = lp;
        pendingDividendQuoteTokenBalance = pendingDividend;
        dividendTokenBalance = dividend;
        pendingDeflationQuoteBalance = burn;
    }

    function seedExistingStatistics() external {
        totalDividendTokenSent = 29;
        totalQuoteAddedToLiquidity = 31;
        totalTokenAddedToLiquidity = 37;
        totalQuoteSentToMarketing = 41;
        totalQuoteSentToReceiver = 43;
        totalTaxTokenBurned = 47;
        totalQuoteBurned = 53;
        pendingDirection = 1;
    }
}

contract ExitReentrantCreator {
    address public processor;
    address public recipient;
    bool public nestedSucceeded;
    uint256 public attempts;

    function start(address processor_, address recipient_) external {
        processor = processor_;
        recipient = recipient_;
        ITaxProcessorExit(processor_).withdrawAll(recipient_);
    }

    function onTransfer() external {
        attempts++;
        (nestedSucceeded,) = processor.call(abi.encodeCall(ITaxProcessorExit.withdrawAll, (recipient)));
    }
}

contract TaxProcessorWithdrawalTest is Test {
    ExitToken internal token;
    ExitWrappedBNB internal wrapped;
    ExitRouter internal router;
    TaxProcessorExitHarness internal processor;
    address internal constant CREATOR = address(0xC8EA);
    address internal constant RECIPIENT = address(0xBEEF);
    address internal constant FEE = address(0xFEE);
    address internal constant MARKET = address(0xA11CE);
    address internal constant COMMISSION = address(0xC011);
    address internal constant DIVIDEND = address(0xD1);
    address internal constant DEAD = address(0xdead);
    uint8 public executionFlags;
    address internal _creator = CREATOR;
    address internal _vault;
    bool internal _failRegistry;

    event TaxAssetsWithdrawn(address indexed creator, address indexed asset, address indexed recipient, uint256 amount);

    function tokenCreators(address asset) external view returns (address) {
        require(!_failRegistry, "registry unavailable");
        return asset == address(token) ? _creator : address(0);
    }

    function tokenVaults(address asset) external view returns (address) {
        require(!_failRegistry, "registry unavailable");
        return asset == address(token) ? _vault : address(0);
    }

    function setUp() public {
        token = new ExitToken();
        wrapped = new ExitWrappedBNB();
        router = new ExitRouter(address(wrapped));
        processor = _newProcessor(_params());
    }

    function _params() internal view returns (TaxProcessorInitParams memory) {
        return TaxProcessorInitParams({
            quoteToken: address(wrapped),
            router: address(router),
            feeReceiver: FEE,
            marketAddress: FEE,
            dividendAddress: address(0),
            taxToken: address(token),
            feeRate: 0,
            marketBps: 0,
            deflationBps: 0,
            lpBps: 10_000,
            dividendBps: 0,
            dividendToken: address(wrapped),
            commissionReceiver: address(0),
            commissionBps: 0,
            converter: address(0),
            liqExpectedOutputAmount: 0
        });
    }

    function _newProcessor(TaxProcessorInitParams memory params) internal returns (TaxProcessorExitHarness result) {
        result = new TaxProcessorExitHarness(address(this));
        result.initialize(params);
    }

    function _withdraw(TaxProcessorExitHarness target) internal {
        vm.prank(_creator);
        ITaxProcessorExit(address(target)).withdrawAll(RECIPIENT);
    }

    function _assertEmptyBooks(TaxProcessorExitHarness target) internal view {
        assertEq(target.lpTokenBalance(), 0, "lp token ledger");
        assertEq(target.feeQuoteBalance(), 0, "fee quote ledger");
        assertEq(target.commissionQuoteBalance(), 0, "commission quote ledger");
        assertEq(target.marketQuoteBalance(), 0, "market quote ledger");
        assertEq(target.lpQuoteBalance(), 0, "lp quote ledger");
        assertEq(target.pendingDividendQuoteTokenBalance(), 0, "pending dividend ledger");
        assertEq(target.dividendTokenBalance(), 0, "dividend token ledger");
        assertEq(target.pendingDeflationQuoteBalance(), 0, "deflation quote ledger");
        assertEq(target.pendingDirection(), 0, "stale threshold direction");
    }

    function test_CreatorExitsOneSidedLiquidityTokensWithoutDex() public {
        token.mint(address(processor), 13);
        processor.seedLpTokens(13);
        vm.prank(CREATOR);
        ITaxProcessorExit(address(processor)).withdrawAll(RECIPIENT);
        assertEq(token.balanceOf(RECIPIENT), 13);
        assertEq(token.balanceOf(address(processor)), 0);
        assertEq(processor.lpTokenBalance(), 0);
    }

    function test_MixedAssetsPreserveEveryChannelAndExistingDividend() public {
        TaxProcessorInitParams memory params = _params();
        params.feeRate = 1_000;
        params.commissionBps = 1_000;
        params.commissionReceiver = COMMISSION;
        params.marketAddress = MARKET;
        params.dividendAddress = DIVIDEND;
        params.marketBps = 2_500;
        params.deflationBps = 2_500;
        params.lpBps = 2_500;
        params.dividendBps = 2_500;
        TaxProcessorExitHarness target = _newProcessor(params);

        token.mint(address(target), 10_013);
        target.seedLpTokens(13);
        target.seedQuoteBalances(2, 3, 5, 7, 11, 13, 17);
        // 58 accounted + 19 donated quote + 23 donated native BNB.
        wrapped.mint(address(target), 77);
        wrapped.mint(DIVIDEND, 101);
        vm.deal(address(target), 23);
        target.seedExistingStatistics();

        _withdraw(target);

        assertEq(token.balanceOf(FEE), 1_000);
        assertEq(token.balanceOf(COMMISSION), 900);
        assertEq(token.balanceOf(MARKET), 2_025);
        assertEq(token.balanceOf(DEAD), 2_025);
        assertEq(token.balanceOf(RECIPIENT), 4_063);
        assertEq(wrapped.balanceOf(FEE), 44, "fee receives quote dust and wrapped native donation");
        assertEq(wrapped.balanceOf(COMMISSION), 3);
        assertEq(wrapped.balanceOf(MARKET), 5);
        assertEq(wrapped.balanceOf(DEAD), 17);
        assertEq(wrapped.balanceOf(RECIPIENT), 31);
        assertEq(wrapped.balanceOf(DIVIDEND), 101, "deposited holder assets are untouched");
        assertEq(token.balanceOf(address(target)), 0);
        assertEq(wrapped.balanceOf(address(target)), 0);
        assertEq(address(target).balance, 0);
        _assertEmptyBooks(target);

        assertEq(target.totalDividendTokenSent(), 29, "no fake dividend deposit");
        assertEq(target.totalQuoteAddedToLiquidity(), 31, "no fake quote liquidity");
        assertEq(target.totalTokenAddedToLiquidity(), 37, "no fake token liquidity");
        assertEq(target.totalQuoteSentToMarketing(), 46);
        assertEq(target.totalQuoteSentToReceiver(), 95);
        assertEq(target.totalTaxTokenBurned(), 2_072);
        assertEq(target.totalQuoteBurned(), 70);
    }

    function test_OnlyOriginalCreatorCanExitIncludingWhenAdminOrKeeperCalls() public {
        token.mint(address(processor), 7);
        address[3] memory callers = [address(this), address(0xCA11), address(0xBAD)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(bytes4(keccak256("UnauthorizedTaxCreator()")));
            vm.prank(callers[i]);
            ITaxProcessorExit(address(processor)).withdrawAll(RECIPIENT);
        }
        assertEq(token.balanceOf(address(processor)), 7);
    }

    function test_EitherActiveProcessingFlagBlocksExit() public {
        token.mint(address(processor), 7);
        for (uint8 flags = 1; flags <= 7; ++flags) {
            if ((flags & 3) == 0) continue;
            executionFlags = flags;
            vm.expectRevert(bytes4(keccak256("TaxProcessingActive()")));
            vm.prank(CREATOR);
            ITaxProcessorExit(address(processor)).withdrawAll(RECIPIENT);
        }
        assertEq(token.balanceOf(address(processor)), 7);
    }

    function test_BuybackFlagMayRemainEnabledDuringExit() public {
        executionFlags = 4;
        token.mint(address(processor), 7);
        _withdraw(processor);
        assertEq(token.balanceOf(RECIPIENT), 7);
    }

    function test_RegistryFailureCannotBypassCreatorCheck() public {
        _failRegistry = true;
        vm.expectRevert(bytes("registry unavailable"));
        vm.prank(CREATOR);
        ITaxProcessorExit(address(processor)).withdrawAll(RECIPIENT);
    }

    function test_UnsafeRecipientsRevertWithoutAssetChanges() public {
        address firstPool = address(0xAA01);
        address secondaryPool = address(0xAA02);
        token.setPool(firstPool);
        token.setPool(secondaryPool);
        TaxProcessorInitParams memory params = _params();
        params.lpBps = 5_000;
        params.dividendBps = 5_000;
        params.dividendAddress = DIVIDEND;
        TaxProcessorExitHarness target = _newProcessor(params);
        token.mint(address(target), 9);
        address[8] memory bad = [
            address(0),
            address(target),
            address(token),
            DIVIDEND,
            address(router),
            address(wrapped),
            firstPool,
            secondaryPool
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(bytes4(keccak256("InvalidTaxWithdrawalRecipient()")));
            vm.prank(CREATOR);
            ITaxProcessorExit(address(target)).withdrawAll(bad[i]);
        }
        assertEq(token.balanceOf(address(target)), 9);
    }

    function test_OriginalFixedTaxRecipientThatIsPoolIsRejected() public {
        token.setPool(MARKET);
        TaxProcessorInitParams memory params = _params();
        params.marketAddress = MARKET;
        params.lpBps = 0;
        params.marketBps = 10_000;
        TaxProcessorExitHarness target = _newProcessor(params);
        token.mint(address(target), 9);
        vm.expectRevert(bytes4(keccak256("InvalidTaxWithdrawalRecipient()")));
        _withdraw(target);
        assertEq(token.balanceOf(address(target)), 9);
    }

    function test_QuoteAndWrappedContractsAreBothRejectedAsRecipient() public {
        ExitToken quote = new ExitToken();
        TaxProcessorInitParams memory params = _params();
        params.quoteToken = address(quote);
        params.dividendToken = address(quote);
        TaxProcessorExitHarness target = _newProcessor(params);
        vm.expectRevert(bytes4(keccak256("InvalidTaxWithdrawalRecipient()")));
        vm.prank(CREATOR);
        ITaxProcessorExit(address(target)).withdrawAll(address(quote));
        vm.expectRevert(bytes4(keccak256("InvalidTaxWithdrawalRecipient()")));
        vm.prank(CREATOR);
        ITaxProcessorExit(address(target)).withdrawAll(address(wrapped));
    }

    function test_TaxTokenCannotAlsoBeQuoteAsset() public {
        TaxProcessorInitParams memory params = _params();
        params.quoteToken = address(token);
        params.dividendToken = address(token);
        TaxProcessorExitHarness target = _newProcessor(params);
        token.mint(address(target), 17);
        vm.expectRevert(bytes4(keccak256("QuoteTokenUnavailable()")));
        _withdraw(target);
        assertEq(token.balanceOf(address(target)), 17);
    }

    function test_TaxTokenCannotAlsoBeWrappedNativeAsset() public {
        ExitToken quote = new ExitToken();
        TaxProcessorInitParams memory params = _params();
        params.taxToken = address(wrapped);
        params.quoteToken = address(quote);
        params.dividendToken = address(quote);
        token = ExitToken(address(wrapped)); // Registry recognizes this fixture's actual tax token.
        TaxProcessorExitHarness target = _newProcessor(params);
        wrapped.mint(address(target), 17);
        vm.expectRevert(bytes4(keccak256("QuoteTokenUnavailable()")));
        _withdraw(target);
        assertEq(wrapped.balanceOf(address(target)), 17);
    }

    function test_InsufficientQuoteBackingRevertsIncludingNativeWrapping() public {
        processor.seedQuoteBalances(0, 0, 0, 11, 0, 0, 0);
        wrapped.mint(address(processor), 7);
        vm.deal(address(processor), 3);
        vm.expectRevert(bytes4(keccak256("AccountingInvariant()")));
        _withdraw(processor);
        assertEq(processor.lpQuoteBalance(), 11);
        assertEq(processor.feeQuoteBalance(), 0);
        assertEq(wrapped.balanceOf(address(processor)), 7);
        assertEq(address(processor).balance, 3);
        assertEq(wrapped.balanceOf(RECIPIENT), 0);
    }

    function test_InsufficientLpTokenBackingRevertsDonationReconciliation() public {
        processor.seedLpTokens(11);
        token.mint(address(processor), 10);
        wrapped.mint(address(processor), 7);
        vm.expectRevert(bytes4(keccak256("AccountingInvariant()")));
        _withdraw(processor);
        assertEq(processor.lpTokenBalance(), 11);
        assertEq(processor.feeQuoteBalance(), 0, "donation reconciliation was rolled back");
        assertEq(token.balanceOf(address(processor)), 10);
        assertEq(wrapped.balanceOf(address(processor)), 7);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(wrapped.balanceOf(FEE), 0);
    }

    function test_OneSidedQuoteAndUnallocatedDividendExitWithoutDeposit() public {
        TaxProcessorInitParams memory params = _params();
        params.lpBps = 5_000;
        params.dividendBps = 5_000;
        params.dividendAddress = DIVIDEND; // No callable deposit implementation is required to exit.
        TaxProcessorExitHarness target = _newProcessor(params);
        target.seedQuoteBalances(0, 0, 0, 7, 11, 13, 0);
        wrapped.mint(address(target), 31);
        _withdraw(target);
        assertEq(wrapped.balanceOf(RECIPIENT), 31);
        assertEq(target.totalDividendTokenSent(), 0);
        _assertEmptyBooks(target);
    }

    function test_LateTaxCanExitAgainAfterFirstWithdrawal() public {
        token.mint(address(processor), 17);
        _withdraw(processor);
        token.mint(address(token), 23);
        vm.startPrank(address(token));
        token.approve(address(processor), 23);
        processor.processTaxTokens(23);
        vm.stopPrank();
        _withdraw(processor);
        assertEq(token.balanceOf(RECIPIENT), 40);
        assertEq(processor.pendingTaxTokens(), 0);
    }

    function test_TaxQueuedDuringTransferRemainsPendingForNextWithdrawal() public {
        token.mint(address(processor), 17);
        processor.seedLpTokens(17);
        token.mint(address(token), 23);
        token.setTransferHook(
            RECIPIENT, address(token), abi.encodeCall(ExitToken.queueTaxesFromHook, (address(processor), 23))
        );

        _withdraw(processor);

        assertTrue(token.hookTaxQueued());
        assertEq(token.balanceOf(RECIPIENT), 17, "first withdrawal pays its entry snapshot");
        assertEq(token.balanceOf(address(token)), 0, "token callback actually moved new tax");
        assertEq(token.balanceOf(address(processor)), 23);
        assertEq(processor.lpTokenBalance(), 0);
        assertEq(processor.pendingTaxTokens(), 23, "callback's new tax is not cleared after transfer");

        _withdraw(processor);

        assertEq(token.balanceOf(RECIPIENT), 40);
        assertEq(token.balanceOf(address(processor)), 0);
        assertEq(processor.pendingTaxTokens(), 0);
        _assertEmptyBooks(processor);
    }

    function test_EmptyRepeatedExitSucceedsWithoutChangingCounters() public {
        processor.seedExistingStatistics();
        _withdraw(processor);
        _withdraw(processor);
        _assertEmptyBooks(processor);
        assertEq(processor.totalQuoteSentToReceiver(), 43);
        assertEq(processor.totalQuoteSentToMarketing(), 41);
        assertEq(processor.totalDividendTokenSent(), 29);
        assertEq(processor.totalTaxTokenBurned(), 47);
        assertEq(processor.totalQuoteBurned(), 53);
    }

    function test_DustUsesOriginalFeeRecipientWithoutActivatingZeroChannel() public {
        TaxProcessorInitParams memory params = _params();
        params.marketAddress = MARKET;
        params.marketBps = 3_333;
        params.deflationBps = 3_333;
        params.lpBps = 3_334;
        TaxProcessorExitHarness target = _newProcessor(params);
        token.mint(address(target), 1);
        _withdraw(target);
        assertEq(token.balanceOf(FEE), 1);
        assertEq(token.balanceOf(MARKET), 0);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_RawTaxForRegisteredVaultPaysCreatorWithoutTrappingNewAssets() public {
        _vault = address(0x7A017);
        TaxProcessorInitParams memory params = _params();
        params.feeReceiver = _vault;
        params.marketAddress = _vault;
        params.lpBps = 0;
        params.marketBps = 10_000;
        TaxProcessorExitHarness target = _newProcessor(params);
        token.mint(address(target), 17);
        target.seedQuoteBalances(3, 0, 5, 0, 0, 0, 0);
        wrapped.mint(address(target), 8);
        _withdraw(target);
        assertEq(token.balanceOf(RECIPIENT), 17);
        assertEq(token.balanceOf(_vault), 0, "vault cannot sweep its tax token");
        assertEq(wrapped.balanceOf(_vault), 8, "already converted fixed income still reaches vault");
        assertEq(wrapped.balanceOf(RECIPIENT), 0);
    }

    function test_RegisteredVaultCannotBeChosenAsExitRecipient() public {
        _vault = address(0x7A017);
        token.mint(address(processor), 17);
        processor.seedLpTokens(17);
        vm.expectRevert(bytes4(keccak256("InvalidTaxWithdrawalRecipient()")));
        vm.prank(CREATOR);
        ITaxProcessorExit(address(processor)).withdrawAll(_vault);
        assertEq(token.balanceOf(address(processor)), 17);
        assertEq(token.balanceOf(_vault), 0);
        assertEq(processor.lpTokenBalance(), 17);
    }

    function test_OrdinaryReceiverCannotBeRedirectedByUnrelatedVaultRecord() public {
        _vault = address(0x7A017);
        TaxProcessorInitParams memory params = _params();
        params.marketAddress = MARKET;
        params.lpBps = 0;
        params.marketBps = 10_000;
        TaxProcessorExitHarness target = _newProcessor(params);
        token.mint(address(target), 17);
        _withdraw(target);
        assertEq(token.balanceOf(MARKET), 17);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function test_NonWbnbQuoteAndNativeDonationHaveSeparateOwners() public {
        ExitToken quote = new ExitToken();
        TaxProcessorInitParams memory params = _params();
        params.quoteToken = address(quote);
        params.dividendToken = address(quote);
        TaxProcessorExitHarness target = _newProcessor(params);
        target.seedQuoteBalances(0, 0, 0, 7, 0, 0, 0);
        quote.mint(address(target), 12); // 7 LP + 5 quote donation.
        wrapped.mint(address(target), 11); // Direct WBNB donation.
        vm.deal(address(target), 13);
        _withdraw(target);
        assertEq(quote.balanceOf(RECIPIENT), 7);
        assertEq(quote.balanceOf(FEE), 5);
        assertEq(wrapped.balanceOf(FEE), 24);
        assertEq(wrapped.balanceOf(RECIPIENT), 0);
        assertEq(address(target).balance, 0);
        assertEq(wrapped.balanceOf(address(target)), 0);
        assertEq(quote.balanceOf(address(target)), 0);
    }

    function test_FalseRawTokenTransferRollsBackAllBalancesAndBooks() public {
        token.mint(address(processor), 7);
        processor.seedLpTokens(7);
        processor.seedQuoteBalances(0, 0, 0, 11, 0, 0, 0);
        wrapped.mint(address(processor), 11);
        vm.deal(address(processor), 3);
        token.failTransfersTo(RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(TransferHelper.TransferFailed.selector, address(token), RECIPIENT));
        _withdraw(processor);
        assertEq(token.balanceOf(address(processor)), 7);
        assertEq(wrapped.balanceOf(address(processor)), 11);
        assertEq(address(processor).balance, 3, "native wrapping rolled back");
        assertEq(processor.lpTokenBalance(), 7);
        assertEq(processor.lpQuoteBalance(), 11);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function test_FalseQuoteTransferRollsBackEarlierRawTokenPayments() public {
        token.mint(address(processor), 7);
        processor.seedLpTokens(7);
        processor.seedQuoteBalances(0, 0, 0, 11, 0, 0, 0);
        wrapped.mint(address(processor), 11);
        wrapped.failTransfersTo(RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(TransferHelper.TransferFailed.selector, address(wrapped), RECIPIENT));
        _withdraw(processor);
        assertEq(token.balanceOf(address(processor)), 7);
        assertEq(wrapped.balanceOf(address(processor)), 11);
        assertEq(processor.lpTokenBalance(), 7);
        assertEq(processor.lpQuoteBalance(), 11);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function test_ReentrantCreatorCallbackCannotWithdrawTwice() public {
        ExitReentrantCreator creator = new ExitReentrantCreator();
        _creator = address(creator);
        token.mint(address(processor), 17);
        token.setTransferHook(RECIPIENT, address(creator), abi.encodeCall(ExitReentrantCreator.onTransfer, ()));
        creator.start(address(processor), RECIPIENT);
        assertEq(creator.attempts(), 1);
        assertFalse(creator.nestedSucceeded());
        assertEq(token.balanceOf(RECIPIENT), 17);
        assertEq(token.balanceOf(address(processor)), 0);
    }

    function test_ExitEmitsAssetAndRecipientAmounts() public {
        token.mint(address(processor), 17);
        vm.expectEmit(true, true, true, true, address(processor));
        emit TaxAssetsWithdrawn(CREATOR, address(token), RECIPIENT, 17);
        _withdraw(processor);
    }
}
