// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "src/Clones.sol";
import {TaxProcessor, UnauthorizedTemporaryRecovery, InvalidTemporaryRecoveryRecipient} from "src/TaxProcessor.sol";
import {TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";
import {
    BuybackVault,
    BuybackConfig,
    BuybackMode,
    TriggerMode,
    UnauthorizedVaultRecovery,
    InvalidVaultRecoveryRecipient
} from "src/BuybackVault.sol";
import {TaxInfrastructureFactory} from "src/TaxInfrastructureFactory.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {UnauthorizedTaxKeeper, InvalidTaxAmount} from "src/TaxProcessor.sol";

/// @dev 真实 OZ AccessControl 作为 registry,用于验证 keeper 撤销后的生效路径(Coordinator 同源)。
contract RealRegistry is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
}

contract KeeperRevokeTest is Test {
    RealRegistry internal registry;
    TaxProcessor internal tp;
    MockERC20 internal taxToken;
    MockWBNB internal wbnb;

    address internal admin = address(this);
    address internal keeper = address(0xCA11);
    address internal recipient = address(0xBEEF);

    function setUp() public {
        registry = new RealRegistry();
        registry.grantRole(registry.KEEPER_ROLE(), keeper);
        taxToken = new MockERC20();
        wbnb = new MockWBNB();
        tp = new TaxProcessor(address(registry));
        tp.initialize(
            TaxProcessorInitParams({
                quoteToken: address(wbnb),
                router: address(new MockRouter(address(wbnb))),
                feeReceiver: address(0xFEE1),
                marketAddress: address(0xFEE1),
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
                liqExpectedOutputAmount: 0
            })
        );
        vm.deal(address(tp), 1 ether);
    }

    /// @notice 撤销 keeper 后,keeper 的临时回收与清算均被拒绝;admin 仍可回收。
    function test_RevokedKeeperLosesAccessAdminStillRecovers() public {
        vm.prank(keeper);
        vm.expectRevert(UnauthorizedTemporaryRecovery.selector);
        tp.temporaryRecoverAll(recipient);

        // 撤销前 keeper 可执行清算入口(通过权限检查,随后因无待处理税币而失败)
        vm.prank(keeper);
        vm.expectRevert(InvalidTaxAmount.selector);
        tp.processPendingTax(1, 1, uint64(block.timestamp + 1 minutes));

        registry.revokeRole(registry.KEEPER_ROLE(), keeper);

        vm.prank(keeper);
        vm.expectRevert(UnauthorizedTaxKeeper.selector);
        tp.processPendingTax(1, 1, uint64(block.timestamp + 1 minutes));

        tp.temporaryRecoverAll(recipient);
        assertEq(recipient.balance, 1 ether, "admin recovered native after revoke");
    }
}

// 与 TransferHelper.ETHTransferFailed 同签名,用于断言原生转账失败的精确回滚原因
error ETHTransferFailed(address to);

// ---------------------------------------------------------------------------
// Mocks (保留 ERC20 余额语义、WBNB 原生兑付、失败分支;不做固定返回值伪造)
// ---------------------------------------------------------------------------

contract MockRegistry {
    bytes32 internal constant ADMIN = bytes32(0);
    bytes32 internal constant KEEPER = keccak256("KEEPER_ROLE");

    mapping(bytes32 => mapping(address => bool)) public roles;

    function grant(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function adminRole() external pure returns (bytes32) {
        return ADMIN;
    }

    function keeperRole() external pure returns (bytes32) {
        return KEEPER;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public mainPool;

    function setMainPool(address p) external {
        mainPool = p;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract MockWBNB is MockERC20 {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native send");
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev 1:1 兑换:扣除 tokenIn、向 to 铸造 tokenOut,足以驱动 processPendingTax 的真实余额差路径。
contract MockRouter {
    address public immutable WETH;

    constructor(address weth_) {
        WETH = weth_;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external {
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(path[path.length - 1]).mint(to, amountIn);
    }
}

/// @dev 始终拒绝 deposit,使 TaxProcessor 把分红额记为 pending(consumed == 0)。
contract MockFailingDividend {
    function deposit(uint256) external pure returns (bool) {
        revert("mock: dividend down");
    }
}

contract MockPair {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }
}

/// @dev 无 receive/fallback:原生 BNB 转入必然失败。
contract NoReceive {}

/// @dev 收到原生 BNB 时回调目标合约(模拟重入)。
contract ReentrantRecipient {
    address public target;
    bytes public payload;

    function setCall(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    receive() external payable {
        if (target != address(0)) {
            (bool ok,) = target.call(payload);
            require(ok, "reentered");
        }
    }
}

// ---------------------------------------------------------------------------
// TaxProcessor 单元测试
// ---------------------------------------------------------------------------

contract TemporaryRecoveryTaxProcessorTest is Test {
    bytes32 internal constant KEEPER = keccak256("KEEPER_ROLE");
    address internal constant POOL = address(0xCAFE);
    address internal constant DEAD = address(0xdead);

    MockERC20 internal taxToken;
    MockWBNB internal wbnb;
    MockRouter internal router;
    MockRegistry internal registry;
    MockFailingDividend internal dividend;
    TaxProcessor internal tp;

    address internal admin = address(0xAD);
    address internal keeper = address(0xCA11);
    address internal stranger = address(0x5555);
    address internal market = address(0xFEE1);
    address internal recipient = address(0xBEEF);

    function setUp() public {
        taxToken = new MockERC20();
        taxToken.setMainPool(POOL);
        wbnb = new MockWBNB();
        router = new MockRouter(address(wbnb));
        registry = new MockRegistry();
        registry.grant(bytes32(0), admin);
        registry.grant(KEEPER, keeper);
        dividend = new MockFailingDividend();
        vm.deal(address(wbnb), 1_000_000 ether);

        tp = new TaxProcessor(address(registry));
        tp.initialize(_params(address(taxToken), address(wbnb), address(dividend), 3000, 1000, 3000, 3000));

        // 模拟 FlapTaxTokenV3:税币合约自身持有税币并授权 processor
        vm.prank(address(taxToken));
        taxToken.approve(address(tp), type(uint256).max);
        vm.prank(address(taxToken));
        wbnb.approve(address(tp), type(uint256).max);
    }

    function _params(
        address token,
        address quote,
        address dividendAddr,
        uint16 marketBps,
        uint16 deflationBps,
        uint16 lpBps,
        uint16 dividendBps
    ) internal view returns (TaxProcessorInitParams memory) {
        return TaxProcessorInitParams({
            quoteToken: quote,
            router: address(router),
            feeReceiver: market,
            marketAddress: market,
            dividendAddress: dividendAddr,
            taxToken: token,
            feeRate: 0,
            marketBps: marketBps,
            deflationBps: deflationBps,
            lpBps: lpBps,
            dividendBps: dividendBps,
            dividendToken: dividendBps == 0 ? address(0) : quote,
            commissionReceiver: address(0),
            commissionBps: 0,
            converter: address(0),
            liqExpectedOutputAmount: 1 ether
        });
    }

    /// @dev 制造四类待处理账本:待清算税币、LP 预留税币、LP quote、待分红、待销毁 quote、残留原生 BNB。
    function _seedLedgers() internal {
        taxToken.mint(address(taxToken), 1000 ether);
        vm.prank(address(taxToken));
        tp.processTaxTokens(1000 ether);
        taxToken.mint(address(taxToken), 200 ether);
        vm.prank(address(taxToken));
        tp.processTaxTokens(200 ether); // 第二批入队:留作待清算余额(processTaxTokens 会消费旧 direction)

        vm.prank(keeper);
        tp.processPendingTax(1000 ether, 1 ether, uint64(block.timestamp + 1 minutes));

        wbnb.mint(address(taxToken), 1000 ether);
        vm.prank(address(taxToken));
        tp.processBondingCurveTax(1000 ether);

        vm.deal(address(tp), 3 ether);
    }

    struct Snapshot {
        uint256 taxBal;
        uint256 wbnbBal;
        uint256 nativeBal;
        uint256 lpTokenBalance;
        uint256 lpQuote;
        uint256 pendingDividend;
        uint256 pendingDeflation;
        uint256 marketQuote;
        uint256 feeQuote;
        uint256 commissionQuote;
        uint256 dividendTokenBalance;
        int8 direction;
        uint256 totalQuoteSentToMarketing;
        uint256 totalQuoteSentToReceiver;
        uint256 totalTaxTokenBurned;
        uint256 totalQuoteBurned;
        uint256 totalDividendTokenSent;
        uint256 totalQuoteAddedToLiquidity;
        uint256 totalTokenAddedToLiquidity;
    }

    function _snap() internal view returns (Snapshot memory s) {
        s.taxBal = taxToken.balanceOf(address(tp));
        s.wbnbBal = wbnb.balanceOf(address(tp));
        s.nativeBal = address(tp).balance;
        s.lpTokenBalance = tp.lpTokenBalance();
        s.lpQuote = tp.lpQuoteBalance();
        s.pendingDividend = tp.pendingDividendQuoteTokenBalance();
        s.pendingDeflation = tp.pendingDeflationQuoteBalance();
        s.marketQuote = tp.marketQuoteBalance();
        s.feeQuote = tp.feeQuoteBalance();
        s.commissionQuote = tp.commissionQuoteBalance();
        s.dividendTokenBalance = tp.dividendTokenBalance();
        s.direction = tp.pendingDirection();
        s.totalQuoteSentToMarketing = tp.totalQuoteSentToMarketing();
        s.totalQuoteSentToReceiver = tp.totalQuoteSentToReceiver();
        s.totalTaxTokenBurned = tp.totalTaxTokenBurned();
        s.totalQuoteBurned = tp.totalQuoteBurned();
        s.totalDividendTokenSent = tp.totalDividendTokenSent();
        s.totalQuoteAddedToLiquidity = tp.totalQuoteAddedToLiquidity();
        s.totalTokenAddedToLiquidity = tp.totalTokenAddedToLiquidity();
    }

    // -------------------------------------------------------------------------

    function test_OnlyAdminCanRecover() public {
        _seedLedgers();

        vm.prank(keeper);
        vm.expectRevert(UnauthorizedTemporaryRecovery.selector);
        tp.temporaryRecoverAll(recipient);

        vm.prank(stranger);
        vm.expectRevert(UnauthorizedTemporaryRecovery.selector);
        tp.temporaryRecoverAll(recipient);
    }

    function test_RecoversAllAssetsClearsLedgersAndKeepsHistory() public {
        _seedLedgers();
        Snapshot memory pre = _snap();

        // 前置条件:各类账本确实非零,否则测试无法证明清理效果
        assertGt(pre.taxBal, 0);
        assertGt(pre.lpTokenBalance, 0, "LP reserve tax tokens");
        assertGt(pre.lpQuote, 0, "LP quote");
        assertGt(pre.pendingDividend, 0, "pending dividend");
        assertGt(pre.pendingDeflation, 0, "pending deflation");
        assertGt(pre.nativeBal, 0, "native");
        assertTrue(pre.direction != 0, "direction");

        vm.prank(admin);
        tp.temporaryRecoverAll(recipient);

        assertEq(taxToken.balanceOf(recipient), pre.taxBal, "tax token to recipient");
        assertEq(wbnb.balanceOf(recipient), pre.wbnbBal, "WBNB to recipient");
        assertEq(recipient.balance, pre.nativeBal, "native to recipient");

        assertEq(taxToken.balanceOf(address(tp)), 0);
        assertEq(wbnb.balanceOf(address(tp)), 0);
        assertEq(address(tp).balance, 0);

        assertEq(tp.lpTokenBalance(), 0, "lpTokenBalance cleared");
        assertEq(tp.lpQuoteBalance(), 0, "lpQuote cleared");
        assertEq(tp.pendingDividendQuoteTokenBalance(), 0, "pending dividend cleared");
        assertEq(tp.pendingDeflationQuoteBalance(), 0, "pending deflation cleared");
        assertEq(tp.marketQuoteBalance(), 0);
        assertEq(tp.feeQuoteBalance(), 0);
        assertEq(tp.commissionQuoteBalance(), 0);
        assertEq(tp.dividendTokenBalance(), 0);
        assertEq(tp.pendingDirection(), 0, "direction cleared");

        // 历史统计不因资金回收而变化
        assertEq(tp.totalQuoteSentToMarketing(), pre.totalQuoteSentToMarketing);
        assertEq(tp.totalQuoteSentToReceiver(), pre.totalQuoteSentToReceiver);
        assertEq(tp.totalTaxTokenBurned(), pre.totalTaxTokenBurned);
        assertEq(tp.totalQuoteBurned(), pre.totalQuoteBurned);
        assertEq(tp.totalDividendTokenSent(), pre.totalDividendTokenSent);
        assertEq(tp.totalQuoteAddedToLiquidity(), pre.totalQuoteAddedToLiquidity);
        assertEq(tp.totalTokenAddedToLiquidity(), pre.totalTokenAddedToLiquidity);
    }

    function test_ZeroBalanceIsNoopThenRecoverableAgain() public {
        vm.prank(admin);
        tp.temporaryRecoverAll(recipient);
        assertEq(taxToken.balanceOf(recipient), 0);
        assertEq(recipient.balance, 0);

        _seedLedgers();
        vm.prank(admin);
        tp.temporaryRecoverAll(recipient);
        uint256 firstTax = taxToken.balanceOf(recipient);
        assertGt(firstTax, 0);

        // 回收后新增的资金可以再次回收
        taxToken.mint(address(taxToken), 77 ether);
        vm.prank(address(taxToken));
        tp.processTaxTokens(77 ether);
        vm.prank(admin);
        tp.temporaryRecoverAll(recipient);
        assertEq(taxToken.balanceOf(recipient), firstTax + 77 ether);
        assertEq(taxToken.balanceOf(address(tp)), 0);
    }

    function test_QuoteEqualsTaxTokenMovesOnce() public {
        // 配置异常但需兜底:router.WETH() 与 quote 同为税币本身
        MockRouter sameRouter = new MockRouter(address(taxToken));
        TaxProcessor tp2 = new TaxProcessor(address(registry));
        TaxProcessorInitParams memory p = _params(address(taxToken), address(taxToken), address(0), 10_000, 0, 0, 0);
        p.router = address(sameRouter);
        p.dividendToken = address(0);
        tp2.initialize(p);
        vm.prank(address(taxToken));
        taxToken.approve(address(tp2), type(uint256).max);

        taxToken.mint(address(taxToken), 500 ether);
        vm.prank(address(taxToken));
        tp2.processTaxTokens(500 ether);

        vm.prank(admin);
        tp2.temporaryRecoverAll(recipient);
        assertEq(taxToken.balanceOf(recipient), 500 ether, "exactly once");
        assertEq(taxToken.balanceOf(address(tp2)), 0);
    }

    function test_RejectsDangerousRecipients() public {
        _seedLedgers();
        address[7] memory bad =
            [address(0), address(tp), address(taxToken), address(wbnb), DEAD, POOL, address(dividend)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(admin);
            vm.expectRevert(InvalidTemporaryRecoveryRecipient.selector);
            tp.temporaryRecoverAll(bad[i]);
        }
    }

    function test_NativeRejectionRollsBackEverything() public {
        _seedLedgers();
        NoReceive rejecter = new NoReceive();
        Snapshot memory pre = _snap();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETHTransferFailed.selector, address(rejecter)));
        tp.temporaryRecoverAll(address(rejecter));

        Snapshot memory post = _snap();
        assertEq(abi.encode(post), abi.encode(pre), "state fully rolled back");
        assertEq(taxToken.balanceOf(address(rejecter)), 0, "no partial tax transfer");
        assertEq(wbnb.balanceOf(address(rejecter)), 0, "no partial WBNB transfer");
    }

    function test_ReentryFromNativeReceiveIsBlocked() public {
        _seedLedgers();
        ReentrantRecipient attacker = new ReentrantRecipient();
        registry.grant(bytes32(0), address(attacker)); // 让重入失败只能来自 nonReentrant
        attacker.setCall(address(tp), abi.encodeCall(tp.temporaryRecoverAll, (address(attacker))));
        Snapshot memory pre = _snap();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETHTransferFailed.selector, address(attacker)));
        tp.temporaryRecoverAll(address(attacker));

        assertEq(abi.encode(_snap()), abi.encode(pre), "reentry rolled back");
    }
}

// ---------------------------------------------------------------------------
// BuybackVault 单元测试
// ---------------------------------------------------------------------------

contract TemporaryRecoveryVaultTest is Test {
    bytes32 internal constant KEEPER = keccak256("KEEPER_ROLE");
    address internal constant DEAD = address(0xdead);

    MockERC20 internal token;
    MockWBNB internal wbnb;
    MockPair internal pair;
    MockRegistry internal registry;
    BuybackVault internal vault;

    address internal admin = address(0xAD);
    address internal keeper = address(0xCA11);
    address internal stranger = address(0x5555);
    address internal recipient = address(0xBEEF);

    function setUp() public {
        token = new MockERC20();
        wbnb = new MockWBNB();
        pair = new MockPair(address(token), address(wbnb));
        registry = new MockRegistry();
        registry.grant(bytes32(0), admin);
        registry.grant(KEEPER, keeper);

        BuybackVault impl = new BuybackVault();
        vault = BuybackVault(payable(Clones.clone(address(impl))));
        BuybackConfig memory cfg = BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Time,
            firstExecuteAt: uint64(block.timestamp + 1 minutes),
            intervalSeconds: 1 minutes,
            triggerAmount: 0,
            buybackAmount: 0.01 ether
        });
        vault.initialize(address(token), address(pair), address(0x7777), address(wbnb), address(registry), cfg);
    }

    function _fund() internal {
        vm.deal(address(vault), 2 ether);
        wbnb.mint(address(vault), 3 ether);
        token.mint(address(vault), 4 ether);
    }

    function test_OnlyAdminCanRecover() public {
        _fund();
        vm.prank(keeper);
        vm.expectRevert(UnauthorizedVaultRecovery.selector);
        vault.temporaryRecoverAll(recipient);

        vm.prank(stranger);
        vm.expectRevert(UnauthorizedVaultRecovery.selector);
        vault.temporaryRecoverAll(recipient);
    }

    function test_RecoversNativeWbnbAndTokenWithoutTouchingBuybackStats() public {
        _fund();
        uint64 nextBefore = vault.nextExecuteTime();

        vm.prank(admin);
        vault.temporaryRecoverAll(recipient);

        assertEq(recipient.balance, 2 ether, "native");
        assertEq(wbnb.balanceOf(recipient), 3 ether, "WBNB");
        assertEq(token.balanceOf(recipient), 4 ether, "token");
        assertEq(address(vault).balance, 0);
        assertEq(wbnb.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(vault)), 0);

        assertEq(vault.buybackCount(), 0, "no buyback counted");
        assertEq(vault.lastExecuteTime(), 0, "cooldown not advanced");
        assertEq(vault.nextExecuteTime(), nextBefore, "schedule untouched");
        assertEq(vault.totalBuybackBNB(), 0);
        assertEq(vault.totalBurnedToken(), 0);
    }

    function test_ZeroBalanceSkippedAndRecoverableAgain() public {
        vm.prank(admin);
        vault.temporaryRecoverAll(recipient);
        assertEq(recipient.balance, 0);

        _fund();
        vm.prank(admin);
        vault.temporaryRecoverAll(recipient);
        assertEq(wbnb.balanceOf(recipient), 3 ether);

        wbnb.mint(address(vault), 1 ether);
        vm.prank(admin);
        vault.temporaryRecoverAll(recipient);
        assertEq(wbnb.balanceOf(recipient), 4 ether);
        assertEq(wbnb.balanceOf(address(vault)), 0);
    }

    function test_RejectsDangerousRecipients() public {
        _fund();
        address[6] memory bad = [address(0), address(vault), address(token), address(wbnb), address(pair), DEAD];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(admin);
            vm.expectRevert(InvalidVaultRecoveryRecipient.selector);
            vault.temporaryRecoverAll(bad[i]);
        }
    }

    function test_NativeRejectionRollsBackEverything() public {
        _fund();
        NoReceive rejecter = new NoReceive();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETHTransferFailed.selector, address(rejecter)));
        vault.temporaryRecoverAll(address(rejecter));

        assertEq(wbnb.balanceOf(address(vault)), 3 ether, "WBNB restored");
        assertEq(token.balanceOf(address(vault)), 4 ether, "token restored");
        assertEq(address(vault).balance, 2 ether, "native restored");
        assertEq(wbnb.balanceOf(address(rejecter)), 0);
    }

    function test_ReentryFromNativeReceiveIsBlocked() public {
        _fund();
        ReentrantRecipient attacker = new ReentrantRecipient();
        registry.grant(bytes32(0), address(attacker));
        attacker.setCall(address(vault), abi.encodeCall(vault.temporaryRecoverAll, (address(attacker))));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETHTransferFailed.selector, address(attacker)));
        vault.temporaryRecoverAll(address(attacker));

        assertEq(address(vault).balance, 2 ether);
        assertEq(wbnb.balanceOf(address(vault)), 3 ether);
    }
}

// ---------------------------------------------------------------------------
// 真实 FlapTaxTokenV3 集成测试:代币转账 + Dividend 份额回调
// ---------------------------------------------------------------------------

contract TemporaryRecoveryRealTokenTest is Test {
    address internal constant POOL = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal market = address(0xFEE1);

    FlapTaxTokenV3 internal token;
    TaxProcessor internal processor;
    Dividend internal dividend;
    MockWBNB internal wbnb;
    MockRouter internal router;

    // Coordinator 角色由测试合约扮演:同时承担 keeperRegistry 与 DEFAULT_ADMIN_ROLE
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == bytes32(0) && account == address(this);
    }

    function setUp() public {
        wbnb = new MockWBNB();
        router = new MockRouter(address(wbnb));
        TaxProcessor taxImpl = new TaxProcessor(address(this));
        Dividend divImpl = new Dividend(address(wbnb), address(0xdead));
        TaxInfrastructureFactory factory =
            new TaxInfrastructureFactory(address(taxImpl), address(divImpl), address(this));

        FlapTaxTokenV3 flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        token = FlapTaxTokenV3(Clones.clone(address(flapImpl)));

        // 与 Coordinator 相同的装配顺序:先克隆并初始化 processor/dividend,再初始化代币
        (address proc, address div) = factory.createInfrastructure(
            TaxProcessorInitParams({
                quoteToken: address(wbnb),
                router: address(router),
                feeReceiver: market,
                marketAddress: market,
                dividendAddress: address(0),
                taxToken: address(token),
                feeRate: 0,
                marketBps: 5000,
                deflationBps: 0,
                lpBps: 0,
                dividendBps: 5000,
                dividendToken: address(wbnb),
                commissionReceiver: address(0),
                commissionBps: 0,
                converter: address(0),
                liqExpectedOutputAmount: 0
            }),
            address(0xAAA1), // pair(排除分红)
            address(0xAAA2), // presale(排除分红)
            1 ether
        );
        processor = TaxProcessor(payable(proc));
        dividend = Dividend(payable(div));

        address[] memory pools = new address[](1);
        pools[0] = POOL;
        token.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "Recovery",
                symbol: "REC",
                meta: "",
                buyTax: 1000,
                sellTax: 1000,
                taxProcessor: proc,
                dividendContract: div,
                quoteToken: address(wbnb),
                liqExpectedOutputAmount: 0,
                taxDuration: 365 days,
                pools: pools,
                v2Router: address(router),
                antiFarmerDuration: 1 days
            })
        );
        token.startMigration();
        token.finalizeMigration();
    }

    function _share(address user) internal view returns (uint256 share) {
        (share,,) = dividend.userInfo(user);
    }

    function test_RealTokenRecoveryMovesBalanceAndUpdatesDividendShares() public {
        token.transfer(alice, 1000 ether);
        assertEq(_share(alice), 1000 ether, "precondition: alice has dividend share");
        // 部署者持有全部初始供应并参与分红份额,因此断言增量而非绝对 totalShares
        uint256 totalBefore = dividend.totalShares();

        // 模拟已入队税币:processor 被分红系统排除,不应获得份额
        token.transfer(address(processor), 500 ether);
        assertEq(_share(address(processor)), 0, "processor excluded");
        assertEq(token.balanceOf(address(processor)), 500 ether);

        processor.temporaryRecoverAll(bob);

        assertEq(token.balanceOf(bob), 500 ether, "tax tokens moved");
        assertEq(token.balanceOf(address(processor)), 0);
        assertEq(_share(bob), 500 ether, "dividend callback credited recipient");
        assertEq(_share(alice), 1000 ether, "existing holder untouched");
        // processor 转入时份额被扣减(排除地址不计份额),回收后 bob 获得等额份额,总量回到转入前
        assertEq(dividend.totalShares(), totalBefore, "total shares restored after recovery");
    }

    function test_RealTokenRecoveryRejectsNonAdmin() public {
        token.transfer(address(processor), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedTemporaryRecovery()"));
        processor.temporaryRecoverAll(bob);
    }
}
