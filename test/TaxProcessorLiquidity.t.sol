// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";

contract StatefulERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StatefulWBNB is StatefulERC20 {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract StatefulTaxToken is StatefulERC20 {
    address public mainPool;
    uint16 public sellTaxBps;

    function configurePool(address pair, uint16 taxBps) external {
        mainPool = pair;
        sellTaxBps = taxBps;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        balanceOf[msg.sender] -= amount;
        uint256 tax = to == mainPool ? amount * sellTaxBps / 10_000 : 0;
        balanceOf[to] += amount - tax;
        balanceOf[address(this)] += tax;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        uint256 tax = to == mainPool ? amount * sellTaxBps / 10_000 : 0;
        balanceOf[to] += amount - tax;
        balanceOf[address(this)] += tax;
        return true;
    }
}

contract StatefulPair {
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address token_, address quote_) {
        token0 = token_;
        token1 = quote_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function seed(uint256 initialSupply) external {
        reserve0 = uint112(StatefulERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(StatefulERC20(token1).balanceOf(address(this)));
        totalSupply = initialSupply;
        balanceOf[msg.sender] = initialSupply;
    }

    function swapTaxForQuote(address to) external returns (uint256 out) {
        uint256 tokenBalance = StatefulERC20(token0).balanceOf(address(this));
        uint256 amountIn = tokenBalance - reserve0;
        uint256 amountInWithFee = amountIn * 9_975;
        out = amountInWithFee * reserve1 / (uint256(reserve0) * 10_000 + amountInWithFee);
        StatefulERC20(token1).transfer(to, out);
        reserve0 = uint112(StatefulERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(StatefulERC20(token1).balanceOf(address(this)));
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 balance0 = StatefulERC20(token0).balanceOf(address(this));
        uint256 balance1 = StatefulERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;
        uint256 fromToken = amount0 * totalSupply / reserve0;
        uint256 fromQuote = amount1 * totalSupply / reserve1;
        liquidity = fromToken < fromQuote ? fromToken : fromQuote;
        require(liquidity != 0, "zero liquidity");
        totalSupply += liquidity;
        balanceOf[to] += liquidity;
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
}

contract StatefulRouter {
    address public immutable pair;
    address public immutable quote;

    constructor(address pair_, address quote_) {
        pair = pair_;
        quote = quote_;
    }

    function WETH() external view returns (address) {
        return quote;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 minOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp && path.length == 2, "bad swap");
        StatefulERC20(path[0]).transferFrom(msg.sender, pair, amountIn);
        uint256 out = StatefulPair(pair).swapTaxForQuote(to);
        require(out >= minOut, "slippage");
    }
}

contract PullingDividend {
    StatefulERC20 public immutable quote;
    uint256 public deposited;

    constructor(StatefulERC20 quote_) {
        quote = quote_;
    }

    function deposit(uint256 amount) external returns (bool) {
        quote.transferFrom(msg.sender, address(this), amount);
        deposited += amount;
        return true;
    }
}

contract TaxProcessorLiquidityTest is Test {
    address private constant KEEPER = address(0xCA11);
    address private constant DEAD = address(0xdead);

    function hasRole(bytes32 role, address account) external pure returns (bool) {
        return role == keccak256("KEEPER_ROLE") && account == KEEPER;
    }

    function test_StatefulSwapAndLiquidityUseActualPostTaxReceipts() public {
        StatefulTaxToken token = new StatefulTaxToken();
        StatefulWBNB quote = new StatefulWBNB();
        StatefulPair pair = new StatefulPair(address(token), address(quote));
        token.configurePool(address(pair), 1_000); // 10% secondary sell tax
        StatefulRouter router = new StatefulRouter(address(pair), address(quote));
        PullingDividend dividend = new PullingDividend(quote);
        TaxProcessor processor = new TaxProcessor(address(this));

        processor.initialize(
            TaxProcessorInitParams({
                quoteToken: address(quote),
                router: address(router),
                feeReceiver: address(0xFEE),
                marketAddress: address(0xA11CE),
                dividendAddress: address(dividend),
                taxToken: address(token),
                feeRate: 0,
                marketBps: 4_000,
                deflationBps: 1_000,
                lpBps: 2_000,
                dividendBps: 3_000,
                dividendToken: address(quote),
                commissionReceiver: address(0),
                commissionBps: 0,
                converter: address(0),
                liqExpectedOutputAmount: 0
            })
        );

        // Seed a 100,000 TOKEN / 10,000 WBNB pair before enabling the transfer tax.
        token.configurePool(address(0), 0);
        token.mint(address(pair), 100_000 ether);
        quote.mint(address(pair), 10_000 ether);
        vm.deal(address(quote), 100_000 ether);
        pair.seed(1_000 ether);
        token.configurePool(address(pair), 1_000);

        token.mint(address(token), 10_000 ether);
        vm.prank(address(token));
        token.approve(address(processor), type(uint256).max);
        vm.prank(address(token));
        processor.processTaxTokens(10_000 ether);

        vm.prank(KEEPER);
        uint256 quoteOut = processor.processPendingTax(10_000 ether, 1, uint64(block.timestamp + 60));

        assertEq(token.balanceOf(DEAD), 1_000 ether, "deflation burns its channel");
        assertEq(processor.lpTokenBalance(), 1_000 ether, "raw LP half remains reserved");
        assertEq(token.balanceOf(address(token)), 800 ether, "swap sell tax returns to token for a later batch");
        assertGt(quoteOut, 0);
        assertGt(processor.lpQuoteBalance(), 0);
        assertGt(dividend.deposited(), 0);

        (uint112 tokenReserve, uint112 quoteReserve,) = pair.getReserves();
        uint256 actualLpToken = 900 ether;
        uint256 neededQuote = actualLpToken * quoteReserve / tokenReserve;
        uint256 expectedLiquidity = actualLpToken * pair.totalSupply() / tokenReserve;

        vm.prank(KEEPER);
        processor.addPendingLiquidity(
            1_000 ether, neededQuote, neededQuote, expectedLiquidity, uint64(block.timestamp + 60)
        );

        assertEq(processor.lpTokenBalance(), 0);
        assertEq(processor.totalTokenAddedToLiquidity(), actualLpToken, "LP accounting uses pair receipt");
        assertEq(processor.totalQuoteAddedToLiquidity(), neededQuote);
        assertEq(token.balanceOf(address(token)), 900 ether, "LP transfer's secondary tax remains recoverable");
        assertEq(pair.balanceOf(DEAD), expectedLiquidity, "new LP is irreversibly burned");
    }
}
