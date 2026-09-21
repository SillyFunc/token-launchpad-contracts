// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {
    TaxProcessor,
    AlreadyInitialized,
    NotDeployer,
    TaxTokenRequired,
    RouterRequired,
    FeeReceiverRequired,
    NotTaxToken,
    KeeperRegistryRequired,
    UnauthorizedTaxKeeper,
    InvalidTaxAmount,
    UnsafeMinQuoteOut,
    InvalidProcessingDeadline
} from "src/TaxProcessor.sol";
import {TaxProcessorInitParams, PackedFeeConfig} from "src/lib/interfaces/ITaxProcessor.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice 模拟路由：1:1 兑换（输出铸造到 path 末位代币）；可注入兑换失败
contract MockSwapRouter {
    address public weth;
    bool public failSwap;

    constructor(address _weth) {
        weth = _weth;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function setFailSwap(bool v) external {
        failSwap = v;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        if (failSwap) revert("mock: swap failed");
        require(amountIn >= amountOutMin, "mock: insufficient output");
        // 1:1 模拟兑换：拉取 path[0]，铸 path 末位代币给接收方
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(path[path.length - 1]).mint(to, amountIn);
    }
}

/// @notice 可解包/包装原生币的模拟 WBNB
contract MockWBNB is MockERC20 {
    constructor() MockERC20("WBNB", "WBNB") {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
}

/// @notice 无 receive/fallback 的收款合约：拒收原生 BNB（测试 WBNB 兜底路径）
contract NoReceiveReceiver {}

contract MockDividend {
    MockERC20 public immutable token;
    bool public failDeposit;
    uint256 public totalDeposited;

    constructor(MockERC20 token_) {
        token = token_;
    }

    function setFailDeposit(bool value) external {
        failDeposit = value;
    }

    function deposit(uint256 amount) external returns (bool) {
        if (failDeposit) revert("mock: dividend failed");
        token.transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        return true;
    }
}

contract TaxProcessorTest is Test {
    MockERC20 taxToken;
    MockWBNB wbnb;
    MockSwapRouter router;
    TaxProcessor tp;

    address feeReceiver = address(0xfee1);
    address keeper = address(0xCA11);

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == keccak256("KEEPER_ROLE") && account == keeper;
    }

    function setUp() public {
        taxToken = new MockERC20("Tax", "TAX");
        wbnb = new MockWBNB();
        router = new MockSwapRouter(address(wbnb));
        tp = new TaxProcessor(address(this));

        // MockWBNB 凭空铸出 WBNB，需预注 native 偿付 withdraw 解包
        vm.deal(address(wbnb), 1_000_000 ether);

        tp.initialize(_params(0));

        taxToken.mint(address(taxToken), 1000000 ether); // 模拟 V3：税在代币合约自己手里
        vm.prank(address(taxToken));
        taxToken.approve(address(tp), type(uint256).max); // 模拟 V3 的 _processTax 无限授权
    }

    function _params(uint256 expectedOut) internal view returns (TaxProcessorInitParams memory) {
        return TaxProcessorInitParams({
            quoteToken: address(wbnb),
            router: address(router),
            feeReceiver: feeReceiver,
            marketAddress: feeReceiver,
            dividendAddress: address(0),
            taxToken: address(taxToken),
            feeRate: 0,
            marketBps: 10_000,
            deflationBps: 0,
            lpBps: 0,
            dividendBps: 0,
            dividendToken: address(0),
            commissionReceiver: address(0),
            commissionBps: 0,
            converter: address(0),
            liqExpectedOutputAmount: expectedOut
        });
    }

    /// @notice 为新 processor 实例补充模拟 V3 的无限授权
    function _authorize(TaxProcessor processor) internal {
        vm.prank(address(taxToken));
        taxToken.approve(address(processor), type(uint256).max);
    }

    function _queue(TaxProcessor processor, uint256 amount) internal returns (int8 direction) {
        vm.prank(address(taxToken));
        direction = processor.processTaxTokens(amount);
    }

    function _process(TaxProcessor processor, uint256 amount, uint256 minOut) internal returns (uint256 out) {
        vm.prank(keeper);
        out = processor.processPendingTax(amount, minOut, uint64(block.timestamp + 1 minutes));
    }

    // -------------------------------------------------------------------------
    // 主路径：swap → 原生 BNB → 收款人
    // -------------------------------------------------------------------------

    function test_ForwardsNativeToReceiver() public {
        int8 direction = _queue(tp, 10000 ether);

        assertEq(direction, 0, "no reference -> no direction");
        assertEq(feeReceiver.balance, 0, "queueing never swaps inside user transfer");
        assertEq(taxToken.balanceOf(address(tp)), 10000 ether, "tax remains queued");

        assertEq(_process(tp, 10000 ether, 9900 ether), 10000 ether);
        assertEq(feeReceiver.balance, 10000 ether, "receiver got native BNB");
        assertEq(wbnb.balanceOf(address(tp)), 0, "no WBNB dust left");
        assertEq(address(tp).balance, 0, "no native dust left");
        assertEq(taxToken.balanceOf(address(tp)), 0, "all tax tokens swapped");
        assertEq(tp.totalQuoteSentToReceiver(), 10000 ether);

        // 第二轮：keeper 清算后累计器与收款余额继续叠加
        _queue(tp, 5000 ether);
        _process(tp, 5000 ether, 4900 ether);
        assertEq(feeReceiver.balance, 15000 ether);
        assertEq(tp.totalQuoteSentToReceiver(), 15000 ether);
    }

    function test_SwapFailureRetainsTokensForKeeperRetry() public {
        router.setFailSwap(true);
        _queue(tp, 10000 ether);

        vm.expectRevert("mock: swap failed");
        vm.prank(keeper);
        tp.processPendingTax(10000 ether, 9900 ether, uint64(block.timestamp + 1 minutes));

        assertEq(taxToken.balanceOf(address(tp)), 10000 ether, "failed swap keeps retryable tax tokens");
        assertEq(taxToken.balanceOf(feeReceiver), 0, "raw tax token never leaks into vault/receiver");
        assertEq(feeReceiver.balance, 0);
        assertEq(tp.totalQuoteSentToReceiver(), 0);

        router.setFailSwap(false);
        _process(tp, 10000 ether, 9900 ether);
        assertEq(taxToken.balanceOf(address(tp)), 0);
        assertEq(feeReceiver.balance, 10000 ether);
    }

    function test_ReceiverRejectsNativeFallsBackToWBNB() public {
        NoReceiveReceiver rejecter = new NoReceiveReceiver();

        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.feeReceiver = address(rejecter);
        p.marketAddress = address(rejecter);
        tp2.initialize(p);
        _authorize(tp2);

        _queue(tp2, 10000 ether);
        _process(tp2, 10000 ether, 9900 ether);

        // 原生转账被拒 → 包回 WBNB 走 ERC20，资金不锁死
        assertEq(wbnb.balanceOf(address(rejecter)), 10000 ether, "WBNB ERC20 fallback");
        assertEq(address(tp2).balance, 0, "no native stuck");
        assertEq(wbnb.balanceOf(address(tp2)), 0, "no WBNB stuck");
        assertEq(tp2.totalQuoteSentToReceiver(), 10000 ether);
    }

    function test_QuoteTokenNotWethForwardsERC20() public {
        MockERC20 usdt = new MockERC20("USDT", "USDT");
        MockSwapRouter router2 = new MockSwapRouter(address(wbnb));

        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.quoteToken = address(usdt);
        p.router = address(router2);
        tp2.initialize(p);
        _authorize(tp2);

        _queue(tp2, 10000 ether);
        _process(tp2, 10000 ether, 9900 ether);

        // path: taxToken → WBNB → USDT，1:1 输出以 USDT 形态 ERC20 直转
        assertEq(usdt.balanceOf(feeReceiver), 10000 ether);
        assertEq(feeReceiver.balance, 0, "no native for non-weth quote");
    }

    // -------------------------------------------------------------------------
    // 方向信号（动态清算阈值）
    // -------------------------------------------------------------------------

    function test_DirectionSignal() public {
        // 参考低于输出（out=10000 > 5000）→ 价格强 → -1
        TaxProcessor tp2 = new TaxProcessor(address(this));
        tp2.initialize(_params(5000 ether));
        _authorize(tp2);
        _queue(tp2, 10000 ether);
        _process(tp2, 10000 ether, 9900 ether);
        assertEq(_queue(tp2, 1 ether), -1, "processed direction is applied on the next liquidation cycle");

        // 参考高于输出（out=10000 < 20000）→ 价格弱 → +1
        TaxProcessor tp3 = new TaxProcessor(address(this));
        tp3.initialize(_params(20000 ether));
        _authorize(tp3);
        _queue(tp3, 10000 ether);
        _process(tp3, 10000 ether, 9900 ether);
        assertEq(_queue(tp3, 1 ether), 1, "processed direction is applied on the next liquidation cycle");
    }

    // -------------------------------------------------------------------------
    // BondingCurve 兼容存根与 no-op dispatch
    // -------------------------------------------------------------------------

    function test_ProcessBondingCurveTaxForwardsQuote() public {
        wbnb.mint(address(taxToken), 500 ether); // BondingCurve 税以 quote 形态持有
        vm.prank(address(taxToken));
        wbnb.approve(address(tp), type(uint256).max);

        vm.prank(address(taxToken));
        tp.processBondingCurveTax(500 ether);

        assertEq(feeReceiver.balance, 500 ether, "quote forwarded as native");
        assertEq(tp.totalQuoteSentToReceiver(), 500 ether);
    }

    function test_DispatchIsNoop() public {
        // 新异步入口是 processPendingTax；旧接口 dispatch 保留为无副作用兼容位
        tp.dispatch();
        assertEq(feeReceiver.balance, 0);
    }

    function test_ZeroAmountNoop() public {
        vm.prank(address(taxToken));
        assertEq(tp.processTaxTokens(0), 0);
    }

    function test_KeeperProcessingGuards() public {
        _queue(tp, 10000 ether);

        vm.expectRevert(UnauthorizedTaxKeeper.selector);
        tp.processPendingTax(1000 ether, 900 ether, uint64(block.timestamp + 1 minutes));

        vm.expectRevert(UnsafeMinQuoteOut.selector);
        vm.prank(keeper);
        tp.processPendingTax(1000 ether, 0, uint64(block.timestamp + 1 minutes));

        vm.expectRevert(InvalidProcessingDeadline.selector);
        vm.prank(keeper);
        tp.processPendingTax(1000 ether, 900 ether, uint64(block.timestamp - 1));

        vm.expectRevert(InvalidProcessingDeadline.selector);
        vm.prank(keeper);
        tp.processPendingTax(1000 ether, 900 ether, uint64(block.timestamp + 11 minutes));

        vm.expectRevert(InvalidTaxAmount.selector);
        vm.prank(keeper);
        tp.processPendingTax(10001 ether, 900 ether, uint64(block.timestamp + 1 minutes));
    }

    // -------------------------------------------------------------------------
    // 权限与初始化校验
    // -------------------------------------------------------------------------

    function test_RevertWhen_TaxTokenZero() public {
        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.taxToken = address(0);
        vm.expectRevert(TaxTokenRequired.selector);
        tp2.initialize(p);
    }

    function test_RevertWhen_RouterZero() public {
        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.router = address(0);
        vm.expectRevert(RouterRequired.selector);
        tp2.initialize(p);
    }

    function test_RevertWhen_FeeReceiverZero() public {
        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.feeReceiver = address(0);
        vm.expectRevert(FeeReceiverRequired.selector);
        tp2.initialize(p);
    }

    function test_RevertWhen_AlreadyInitialized() public {
        vm.expectRevert(AlreadyInitialized.selector);
        tp.initialize(_params(0));
    }

    function test_RevertWhen_NotDeployer() public {
        TaxProcessor tp2 = new TaxProcessor(address(this));
        vm.prank(address(0xBEEF));
        vm.expectRevert(NotDeployer.selector);
        tp2.initialize(_params(0));
    }

    function test_OnlyTaxToken() public {
        vm.expectRevert(NotTaxToken.selector);
        tp.processTaxTokens(1 ether); // 非税代币地址调用

        vm.expectRevert(NotTaxToken.selector);
        tp.processBondingCurveTax(1 ether);
    }

    function test_RevertWhen_KeeperRegistryZero() public {
        vm.expectRevert(KeeperRegistryRequired.selector);
        new TaxProcessor(address(0));
    }

    /// @dev Regression target for the four-channel restoration: the current
    ///      single-channel processor discards these values and this test must fail
    ///      before the implementation change.
    function test_FourChannelConfigIsPersisted() public {
        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.marketAddress = address(0xA11CE);
        p.dividendAddress = address(0xD1A1);
        p.marketBps = 4_000;
        p.deflationBps = 1_000;
        p.lpBps = 2_000;
        p.dividendBps = 3_000;
        p.dividendToken = address(wbnb);
        tp2.initialize(p);

        PackedFeeConfig memory config = tp2.feeConfig();
        assertEq(config.marketBps, 4_000);
        assertEq(config.deflationBps, 1_000);
        assertEq(config.lpBps, 2_000);
        assertEq(config.dividendBps, 3_000);
        assertEq(tp2.marketAddress(), address(0xA11CE));
        assertEq(tp2.dividendAddress(), address(0xD1A1));
    }

    function test_FourChannelSplitUsesActualQuoteAndDefersFailedDividend() public {
        MockDividend dividend = new MockDividend(wbnb);
        dividend.setFailDeposit(true);

        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.marketBps = 4_000;
        p.deflationBps = 1_000;
        p.lpBps = 2_000;
        p.dividendBps = 3_000;
        p.dividendAddress = address(dividend);
        p.dividendToken = address(wbnb);
        tp2.initialize(p);
        _authorize(tp2);

        _queue(tp2, 10_000 ether);
        assertEq(_process(tp2, 10_000 ether, 7_900 ether), 8_000 ether);

        assertEq(taxToken.balanceOf(address(0xdead)), 1_000 ether, "deflation burns tax token directly");
        assertEq(tp2.lpTokenBalance(), 1_000 ether, "half of LP channel is reserved as tax token");
        assertEq(tp2.pendingTaxTokens(), 0, "LP reserve is not processable tax");
        assertEq(tp2.lpQuoteBalance(), 1_000 ether, "other LP half is converted to quote");
        assertEq(feeReceiver.balance, 4_000 ether, "market channel reaches fixed receiver");
        assertEq(tp2.pendingDividendQuoteTokenBalance(), 3_000 ether, "failed deposit stays retryable");

        dividend.setFailDeposit(false);
        tp2.dispatch();
        assertEq(dividend.totalDeposited(), 3_000 ether);
        assertEq(tp2.pendingDividendQuoteTokenBalance(), 0);
        assertEq(tp2.totalDividendTokenSent(), 3_000 ether);
    }

    function test_AllDeflationConfigProcessesWithoutSwap() public {
        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.marketAddress = address(0);
        p.marketBps = 0;
        p.deflationBps = 10_000;
        tp2.initialize(p);
        _authorize(tp2);

        _queue(tp2, 123 ether);
        vm.prank(keeper);
        uint256 out = tp2.processPendingTax(123 ether, 0, uint64(block.timestamp + 1 minutes));

        assertEq(out, 0);
        assertEq(taxToken.balanceOf(address(0xdead)), 123 ether);
        assertEq(tp2.pendingTaxTokens(), 0);
    }

    function test_RoundingDustNeverActivatesDisabledDividendChannel() public {
        TaxProcessor tp2 = new TaxProcessor(address(this));
        TaxProcessorInitParams memory p = _params(0);
        p.marketBps = 3_333;
        p.deflationBps = 3_333;
        p.lpBps = 3_334;
        tp2.initialize(p);
        _authorize(tp2);

        _queue(tp2, 1);
        _process(tp2, 1, 1);

        assertEq(tp2.pendingDividendQuoteTokenBalance(), 0);
        assertEq(tp2.dividendAddress(), address(0));
        assertEq(feeReceiver.balance, 1, "flooring dust belongs to the protocol receiver");
    }
}
