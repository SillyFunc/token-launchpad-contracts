// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {TransferHelper} from "src/TransferHelper.sol";
import {IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";
import {
    ITaxProcessor,
    TaxProcessorInitParams,
    PackedFeeConfig,
    PackedFeeConfigV2
} from "src/lib/interfaces/ITaxProcessor.sol";

// ---------------------------------------------------------------------------
// 自定义错误
// ---------------------------------------------------------------------------

error AlreadyInitialized();
error NotDeployer();
error TaxTokenRequired();
error RouterRequired();
error FeeReceiverRequired();
error NotTaxToken();
error KeeperRegistryRequired();
error UnauthorizedTaxKeeper();
error InvalidTaxAmount();
error UnsafeMinQuoteOut();
error InvalidProcessingDeadline();
error QuoteTokenUnavailable();
error InsufficientQuoteOutput();

/// @notice Launchpad 单通道 TaxProcessor：代币转账只归集税代币，由平台 keeper 异步兑换并派发。
/// @dev 异步清算避免在用户卖出交易里用无保护报价嵌套 swap：
///      1. 收款人由 Coordinator 在发币时经 initialize 固定，运行期无任何变更入口
///         （清算时动态传收款人=任何人可把税金打给自己，故恒为固定值）
///      2. keeper 必须提交最低输出与短时限；swap 失败整笔回滚，税代币保留在本合约等待重试
///      3. 原生转账失败（收款人为拒收 BNB 的合约）→ 包回 WBNB 走 ERC20 转账，资金不锁死
///      4. 方向信号在 keeper 清算后缓存，并在下一次代币归集时回传给 FlapTaxTokenV3
///      5. 上游四通道（market/deflation/lp/dividend）、commission、Dividend 交互全部移除；
///         ITaxProcessor（src/lib 受保护接口）签名不变，兼容视图以零值存根实现
contract TaxProcessor is ITaxProcessor, ReentrancyGuard {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint64 public constant MAX_DEADLINE_DELAY = 10 minutes;

    address private immutable _deployer;
    bool private _initialized;

    address public immutable override swapRegistry; // address(0) — 本实现不使用 SwapRegistry
    address public immutable keeperRegistry;

    address public override taxToken;
    address public override router;
    address public override feeReceiver;
    address public quoteToken; // 存储值；isWeth 时 getQuoteToken 返回 WETH
    uint256 public override liqExpectedOutputAmount;

    /// @notice 累计已派发给收款人的 quote 数量（原生 BNB 与 WBNB 两种到账形态合计）
    uint256 public totalQuoteSentToReceiver;
    int8 public pendingDirection;

    event Initialized(address indexed taxToken);
    event TaxQueued(uint256 taxAmount, uint256 pendingBalance);
    event TaxProcessed(uint256 taxAmount, uint256 quoteOut, int8 direction);
    event TaxForwarded(address indexed receiver, uint256 amount, bool isNative);

    /// @dev WETH.withdraw 解包回款入口：仅兜收，不承载业务
    receive() external payable {}

    constructor(address keeperRegistry_) {
        if (keeperRegistry_ == address(0)) revert KeeperRegistryRequired();
        _deployer = msg.sender;
        swapRegistry = address(0);
        keeperRegistry = keeperRegistry_;
    }

    modifier onlyTaxToken() {
        if (msg.sender != taxToken) revert NotTaxToken();
        _;
    }

    function initialize(TaxProcessorInitParams memory params) external override {
        if (_initialized) revert AlreadyInitialized();
        if (msg.sender != _deployer) revert NotDeployer();
        if (params.taxToken == address(0)) revert TaxTokenRequired();
        if (params.router == address(0)) revert RouterRequired();
        if (params.feeReceiver == address(0)) revert FeeReceiverRequired();

        _initialized = true;

        taxToken = params.taxToken;
        router = params.router;
        feeReceiver = params.feeReceiver;
        quoteToken = params.quoteToken;
        liqExpectedOutputAmount = params.liqExpectedOutputAmount;

        // params 中 bps/dividend/commission/converter 为上游接口兼容位，本实现忽略
        emit Initialized(params.taxToken);
    }

    // ---------------------------------------------------------------------------
    // 核心：处理税
    // ---------------------------------------------------------------------------

    /// @notice 从 FlapTaxTokenV3 拉取税代币并排队，不在用户卖出交易内执行 DEX swap。
    /// @return direction 方向信号语义与 FlapTaxTokenV3._adjustLiquidationThreshold 一致：
    ///     > 0 → swap 输出低于参考（价格弱，提高阈值）
    ///     < 0 → swap 输出高于参考（价格强，降低阈值）
    ///     0   → 无参考值或相等
    function processTaxTokens(uint256 taxAmount) external override onlyTaxToken returns (int8) {
        if (taxAmount == 0) return 0;

        int8 direction = pendingDirection;
        if (direction != 0) pendingDirection = 0;

        uint256 before = IERC20(taxToken).balanceOf(address(this));
        TransferHelper.safeTransferFrom(taxToken, msg.sender, address(this), taxAmount);
        uint256 received = IERC20(taxToken).balanceOf(address(this)) - before;
        emit TaxQueued(received, IERC20(taxToken).balanceOf(address(this)));
        return direction;
    }

    /// @notice keeper 分批清算已归集税代币。失败会整笔回滚，原始税代币仍可再次处理。
    function processPendingTax(uint256 amountIn, uint256 minQuoteOut, uint64 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (!IAccessControl(keeperRegistry).hasRole(KEEPER_ROLE, msg.sender)) {
            revert UnauthorizedTaxKeeper();
        }
        uint256 pending = IERC20(taxToken).balanceOf(address(this));
        if (amountIn == 0 || amountIn > pending) revert InvalidTaxAmount();
        if (minQuoteOut == 0) revert UnsafeMinQuoteOut();
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_DELAY) {
            revert InvalidProcessingDeadline();
        }

        out = _swapToQuote(amountIn, minQuoteOut, deadline);
        _forwardQuote(out);

        int8 direction;
        if (liqExpectedOutputAmount != 0) {
            if (out > liqExpectedOutputAmount) direction = -1;
            else if (out < liqExpectedOutputAmount) direction = 1;
        }
        pendingDirection = direction;

        emit TaxProcessed(amountIn, out, direction);
    }

    /// @notice BondingCurve 阶段税（本项目不触发；保留接口兼容）：quote 直转收款人
    function processBondingCurveTax(uint256 quoteAmount) external override onlyTaxToken {
        if (quoteAmount == 0) return;
        TransferHelper.safeTransferFrom(getQuoteToken(), msg.sender, address(this), quoteAmount);
        _forwardQuote(quoteAmount);
    }

    /// @notice 接口兼容存根；异步清算使用 `processPendingTax`。
    function dispatch() external override {}

    // ---------------------------------------------------------------------------
    // 内部：swap 与派发
    // ---------------------------------------------------------------------------

    /// @notice 将税代币换成 quote token；任何失败均回滚，保留原始税代币供 keeper 重试。
    function _swapToQuote(uint256 amountIn, uint256 minQuoteOut, uint64 deadline) internal returns (uint256 out) {
        address quote = getQuoteToken();
        address weth_ = weth();
        if (quote == address(0) || weth_ == address(0)) revert QuoteTokenUnavailable();

        address[] memory path;
        if (quote == weth_) {
            path = new address[](2);
            path[0] = taxToken;
            path[1] = weth_;
        } else {
            path = new address[](3);
            path[0] = taxToken;
            path[1] = weth_; // 经 WETH 中转（需 weth/quote 池存在）
            path[2] = quote;
        }

        uint256 before = IERC20(quote).balanceOf(address(this));
        TransferHelper.safeApprove(taxToken, router, 0);
        TransferHelper.safeApprove(taxToken, router, amountIn);

        IPancakeRouter02(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, minQuoteOut, path, address(this), deadline);
        TransferHelper.safeApprove(taxToken, router, 0);

        out = IERC20(quote).balanceOf(address(this)) - before;
        if (out < minQuoteOut) revert InsufficientQuoteOutput();
    }

    /// @notice 派发 quote 给 feeReceiver：WETH 先解包原生 BNB 转账；
    ///         收款方拒收原生币（无 receive 的合约）时包回 WBNB 走 ERC20 转账
    /// @dev CEI：totalQuoteSentToReceiver 先记账再外呼。原生转账收款方为发币时固定的 feeReceiver
    ///      （唯一赋值链：CoordinatorFactory.initialize ← 表单 feeRecipient，双重非零校验，无 setter），
    ///      非任意目的地 —— 压制 arbitrary-send-eth 误报
    // slither-disable-next-line arbitrary-send-eth
    function _forwardQuote(uint256 amount) internal {
        totalQuoteSentToReceiver += amount;

        address quote = getQuoteToken();
        if (quote != weth()) {
            TransferHelper.safeTransfer(quote, feeReceiver, amount);
            emit TaxForwarded(feeReceiver, amount, false);
            return;
        }

        IWETH(quote).withdraw(amount); // 解包：原生 BNB 回到本合约（receive 兜收）
        (bool ok,) = feeReceiver.call{value: amount}("");
        if (ok) {
            emit TaxForwarded(feeReceiver, amount, true);
            return;
        }
        // 原生转账失败不吞资金：包回 WBNB 走 ERC20 转账
        IWETH(quote).deposit{value: amount}();
        TransferHelper.safeTransfer(quote, feeReceiver, amount);
        emit TaxForwarded(feeReceiver, amount, false);
    }

    // ---------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------

    function isWeth() public view returns (bool) {
        return quoteToken == address(0) || quoteToken == weth();
    }

    function weth() public view override returns (address) {
        return router != address(0) ? IPancakeRouter02(router).WETH() : address(0);
    }

    function getQuoteToken() public view override returns (address) {
        return isWeth() ? weth() : quoteToken;
    }

    function pendingTaxTokens() external view returns (uint256) {
        return IERC20(taxToken).balanceOf(address(this));
    }

    function flapBlackHole() external pure override returns (address) {
        return address(0xdead);
    }

    // ── 上游四通道兼容存根：本实现单通道，恒零值 ──

    function marketAddress() external pure override returns (address) {
        return address(0);
    }

    function dividendAddress() external pure override returns (address) {
        return address(0);
    }

    function commissionReceiver() external pure override returns (address) {
        return address(0);
    }

    function converter() external pure override returns (address) {
        return address(0);
    }

    function dividendToken() external pure override returns (address) {
        return address(0);
    }

    function commissionBps() external pure override returns (uint16) {
        return 0;
    }

    function feeQuoteBalance() external pure override returns (uint256) {
        return 0;
    }

    function lpQuoteBalance() external pure override returns (uint256) {
        return 0;
    }

    function marketQuoteBalance() external pure override returns (uint256) {
        return 0;
    }

    function pendingDividendQuoteTokenBalance() external pure override returns (uint256) {
        return 0;
    }

    function dividendQuoteBalance() external pure override returns (uint256) {
        return 0;
    }

    function dividendTokenBalance() external pure override returns (uint256) {
        return 0;
    }

    function commissionQuoteBalance() external pure override returns (uint256) {
        return 0;
    }

    function totalDividendTokenSent() external pure override returns (uint256) {
        return 0;
    }

    function totalQuoteSentToDividend() external pure override returns (uint256) {
        return 0;
    }

    function totalQuoteAddedToLiquidity() external pure override returns (uint256) {
        return 0;
    }

    function totalTokenAddedToLiquidity() external pure override returns (uint256) {
        return 0;
    }

    function totalQuoteSentToMarketing() external pure override returns (uint256) {
        return 0;
    }

    function requiresMEVProtection() external pure override returns (bool) {
        return true;
    }

    function feeConfig() external view override returns (PackedFeeConfig memory) {
        return PackedFeeConfig({marketBps: 0, deflationBps: 0, lpBps: 0, dividendBps: 0, feeRate: 0, isWeth: isWeth()});
    }

    function feeConfigV2() external view override returns (PackedFeeConfigV2 memory) {
        return PackedFeeConfigV2({
            marketBps: 0,
            deflationBps: 0,
            lpBps: 0,
            dividendBps: 0,
            feeRate: 0,
            isWeth: isWeth(),
            commissionBps: 0,
            dividendToken: address(0)
        });
    }
}

    /// @notice 最小 WETH 接口（解包/包装原生 BNB）
    interface IWETH {
        function deposit() external payable;
        function withdraw(uint256 amount) external;
    }
