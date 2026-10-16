// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TaxProcessor, IWETH} from "src/TaxProcessor.sol";
import {Clones} from "src/Clones.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";
import {IPancakeRouter02, IPancakeFactory} from "src/lib/interfaces/IPancakeRouter02.sol";

/// @dev Real ERC20 transfer semantics; only the Flap pool getters needed by withdrawal are added.
///      Actual Flap transfer/share callbacks are covered separately by ReaderTest.
contract MainnetForkTaxExitToken is ERC20 {
    mapping(address => bool) public pools;
    address public mainPool;

    constructor() ERC20("Mainnet Fork Tax Exit Token", "MFTE") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function registerPool(address pair) external {
        require(mainPool == address(0), "pool already set");
        mainPool = pair;
        pools[pair] = true;
    }
}

/// @notice Builds actual pending tax/LP/dividend inventory through the BSC Pancake V2 router,
///         then settles it without executing another trade. All transactions are local fork calls.
contract TaxProcessorBscMainnetForkTest is Test {
    address internal constant MAINNET_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant DEAD = address(0xdead);
    address internal constant CREATOR = address(0xC8EA);
    address internal constant RECIPIENT = address(0xBEEF);
    address internal constant FEE = address(0xFEE);
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint8 public executionFlags = 7;

    MainnetForkTaxExitToken internal token;
    IERC20 internal wrapped;
    IPancakeRouter02 internal router;
    TaxProcessor internal processor;
    Dividend internal dividend;

    struct ExitSnapshot {
        uint256 lpToken;
        uint256 lpQuote;
        uint256 pendingDividend;
        uint256 feeNative;
        uint256 feeWrapped;
        uint256 marketingSent;
        uint256 receiverSent;
        uint256 dividendBalance;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == KEEPER_ROLE && account == address(this);
    }

    function tokenCreators(address asset) external view returns (address) {
        return asset == address(token) ? CREATOR : address(0);
    }

    function tokenVaults(address) external pure returns (address) {
        return address(0);
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BSC_RPC_URL not set; mainnet fork test skipped");
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 56, "fork must be BSC mainnet");
        assertGt(MAINNET_ROUTER.code.length, 0, "real Pancake V2 router must exist");
        router = IPancakeRouter02(MAINNET_ROUTER);
        wrapped = IERC20(router.WETH());
        assertGt(address(wrapped).code.length, 0, "real WBNB must exist");
        vm.deal(address(this), 10 ether);

        token = new MainnetForkTaxExitToken();
        token.approve(MAINNET_ROUTER, type(uint256).max);
        router.addLiquidityETH{value: 0.1 ether}(
            address(token), 100_000 ether, 100_000 ether, 0.1 ether, address(this), block.timestamp + 5 minutes
        );
        address pair = IPancakeFactory(router.factory()).getPair(address(token), address(wrapped));
        assertTrue(pair != address(0), "real factory must create a pair");
        token.registerPool(pair);

        Dividend implementation = new Dividend(address(wrapped), DEAD);
        dividend = Dividend(payable(Clones.clone(address(implementation))));
        dividend.initialize(address(wrapped), address(token), 1);
        processor = new TaxProcessor(address(this));
        processor.initialize(_params());
    }

    function _params() internal view returns (TaxProcessorInitParams memory) {
        return TaxProcessorInitParams({
            quoteToken: address(wrapped),
            router: MAINNET_ROUTER,
            feeReceiver: FEE,
            marketAddress: FEE,
            dividendAddress: address(dividend),
            taxToken: address(token),
            feeRate: 0,
            marketBps: 2_500,
            deflationBps: 2_500,
            lpBps: 2_500,
            dividendBps: 2_500,
            dividendToken: address(wrapped),
            commissionReceiver: address(0),
            commissionBps: 0,
            converter: address(0),
            liqExpectedOutputAmount: 0
        });
    }

    function test_mainnetPendingInventoriesExitAndProcessingCanResume() public {
        token.transfer(address(processor), 400 ether);
        assertGt(_process(200 ether), 0, "Pancake must produce real WBNB");
        assertEq(processor.pendingTaxTokens(), 200 ether);
        assertEq(processor.lpTokenBalance(), 25 ether);
        assertGt(processor.lpQuoteBalance(), 0);
        assertGt(processor.pendingDividendQuoteTokenBalance(), 0, "no shares leaves dividend pending");
        assertEq(dividend.totalShares(), 0);
        assertEq(processor.totalDividendTokenSent(), 0);

        // An existing Dividend balance is outside TaxProcessor's withdrawal authority.
        IWETH(address(wrapped)).deposit{value: 0.006 ether}();
        assertTrue(wrapped.transfer(address(dividend), 0.004 ether));
        assertTrue(wrapped.transfer(address(processor), 0.002 ether));
        vm.deal(address(processor), 0.003 ether);
        ExitSnapshot memory beforeExit = _snapshot();

        executionFlags = 0;
        vm.prank(CREATOR);
        processor.withdrawAll(RECIPIENT);
        _assertExit(beforeExit);

        // Pause is reversible: subsequent tax uses the original configured processing path.
        executionFlags = 7;
        token.transfer(address(processor), 40 ether);
        assertGt(_process(40 ether), 0, "processing resumes after withdrawal");
        assertEq(processor.pendingTaxTokens(), 0);
        assertEq(processor.lpTokenBalance(), 5 ether);
        assertGt(processor.lpQuoteBalance(), 0);
        assertGt(processor.pendingDividendQuoteTokenBalance(), 0);
        assertEq(processor.totalTaxTokenBurned(), 110 ether);
        assertEq(wrapped.balanceOf(address(dividend)), beforeExit.dividendBalance);
    }

    function _process(uint256 batch) internal returns (uint256 out) {
        // Equal four-way split: burn 1/4, reserve half of LP's 1/4, swap the remaining 5/8.
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(wrapped);
        uint256 quotedOut = router.getAmountsOut(batch * 5 / 8, path)[1];
        out = processor.processPendingTax(batch, quotedOut * 99 / 100, uint64(block.timestamp + 5 minutes));
    }

    function _snapshot() internal view returns (ExitSnapshot memory result) {
        result.lpToken = processor.lpTokenBalance();
        result.lpQuote = processor.lpQuoteBalance();
        result.pendingDividend = processor.pendingDividendQuoteTokenBalance();
        result.feeNative = FEE.balance;
        result.feeWrapped = wrapped.balanceOf(FEE);
        result.marketingSent = processor.totalQuoteSentToMarketing();
        result.receiverSent = processor.totalQuoteSentToReceiver();
        result.dividendBalance = wrapped.balanceOf(address(dividend));
    }

    function _assertExit(ExitSnapshot memory beforeExit) internal view {
        // The 200 pending tokens split 50 each; creator receives LP + unallocated dividends
        // plus 25 already reserved LP tokens. Market remains fixed; burn remains irreversible.
        assertEq(token.balanceOf(RECIPIENT), beforeExit.lpToken + 100 ether);
        assertEq(token.balanceOf(FEE), 50 ether);
        assertEq(token.balanceOf(DEAD), 100 ether);
        assertEq(wrapped.balanceOf(RECIPIENT), beforeExit.lpQuote + beforeExit.pendingDividend);
        assertEq(wrapped.balanceOf(FEE) - beforeExit.feeWrapped, 0.005 ether);
        assertEq(FEE.balance, beforeExit.feeNative, "withdrawal transfers WBNB without unwrapping");
        assertEq(wrapped.balanceOf(address(dividend)), beforeExit.dividendBalance);
        assertEq(processor.totalDividendTokenSent(), 0, "withdrawal is not a dividend deposit");
        assertEq(processor.totalTokenAddedToLiquidity(), 0, "withdrawal is not LP minting");
        assertEq(processor.totalQuoteAddedToLiquidity(), 0);
        assertEq(processor.totalTaxTokenBurned(), 100 ether);
        assertEq(processor.totalQuoteBurned(), 0);
        assertEq(processor.totalQuoteSentToMarketing(), beforeExit.marketingSent);
        assertEq(processor.totalQuoteSentToReceiver(), beforeExit.receiverSent + 0.005 ether);
        assertEq(address(processor).balance, 0);
        assertEq(token.balanceOf(address(processor)), 0);
        assertEq(wrapped.balanceOf(address(processor)), 0);
        assertEq(processor.pendingTaxTokens(), 0);
        assertEq(processor.lpTokenBalance(), 0);
        assertEq(processor.feeQuoteBalance(), 0);
        assertEq(processor.commissionQuoteBalance(), 0);
        assertEq(processor.marketQuoteBalance(), 0);
        assertEq(processor.lpQuoteBalance(), 0);
        assertEq(processor.pendingDividendQuoteTokenBalance(), 0);
        assertEq(processor.dividendTokenBalance(), 0);
        assertEq(processor.pendingDeflationQuoteBalance(), 0);
    }

    receive() external payable {}
}
