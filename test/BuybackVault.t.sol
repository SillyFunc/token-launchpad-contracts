// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "src/Clones.sol";
import {TaxInfrastructureFixture} from "./helpers/TaxInfrastructureFixture.sol";
import {
    BuybackVault,
    BuybackConfig,
    BuybackMode,
    TriggerMode,
    BuybackReadiness,
    AlreadyInitialized,
    ZeroAddress,
    InvalidInterval,
    InvalidFirstExecuteTime,
    InvalidTriggerAmount,
    InvalidBuybackAmount,
    InsufficientBalance,
    TooEarly,
    OnlySelf,
    UnauthorizedKeeper,
    InvalidPair,
    InvalidMinimumOutput,
    InvalidExecutionDeadline,
    InvalidPoolReserves,
    ReserveCapBelowMinimum,
    UnsafeExecutionAmount
} from "src/BuybackVault.sol";
import {BuybackVaultFactory, ZeroImplementation, ZeroCoordinator, UnknownVault} from "src/BuybackVaultFactory.sol";
import {
    CoordinatorFactory,
    BuybackVaultFactoryNotSet,
    VaultRequiresMarketChannel,
    ZeroBuybackVaultFactory,
    InvalidBuybackVaultFactory,
    AlreadyConfigured
} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {PRESALE} from "src/Presale.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {ITaxProcessor, TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {VanitySaltFinder} from "./TokenReservation.t.sol";

contract MockVaultERC20 {
    string public name = "TKN";
    string public symbol = "TKN";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint16 public buyTaxRate;
    uint16 public sellTaxRate;
    address public taxedPair;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setTax(uint16 buy_, uint16 sell_) external {
        buyTaxRate = buy_;
        sellTaxRate = sell_;
    }

    function setPair(address pair_) external {
        taxedPair = pair_;
    }

    function mintFromPair(address to, uint256 amount) external returns (uint256 received) {
        uint256 tax = (amount * buyTaxRate) / 10_000;
        received = amount - tax;
        balanceOf[address(this)] += tax;
        balanceOf[to] += received;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        uint256 tax = to == taxedPair ? (amount * sellTaxRate) / 10_000 : 0;
        balanceOf[address(this)] += tax;
        balanceOf[to] += amount - tax;
    }
}

contract MockVaultWBNB is MockVaultERC20 {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
}

contract MockBuybackPair {
    address public immutable token0;
    address public immutable token1;
    mapping(address => uint256) public balanceOf;

    uint112 private _reserve0;
    uint112 private _reserve1;
    bool public failMint;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }

    function sync() external {
        _sync();
    }

    function setFailMint(bool value) external {
        failMint = value;
    }

    function setReservesForTest(uint112 reserve0, uint112 reserve1) external {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    function mint(address to) external returns (uint256 liquidity) {
        if (failMint) revert("mock: mint failed");
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;
        liquidity = amount0 < amount1 ? amount0 : amount1;
        require(liquidity > 0, "mock: zero liquidity");
        balanceOf[to] += liquidity;
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
    }

    function _sync() internal {
        _reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        _reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }
}

contract MockBuybackRouter {
    address public weth;
    address public pairFactory;
    bool public failSwap;

    constructor(address _weth) {
        weth = _weth;
    }

    function setPairFactory(address f) external {
        pairFactory = f;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function factory() external view returns (address) {
        return pairFactory;
    }

    function setFailSwap(bool v) external {
        failSwap = v;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable {
        if (failSwap) revert("mock: swap failed");
        require(deadline >= block.timestamp, "mock: expired");
        uint256 received = MockVaultERC20(path[path.length - 1]).mintFromPair(to, msg.value);
        require(received >= amountOutMin, "mock: insufficient output");
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        if (failSwap) revert("mock: swap failed");
        require(deadline >= block.timestamp, "mock: expired");
        require(amountIn >= amountOutMin, "mock: insufficient output");
        MockVaultERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        MockVaultERC20(path[path.length - 1]).mint(to, amountIn);
    }
}

contract BuybackVaultTest is Test {
    address constant DEAD = address(0xdead);

    BuybackVault impl;
    BuybackVaultFactory vaultFactory;
    MockVaultERC20 token;
    MockVaultWBNB wbnbToken;
    MockBuybackPair pairContract;
    MockBuybackRouter router;
    address pair;
    address wbnb;

    address coordinator = address(this);
    address caller = address(0xCA11);
    address replacementKeeper = address(0xBEEF);

    mapping(address => bool) private _keepers;

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == keccak256("KEEPER_ROLE") && _keepers[account];
    }

    function setUp() public {
        impl = new BuybackVault();
        vaultFactory = new BuybackVaultFactory(address(impl), coordinator);
        token = new MockVaultERC20();
        wbnbToken = new MockVaultWBNB();
        wbnb = address(wbnbToken);
        vm.deal(wbnb, 1_000 ether);
        pairContract = new MockBuybackPair(address(token), wbnb);
        pair = address(pairContract);
        token.setPair(pair);
        token.mint(pair, 100 ether);
        wbnbToken.mint(pair, 100 ether);
        pairContract.sync();
        router = new MockBuybackRouter(wbnb);
        _keepers[caller] = true;
        vm.deal(caller, 10 ether);
    }

    function _timeConfig() internal view returns (BuybackConfig memory) {
        return BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Time,
            firstExecuteAt: uint64(block.timestamp + 1 minutes),
            intervalSeconds: 1 minutes,
            triggerAmount: 0,
            buybackAmount: 0.01 ether
        });
    }

    function _cloneInit(BuybackConfig memory cfg) internal returns (BuybackVault vault) {
        address clone = vaultFactory.createVault();
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);
        vault = BuybackVault(payable(clone));
    }

    function _execute(BuybackVault vault, address keeper) internal {
        (uint256 amount,) = vault.previewBuyback();
        vm.prank(keeper);
        vault.executeBuyback(amount, 0.009 ether, 0.004 ether, uint64(block.timestamp + 1 minutes));
    }

    function test_implementationLocked() public {
        vm.expectRevert(AlreadyInitialized.selector);
        impl.initialize(address(token), pair, address(router), wbnb, address(this), _timeConfig());
    }

    function test_zeroImplementationFactoryReverts() public {
        vm.expectRevert(ZeroImplementation.selector);
        new BuybackVaultFactory(address(0), coordinator);

        vm.expectRevert(ZeroCoordinator.selector);
        new BuybackVaultFactory(address(impl), address(0));
    }

    function test_initializeVaultUnknownReverts() public {
        vm.expectRevert(UnknownVault.selector);
        vaultFactory.initializeVault(address(0x1234), address(token), pair, address(router), wbnb, _timeConfig());
    }

    function test_invalidConfigs() public {
        BuybackConfig memory cfg = _timeConfig();
        cfg.intervalSeconds = 59;
        address clone = vaultFactory.createVault();
        vm.expectRevert(InvalidInterval.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.intervalSeconds = 365 days + 1;
        vm.expectRevert(InvalidInterval.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.buybackAmount = 0.0015 ether; // not 0.001 aligned
        vm.expectRevert(InvalidBuybackAmount.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.triggerAmount = 1 ether; // time mode must be 0
        vm.expectRevert(InvalidTriggerAmount.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.firstExecuteAt = uint64(block.timestamp + 59);
        vm.expectRevert(InvalidFirstExecuteTime.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);
    }

    function test_absoluteFirstExecutionTimeIsNotShiftedByInitialization() public {
        BuybackConfig memory cfg = _timeConfig();
        uint64 selectedTime = uint64(block.timestamp + 1 days);
        cfg.firstExecuteAt = selectedTime;

        vm.warp(block.timestamp + 1 hours);
        BuybackVault vault = _cloneInit(cfg);
        assertEq(vault.nextExecuteTime(), selectedTime);

        vm.deal(address(vault), 0.05 ether);
        vm.warp(selectedTime - 1);
        assertFalse(vault.canExecuteBuyback());

        vm.warp(selectedTime);
        assertTrue(vault.canExecuteBuyback());
        _execute(vault, caller);
    }

    function test_intervalBoundsAreSeconds() public {
        BuybackConfig memory cfg = _timeConfig();
        cfg.intervalSeconds = 1 minutes;
        BuybackVault minVault = _cloneInit(cfg);
        assertEq(minVault.intervalSeconds(), 60);

        cfg = _timeConfig();
        cfg.intervalSeconds = 365 days;
        BuybackVault maxVault = _cloneInit(cfg);
        assertEq(maxVault.intervalSeconds(), 365 days);
    }

    function test_timeTrigger_tooEarlyThenExecute() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);

        assertFalse(vault.canExecuteBuyback());
        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));

        vm.warp(block.timestamp + 60);
        assertTrue(vault.canExecuteBuyback());

        _execute(vault, caller);

        assertEq(token.balanceOf(DEAD), 0.01 ether);
        assertEq(vault.buybackCount(), 1);
        assertEq(vault.totalBuybackBNB(), 0.01 ether);
        assertEq(address(vault).balance, 0.04 ether);

        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));
    }

    function test_timeTrigger_missedWindowExecutesOnce() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 1 ether);
        vm.warp(block.timestamp + 10 days);
        _execute(vault, caller);
        assertEq(vault.buybackCount(), 1);
        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));
    }

    function test_balanceTrigger() public {
        BuybackConfig memory cfg = BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Balance,
            firstExecuteAt: 0,
            intervalSeconds: 1 minutes,
            triggerAmount: 1 ether,
            buybackAmount: 0.01 ether
        });
        BuybackVault vault = _cloneInit(cfg);

        vm.deal(address(vault), 0.5 ether);
        vm.prank(caller);
        vm.expectRevert(InsufficientBalance.selector);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));

        vm.deal(address(vault), 1 ether);
        _execute(vault, caller);
        assertEq(vault.buybackCount(), 1);
        assertEq(address(vault).balance, 0.99 ether);
    }

    function test_balanceTriggerAllowsFractionalThreshold() public {
        BuybackConfig memory cfg = BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Balance,
            firstExecuteAt: 0,
            intervalSeconds: 1 minutes,
            triggerAmount: 0.015 ether,
            buybackAmount: 0.01 ether
        });
        BuybackVault vault = _cloneInit(cfg);
        vm.deal(address(vault), 0.015 ether);

        _execute(vault, caller);
        assertEq(address(vault).balance, 0.005 ether);
    }

    function test_balanceTriggerRejectsTimeAndThresholdBelowExecutionAmount() public {
        BuybackConfig memory cfg = BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Balance,
            firstExecuteAt: uint64(block.timestamp + 1 days),
            intervalSeconds: 1 minutes,
            triggerAmount: 0.01 ether,
            buybackAmount: 0.01 ether
        });
        address clone = vaultFactory.createVault();
        vm.expectRevert(InvalidFirstExecuteTime.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        cfg.firstExecuteAt = 0;
        cfg.triggerAmount = 0.009 ether;
        clone = vaultFactory.createVault();
        vm.expectRevert(InvalidTriggerAmount.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);
    }

    function test_timeAndBalance() public {
        BuybackConfig memory cfg = BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.TimeAndBalance,
            firstExecuteAt: uint64(block.timestamp + 1 minutes),
            intervalSeconds: 1 minutes,
            triggerAmount: 1 ether,
            buybackAmount: 0.01 ether
        });
        BuybackVault vault = _cloneInit(cfg);
        vm.deal(address(vault), 1 ether);

        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));

        vm.warp(block.timestamp + 60);
        vm.deal(address(vault), 0.5 ether);
        vm.prank(caller);
        vm.expectRevert(InsufficientBalance.selector);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));

        vm.deal(address(vault), 1 ether);
        _execute(vault, caller);
        assertEq(vault.buybackCount(), 1);
    }

    function test_receiveDoesNotBuyback() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.warp(block.timestamp + 60);
        (bool ok,) = address(vault).call{value: 0.05 ether}("");
        assertTrue(ok);
        assertEq(vault.buybackCount(), 0);
        assertTrue(vault.canExecuteBuyback());
    }

    function test_lpFallbackToTokenBurn() public {
        BuybackConfig memory cfg = _timeConfig();
        cfg.mode = BuybackMode.LpBurn;
        BuybackVault vault = _cloneInit(cfg);
        pairContract.setFailMint(true);
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        _execute(vault, caller);

        assertEq(token.balanceOf(DEAD), 0.01 ether);
        assertEq(vault.totalLpBurned(), 0);
        assertEq(vault.totalBurnedToken(), 0.01 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_lpSuccessBurnsLpNotTokenInventory() public {
        BuybackConfig memory cfg = _timeConfig();
        cfg.mode = BuybackMode.LpBurn;
        BuybackVault vault = _cloneInit(cfg);
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        _execute(vault, caller);

        assertGt(vault.totalLpBurned(), 0);
        assertEq(pairContract.balanceOf(DEAD), vault.totalLpBurned());
        assertEq(token.balanceOf(address(vault)), 0);
        assertLe(vault.totalBuybackBNB(), 0.01 ether);
        assertEq(address(vault).balance, 0.05 ether - vault.totalBuybackBNB());
    }

    function test_tokenBurnAccountsForActualBuyTaxOutput() public {
        token.setTax(1000, 0); // 10% buy tax
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        vm.prank(caller);
        vault.executeBuyback(0.01 ether, 0.008 ether, 0, uint64(block.timestamp + 1 minutes));

        assertEq(token.balanceOf(DEAD), 0.009 ether);
        assertEq(vault.totalBurnedToken(), 0.009 ether);
        assertEq(token.balanceOf(address(token)), 0.001 ether, "buy tax remains in token tax inventory");
    }

    function test_lpUsesActualFeeOnTransferAmounts() public {
        token.setTax(500, 1000); // 5% buy tax, 10% sell tax into the pair
        BuybackConfig memory cfg = _timeConfig();
        cfg.mode = BuybackMode.LpBurn;
        BuybackVault vault = _cloneInit(cfg);
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        vm.prank(caller);
        vault.executeBuyback(0.01 ether, 0.008 ether, 0.004 ether, uint64(block.timestamp + 1 minutes));

        assertGt(vault.totalLpBurned(), 0);
        assertEq(pairContract.balanceOf(DEAD), vault.totalLpBurned());
        assertEq(token.balanceOf(address(vault)), 0);
        assertGt(token.balanceOf(address(token)), 0, "both buy and add-liquidity taxes are retained by token");
        assertEq(address(vault).balance, 0.05 ether - vault.totalBuybackBNB());
    }

    function test_executionQuoteAndDeadlineGuards() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        vm.expectRevert(InvalidMinimumOutput.selector);
        vm.prank(caller);
        vault.executeBuyback(0.01 ether, 0, 0, uint64(block.timestamp + 1 minutes));

        vm.expectRevert(InvalidExecutionDeadline.selector);
        vm.prank(caller);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp - 1));

        vm.expectRevert(InvalidExecutionDeadline.selector);
        vm.prank(caller);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 11 minutes));
    }

    function test_minOutputFailureRollsBackScheduleAndFunds() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);
        uint64 originalNext = vault.nextExecuteTime();

        vm.expectRevert("mock: insufficient output");
        vm.prank(caller);
        vault.executeBuyback(0.01 ether, 0.02 ether, 0, uint64(block.timestamp + 1 minutes));

        assertEq(vault.buybackCount(), 0);
        assertEq(vault.lastExecuteTime(), 0);
        assertEq(vault.nextExecuteTime(), originalNext);
        assertEq(address(vault).balance, 0.05 ether);
    }

    function test_reserveLimitCapsOversizedBuyback() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);
        pairContract.setReservesForTest(100 ether, 0.5 ether); // 1% limit = 0.005 BNB

        (uint256 amount, BuybackReadiness readiness) = vault.previewBuyback();
        assertEq(amount, 0.005 ether);
        assertEq(uint8(readiness), uint8(BuybackReadiness.Ready));
        assertTrue(vault.canExecuteBuyback());

        vm.prank(caller);
        vault.executeBuyback(amount, 0.004 ether, 0, uint64(block.timestamp + 1 minutes));

        assertEq(vault.totalBuybackBNB(), 0.005 ether);
        assertEq(token.balanceOf(DEAD), 0.005 ether);
        assertEq(address(vault).balance, 0.045 ether);
    }

    function test_timeModeCanExecuteBelowConfiguredMaximum() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.0005 ether);
        vm.warp(block.timestamp + 60);

        (uint256 amount, BuybackReadiness readiness) = vault.previewBuyback();
        assertEq(amount, 0.0005 ether);
        assertEq(uint8(readiness), uint8(BuybackReadiness.Ready));

        vm.prank(caller);
        vault.executeBuyback(amount, 0.0004 ether, 0, uint64(block.timestamp + 1 minutes));
        assertEq(address(vault).balance, 0);
        assertEq(vault.totalBuybackBNB(), 0.0005 ether);
    }

    function test_reserveChangeAfterQuoteRevertsWithoutAdvancingState() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);
        pairContract.setReservesForTest(100 ether, 0.5 ether);
        (uint256 quotedAmount,) = vault.previewBuyback();
        assertEq(quotedAmount, 0.005 ether);

        pairContract.setReservesForTest(100 ether, 0.4 ether);
        vm.expectRevert(abi.encodeWithSelector(UnsafeExecutionAmount.selector, 0.005 ether, 0.004 ether));
        vm.prank(caller);
        vault.executeBuyback(quotedAmount, 0.003 ether, 0, uint64(block.timestamp + 1 minutes));

        assertEq(vault.buybackCount(), 0);
        assertEq(vault.lastExecuteTime(), 0);
        assertEq(address(vault).balance, 0.05 ether);
    }

    function test_balanceIncreaseAfterQuoteCannotBlockExecution() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.005 ether);
        vm.warp(block.timestamp + 60);
        (uint256 quotedAmount,) = vault.previewBuyback();
        assertEq(quotedAmount, 0.005 ether);

        // 模拟报价后第三方向 receive() 捐赠 1 wei。若强制等于最新预览，这会成为廉价 DoS。
        vm.deal(address(vault), 0.005 ether + 1);
        vm.prank(caller);
        vault.executeBuyback(quotedAmount, 0.004 ether, 0, uint64(block.timestamp + 1 minutes));

        assertEq(vault.buybackCount(), 1);
        assertEq(vault.totalBuybackBNB(), quotedAmount);
        assertEq(address(vault).balance, 1);
    }

    function test_keeperCannotChooseAmountBelowEconomicMinimum() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        vm.expectRevert(abi.encodeWithSelector(UnsafeExecutionAmount.selector, 0.00005 ether, 0.01 ether));
        vm.prank(caller);
        vault.executeBuyback(0.00005 ether, 0.00004 ether, 0, uint64(block.timestamp + 1 minutes));

        assertEq(vault.buybackCount(), 0);
        assertEq(vault.lastExecuteTime(), 0);
        assertEq(address(vault).balance, 0.05 ether);
    }

    function test_emptyPoolReportsExplicitReason() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);
        pairContract.setReservesForTest(0, 0);

        (uint256 amount, BuybackReadiness readiness) = vault.previewBuyback();
        assertEq(amount, 0);
        assertEq(uint8(readiness), uint8(BuybackReadiness.InvalidPoolReserves));

        vm.expectRevert(InvalidPoolReserves.selector);
        vm.prank(caller);
        vault.executeBuyback(0.001 ether, 0.0009 ether, 0, uint64(block.timestamp + 1 minutes));
    }

    function test_reserveCapBelowEconomicMinimumReportsExplicitReason() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);
        pairContract.setReservesForTest(100 ether, 0.005 ether); // 1% = 0.00005 BNB

        (uint256 amount, BuybackReadiness readiness) = vault.previewBuyback();
        assertEq(amount, 0);
        assertEq(uint8(readiness), uint8(BuybackReadiness.ReserveCapBelowMinimum));
        assertFalse(vault.canExecuteBuyback());

        vm.expectRevert(ReserveCapBelowMinimum.selector);
        vm.prank(caller);
        vault.executeBuyback(0.00005 ether, 0.00004 ether, 0, uint64(block.timestamp + 1 minutes));
    }

    function test_lpBuybackAndBurnOnlySelf() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.expectRevert(OnlySelf.selector);
        vault.lpBuybackAndBurn(0.01 ether, 0.004 ether, uint64(block.timestamp + 1 minutes));
    }

    function test_insufficientBalance() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.warp(block.timestamp + 60);
        vm.prank(caller);
        vm.expectRevert(InsufficientBalance.selector);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));
    }

    function test_nonKeeperCannotExecute() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        vm.expectRevert(UnauthorizedKeeper.selector);
        vm.prank(address(0xBAD));
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));
    }

    function test_keeperRoleIsReadDynamically() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        _keepers[caller] = false;
        vm.expectRevert(UnauthorizedKeeper.selector);
        vm.prank(caller);
        vault.executeBuyback(0.01 ether, 0.009 ether, 0, uint64(block.timestamp + 1 minutes));

        _keepers[replacementKeeper] = true;
        _execute(vault, replacementKeeper);
        assertEq(vault.buybackCount(), 1);
    }

    function test_keeperTaxProcessingFundsVaultThenBuyback() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        TaxProcessor processor = new TaxProcessor(address(this));
        processor.initialize(
            TaxProcessorInitParams({
                quoteToken: wbnb,
                router: address(router),
                feeReceiver: address(vault),
                marketAddress: address(vault),
                dividendAddress: address(0),
                taxToken: address(token),
                feeRate: 0,
                marketBps: 10_000,
                deflationBps: 0,
                lpBps: 0,
                dividendBps: 0,
                dividendToken: address(0),
                commissionReceiver: address(0),
                commissionBps: 0,
                converter: address(0),
                liqExpectedOutputAmount: 0
            })
        );

        token.mint(address(token), 0.02 ether);
        vm.prank(address(token));
        token.approve(address(processor), type(uint256).max);
        vm.prank(address(token));
        processor.processTaxTokens(0.02 ether);

        assertEq(address(vault).balance, 0, "queueing tax never performs an inline swap");
        assertEq(processor.pendingTaxTokens(), 0.02 ether);

        vm.prank(caller);
        processor.processPendingTax(0.02 ether, 0.019 ether, uint64(block.timestamp + 1 minutes));
        assertEq(address(vault).balance, 0.02 ether, "processed tax BNB reaches the vault");
        assertEq(processor.pendingTaxTokens(), 0);

        vm.warp(block.timestamp + 1 minutes);
        _execute(vault, caller);
        assertEq(token.balanceOf(DEAD), 0.01 ether);
        assertEq(address(vault).balance, 0.01 ether);
    }

    function test_zeroAddressesOnInit() public {
        address clone = vaultFactory.createVault();
        vm.expectRevert(ZeroAddress.selector);
        vaultFactory.initializeVault(clone, address(0), pair, address(router), wbnb, _timeConfig());
    }

    function test_pairMustMatchTokenAndWbnb() public {
        MockBuybackPair wrongPair = new MockBuybackPair(address(token), address(0xBAD));
        address clone = vaultFactory.createVault();
        vm.expectRevert(InvalidPair.selector);
        vaultFactory.initializeVault(clone, address(token), address(wrongPair), address(router), wbnb, _timeConfig());
    }
}

contract BuybackVaultCoordinatorTest is Test {
    uint256 constant SUPPLY = 1e9 ether;

    FlapTaxTokenV3 flapImpl;
    TokenFactory tokenFactory;
    PresaleFactory presaleFactory;
    CoordinatorFactory coordinator;
    BuybackVaultFactory vaultFactory;
    MockBuybackRouter router;
    MockVaultWBNB wbnbToken;
    address wbnb;
    address creator = address(0xB0B);
    address feeReceiver = address(0xfee1);
    address keeper = address(0xCA11);

    function setUp() public {
        flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        MockPairFactoryStub pairFactory = new MockPairFactoryStub();
        wbnbToken = new MockVaultWBNB();
        wbnb = address(wbnbToken);
        router = new MockBuybackRouter(wbnb);
        router.setPairFactory(address(pairFactory));

        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE template = new PRESALE();
        presaleFactory = new PresaleFactory(address(template), address(0));
        coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));
        TaxInfrastructureFixture.configure(coordinator, wbnb);
        coordinator.grantRole(coordinator.KEEPER_ROLE(), keeper);
        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        BuybackVault impl = new BuybackVault();
        vaultFactory = new BuybackVaultFactory(address(impl), address(coordinator));
        coordinator.setBuybackVaultFactory(address(vaultFactory));

        vm.deal(creator, 100 ether);
    }

    function _tokenConfig() internal view returns (TokenConfig memory) {
        return TokenConfig({
            name: "T",
            symbol: "T",
            meta: "",
            buyTax: 200,
            sellTax: 300,
            feeRecipient: feeReceiver,
            marketBps: 10_000,
            deflationBps: 0,
            lpBps: 0,
            dividendBps: 0,
            minimumShareBalance: 0,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }

    function _vanitySalt(string memory tag) internal view returns (bytes32 salt) {
        (salt,) = VanitySaltFinder.find(address(tokenFactory), address(flapImpl), uint256(keccak256(bytes(tag))));
        require(salt != bytes32(0), "salt");
    }

    function _buyback() internal view returns (BuybackConfig memory) {
        return BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Time,
            firstExecuteAt: uint64(block.timestamp + 1 minutes),
            intervalSeconds: 1 minutes,
            triggerAmount: 0,
            buybackAmount: 0.01 ether
        });
    }

    function test_createTokenStillPaysFeeRecipient() public {
        bytes32 salt = _vanitySalt("wallet-mode");
        vm.prank(creator);
        (address token,) = coordinator.createToken{value: 1 ether}(_tokenConfig(), salt);
        assertEq(coordinator.tokenVaults(token), address(0));
    }

    function test_createTokenWithVaultWiresFeeReceiver() public {
        bytes32 salt = _vanitySalt("vault-mode");
        TokenConfig memory cfg = _tokenConfig();
        vm.prank(creator);
        (address token, address presale, address vault) =
            coordinator.createTokenWithVault{value: 1 ether}(cfg, salt, _buyback());

        assertEq(presale, coordinator.tokenPresales(token));
        assertEq(coordinator.tokenVaults(token), vault);
        assertEq(BuybackVault(payable(vault)).token(), token);
        assertEq(BuybackVault(payable(vault)).pair(), FlapTaxTokenV3(token).mainPool());
        assertEq(BuybackVault(payable(vault)).keeperRegistry(), address(coordinator));
        assertTrue(coordinator.hasRole(coordinator.KEEPER_ROLE(), keeper));

        address taxProcessor = FlapTaxTokenV3(token).taxProcessor();
        assertEq(ITaxProcessor(taxProcessor).feeReceiver(), vault);
        assertEq(TaxProcessor(payable(taxProcessor)).keeperRegistry(), address(coordinator));
        assertTrue(ITaxProcessor(taxProcessor).requiresMEVProtection());
        assertEq(FlapTaxTokenV3(token).taxExpirationTime(), coordinator.TAX_DURATION());
    }

    function test_createTokenWithVaultRequiresFactory() public {
        CoordinatorFactory bare =
            new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));
        vm.expectRevert(BuybackVaultFactoryNotSet.selector);
        vm.prank(creator);
        bare.createTokenWithVault{value: 1 ether}(_tokenConfig(), _vanitySalt("nofactory"), _buyback());
    }

    function test_createTokenWithVaultRequiresMarketChannel() public {
        TokenConfig memory config = _tokenConfig();
        config.marketBps = 0;
        config.deflationBps = 10_000;

        vm.expectRevert(VaultRequiresMarketChannel.selector);
        vm.prank(creator);
        coordinator.createTokenWithVault{value: 1 ether}(config, _vanitySalt("zero-market-vault"), _buyback());
    }

    function test_setBuybackVaultFactoryOnce() public {
        vm.expectRevert(AlreadyConfigured.selector);
        coordinator.setBuybackVaultFactory(address(0x1234));

        CoordinatorFactory bare =
            new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));
        vm.expectRevert(ZeroBuybackVaultFactory.selector);
        bare.setBuybackVaultFactory(address(0));

        vm.expectRevert(InvalidBuybackVaultFactory.selector);
        bare.setBuybackVaultFactory(address(0x1234));

        BuybackVault wrongImpl = new BuybackVault();
        BuybackVaultFactory wrongRegistryFactory = new BuybackVaultFactory(address(wrongImpl), address(this));
        vm.expectRevert(InvalidBuybackVaultFactory.selector);
        bare.setBuybackVaultFactory(address(wrongRegistryFactory));
    }
}

contract MockPairFactoryStub {
    address public pair;

    function getPair(address, address) external view returns (address) {
        return pair;
    }

    function createPair(address tokenA, address tokenB) external returns (address) {
        if (pair == address(0)) pair = address(new MockBuybackPair(tokenA, tokenB));
        return pair;
    }
}
