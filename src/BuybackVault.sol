// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IPancakeRouter02, IPancakePair} from "src/lib/interfaces/IPancakeRouter02.sol";
import {TransferHelper} from "src/TransferHelper.sol";

// ---------------------------------------------------------------------------
// 配置类型（发币时锁定）
// ---------------------------------------------------------------------------

enum BuybackMode {
    TokenBurn, // 0：BNB 买本币 → 0xdead
    LpBurn // 1：BNB 买本币加 LP → LP 死锁 0xdead；失败则回退 TokenBurn
}

enum TriggerMode {
    Time, // 0：到点后按间隔
    Balance, // 1：余额 ≥ triggerAmount 且间隔满足
    TimeAndBalance // 2：到点且余额达标
}

/// @notice Keeper/DApp 可直接读取的回购就绪状态，避免 `canExecuteBuyback=false` 时无法判断原因。
enum BuybackReadiness {
    Ready,
    InsufficientBalance,
    TriggerBalanceNotMet,
    TooEarly,
    InvalidPoolReserves,
    ReserveCapBelowMinimum
}

struct BuybackConfig {
    BuybackMode mode;
    TriggerMode trigger;
    uint64 firstExecuteAt; // Unix 秒；模式 1 必须为 0，模式 0/2 必须至少晚于创建时间 1 分钟
    uint64 intervalSeconds; // 60…31536000 秒
    uint256 triggerAmount; // 模式 0 必须 0；模式 1/2 必须 >= buybackAmount 且 <= 1000 BNB
    uint256 buybackAmount; // 单次上限：0.001…10 BNB，0.001 精度；实际输入可被余额/储备安全线上限缩小
}

struct VaultStats {
    uint256 treasuryBNB;
    address token;
    address pair;
    uint8 mode;
    uint8 trigger;
    uint256 buybackAmount;
    uint256 triggerAmount;
    uint64 intervalSeconds;
    uint64 nextExecuteTime;
    uint64 lastExecuteTime;
    uint256 totalBuybackBNB;
    uint256 totalBurnedToken;
    uint256 totalLpBurned;
    uint256 buybackCount;
    bool canExecute;
    uint256 executableBuybackAmount;
    BuybackReadiness readiness;
}

// ---------------------------------------------------------------------------
// 错误
// ---------------------------------------------------------------------------

error AlreadyInitialized();
error ZeroAddress();
error InvalidBuybackMode();
error InvalidTriggerMode();
error InvalidInterval();
error InvalidFirstExecuteTime();
error InvalidTriggerAmount();
error InvalidBuybackAmount();
error InsufficientBalance();
error TooEarly();
error OnlySelf();
error UnauthorizedKeeper();
error InvalidPair();
error InvalidMinimumOutput();
error InvalidExecutionDeadline();
error InvalidPoolReserves();
error ReserveCapBelowMinimum();
error UnsafeExecutionAmount(uint256 requested, uint256 maximum);
error InvalidLpRatio();

/// @notice 自动回购金库：接收 TaxProcessor 清算所得 BNB，按发币配置买回并销毁（或加 LP 死锁）。
/// @dev `executeBuyback` 仅允许 CoordinatorFactory 授权的 keeper 调用。
///      `receive()` 只收款；税费清算和回购均由 keeper 分成独立交易并提交最低输出。
contract BuybackVault is ReentrancyGuard {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint64 public constant MIN_INTERVAL_SECONDS = 1 minutes;
    uint64 public constant MAX_INTERVAL_SECONDS = 365 days;
    uint256 public constant MIN_BUYBACK_AMOUNT = 0.001 ether;
    uint256 public constant MAX_BUYBACK_AMOUNT = 10 ether;
    uint256 public constant BUYBACK_PRECISION = 0.001 ether;
    uint256 public constant MIN_EXECUTION_AMOUNT = 0.0001 ether;
    uint256 public constant MAX_TRIGGER_AMOUNT = 1000 ether;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_BUYBACK_RESERVE_BPS = 100; // 单笔最多使用池中 1% WBNB 储备
    uint256 public constant LP_SWAP_BPS = 4_990; // 给 LP 侧留出 AMM 手续费和轻微价格影响缓冲
    uint64 public constant MAX_DEADLINE_DELAY = 10 minutes;
    address public constant DEAD = address(0xdead);

    bool private _initialized;

    address public token;
    address public pair;
    address public router;
    address public wbnb;
    address public keeperRegistry;
    bool public tokenIsToken0;

    BuybackMode public mode;
    TriggerMode public trigger;
    uint64 public intervalSeconds;
    uint64 public nextExecuteTime;
    uint64 public lastExecuteTime;
    uint64 public createdAt;
    uint256 public triggerAmount;
    uint256 public buybackAmount;

    uint256 public totalBuybackBNB;
    uint256 public totalBurnedToken;
    uint256 public totalLpBurned;
    uint256 public buybackCount;
    address private _activeCaller;

    event Initialized(address indexed token, address indexed pair, BuybackMode mode, TriggerMode trigger);
    event RevenueReceived(address indexed from, uint256 amount);
    event TokenBuybackExecuted(address indexed caller, uint256 bnbSpent, uint256 tokensBurned);
    event LpBuybackExecuted(address indexed caller, uint256 bnbSpent, uint256 lpBurned, uint256 tokensAdded);
    event BuybackFallbackToToken(uint256 bnbSpent);

    constructor() {
        _initialized = true;
    }

    /// @notice 克隆实例一次性初始化。由 BuybackVaultFactory 在发币同一笔交易内调用。
    function initialize(
        address token_,
        address pair_,
        address router_,
        address wbnb_,
        address keeperRegistry_,
        BuybackConfig calldata config
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (
            token_ == address(0) || pair_ == address(0) || router_ == address(0) || wbnb_ == address(0)
                || keeperRegistry_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _validateConfig(config);

        _initialized = true;
        token = token_;
        pair = pair_;
        router = router_;
        wbnb = wbnb_;
        keeperRegistry = keeperRegistry_;
        address token0 = IPancakePair(pair_).token0();
        address token1 = IPancakePair(pair_).token1();
        if (token0 == token_ && token1 == wbnb_) tokenIsToken0 = true;
        else if (token0 != wbnb_ || token1 != token_) revert InvalidPair();
        mode = config.mode;
        trigger = config.trigger;
        triggerAmount = config.triggerAmount;
        buybackAmount = config.buybackAmount;
        intervalSeconds = config.intervalSeconds;
        createdAt = uint64(block.timestamp);
        nextExecuteTime = config.firstExecuteAt;

        emit Initialized(token_, pair_, config.mode, config.trigger);
    }

    /// @dev 只收 BNB、记账。TaxProcessor 清算会走这条路径；零值 ping 静默忽略。
    receive() external payable {
        if (msg.value > 0) emit RevenueReceived(msg.sender, msg.value);
    }

    /// @notice 条件满足时执行一笔回购。仅 CoordinatorFactory 授权的 keeper 可调用。
    /// @dev `expectedBnbIn` 是本次绑定预算且不得超过执行时重新计算的安全上限。
    ///      Token 路径花费全部预算；LP 路径按实时配比最多花该预算，未使用部分留在金库。
    ///      上限增加不会因第三方捐赠 1 wei 而阻断；上限下降到不足时回滚并重新报价。
    ///      成功才推进冷却；失败整笔回滚，keeper 不接收金库资金。
    function executeBuyback(uint256 expectedBnbIn, uint256 minTokenOut, uint256 minLpTokenOut, uint64 deadline)
        external
        nonReentrant
    {
        if (!IAccessControl(keeperRegistry).hasRole(KEEPER_ROLE, msg.sender)) revert UnauthorizedKeeper();
        if (minTokenOut == 0 || (mode == BuybackMode.LpBurn && minLpTokenOut == 0)) {
            revert InvalidMinimumOutput();
        }
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_DELAY) {
            revert InvalidExecutionDeadline();
        }
        (uint256 maximumAmount, BuybackReadiness readiness) = previewBuyback();
        _revertIfNotReady(readiness);
        if (expectedBnbIn < MIN_EXECUTION_AMOUNT || expectedBnbIn > maximumAmount) {
            revert UnsafeExecutionAmount(expectedBnbIn, maximumAmount);
        }

        lastExecuteTime = uint64(block.timestamp);
        nextExecuteTime = uint64(block.timestamp + intervalSeconds);
        unchecked {
            buybackCount += 1;
        }
        _activeCaller = msg.sender;

        if (mode == BuybackMode.LpBurn) {
            try this.lpBuybackAndBurn(expectedBnbIn, minLpTokenOut, deadline) {}
            catch {
                emit BuybackFallbackToToken(expectedBnbIn);
                _tokenBuybackAndBurn(expectedBnbIn, minTokenOut, deadline);
            }
        } else {
            _tokenBuybackAndBurn(expectedBnbIn, minTokenOut, deadline);
        }
        _activeCaller = address(0);
    }

    /// @notice LP 买毁路径，仅供本合约 `try this.` 调用。失败则外层回退 Token 买毁。
    function lpBuybackAndBurn(uint256 amount, uint256 minTokenOut, uint64 deadline) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _lpBuybackAndBurn(amount, minTokenOut, deadline);
    }

    function canExecuteBuyback() public view returns (bool) {
        (, BuybackReadiness readiness) = previewBuyback();
        return readiness == BuybackReadiness.Ready;
    }

    /// @notice 返回当前可安全执行的精确 BNB 输入和不可执行原因。
    /// @dev `buybackAmount` 是创建者锁定的单次上限；实际输入还受金库余额和池 WBNB 储备 1% 限制。
    function previewBuyback() public view returns (uint256 executableAmount, BuybackReadiness readiness) {
        uint256 balance = address(this).balance;
        if (balance < MIN_EXECUTION_AMOUNT) return (0, BuybackReadiness.InsufficientBalance);
        if ((trigger == TriggerMode.Balance || trigger == TriggerMode.TimeAndBalance) && balance < triggerAmount) {
            return (0, BuybackReadiness.TriggerBalanceNotMet);
        }
        if (!_timeOk()) return (0, BuybackReadiness.TooEarly);

        (uint256 reserveToken, uint256 reserveWbnb) = _pairReserves();
        if (reserveToken == 0 || reserveWbnb == 0) return (0, BuybackReadiness.InvalidPoolReserves);

        uint256 reserveCap = (reserveWbnb * MAX_BUYBACK_RESERVE_BPS) / BPS_DENOMINATOR;
        executableAmount = balance < buybackAmount ? balance : buybackAmount;
        if (reserveCap < executableAmount) executableAmount = reserveCap;
        if (executableAmount < MIN_EXECUTION_AMOUNT) {
            return (0, BuybackReadiness.ReserveCapBelowMinimum);
        }
        return (executableAmount, BuybackReadiness.Ready);
    }

    function getVaultStats() external view returns (VaultStats memory stats) {
        stats.treasuryBNB = address(this).balance;
        stats.token = token;
        stats.pair = pair;
        stats.mode = uint8(mode);
        stats.trigger = uint8(trigger);
        stats.buybackAmount = buybackAmount;
        stats.triggerAmount = triggerAmount;
        stats.intervalSeconds = intervalSeconds;
        stats.nextExecuteTime = nextExecuteTime;
        stats.lastExecuteTime = lastExecuteTime;
        stats.totalBuybackBNB = totalBuybackBNB;
        stats.totalBurnedToken = totalBurnedToken;
        stats.totalLpBurned = totalLpBurned;
        stats.buybackCount = buybackCount;
        (stats.executableBuybackAmount, stats.readiness) = previewBuyback();
        stats.canExecute = stats.readiness == BuybackReadiness.Ready;
    }

    // -----------------------------------------------------------------------
    // 内部
    // -----------------------------------------------------------------------

    function _timeOk() internal view returns (bool) {
        if (trigger == TriggerMode.Balance) {
            return lastExecuteTime == 0 || block.timestamp >= lastExecuteTime + intervalSeconds;
        }
        return block.timestamp >= nextExecuteTime;
    }

    function _validateConfig(BuybackConfig calldata config) internal view {
        if (uint8(config.mode) > uint8(BuybackMode.LpBurn)) revert InvalidBuybackMode();
        if (config.intervalSeconds < MIN_INTERVAL_SECONDS || config.intervalSeconds > MAX_INTERVAL_SECONDS) {
            revert InvalidInterval();
        }
        if (
            config.buybackAmount < MIN_BUYBACK_AMOUNT || config.buybackAmount > MAX_BUYBACK_AMOUNT
                || config.buybackAmount % BUYBACK_PRECISION != 0
        ) {
            revert InvalidBuybackAmount();
        }
        TriggerMode t = config.trigger;
        if (t == TriggerMode.Time) {
            if (config.triggerAmount != 0) revert InvalidTriggerAmount();
            _validateFirstExecuteTime(config.firstExecuteAt);
        } else if (t == TriggerMode.Balance) {
            if (config.firstExecuteAt != 0) revert InvalidFirstExecuteTime();
            _validateTriggerAmount(config.triggerAmount, config.buybackAmount);
        } else if (t == TriggerMode.TimeAndBalance) {
            _validateFirstExecuteTime(config.firstExecuteAt);
            _validateTriggerAmount(config.triggerAmount, config.buybackAmount);
        } else {
            revert InvalidTriggerMode();
        }
    }

    function _validateFirstExecuteTime(uint64 firstExecuteAt) internal view {
        if (firstExecuteAt < block.timestamp + MIN_INTERVAL_SECONDS) revert InvalidFirstExecuteTime();
    }

    function _validateTriggerAmount(uint256 amount, uint256 executionAmount) internal pure {
        if (amount < executionAmount || amount > MAX_TRIGGER_AMOUNT) {
            revert InvalidTriggerAmount();
        }
    }

    function _tokenBuybackAndBurn(uint256 amount, uint256 minTokenOut, uint64 deadline) internal {
        uint256 bought = _swapBnbForToken(amount, minTokenOut, deadline);
        if (bought > 0) {
            TransferHelper.safeTransfer(token, DEAD, bought);
        }
        totalBuybackBNB += amount;
        totalBurnedToken += bought;
        emit TokenBuybackExecuted(_activeCaller, amount, bought);
    }

    function _lpBuybackAndBurn(uint256 amount, uint256 minTokenOut, uint64 deadline) internal {
        uint256 swapAmount = (amount * LP_SWAP_BPS) / BPS_DENOMINATOR;
        uint256 maxWbnbForLp = amount - swapAmount;
        uint256 bought = _swapBnbForToken(swapAmount, minTokenOut, deadline);

        TransferHelper.safeTransfer(token, pair, bought);
        (uint256 reserveToken, uint256 reserveWbnb) = _pairReserves();
        uint256 pairTokenBalance = IERC20(token).balanceOf(pair);
        if (pairTokenBalance <= reserveToken || reserveToken == 0 || reserveWbnb == 0) revert InvalidLpRatio();
        uint256 tokenAdded = pairTokenBalance - reserveToken;

        uint256 numerator = tokenAdded * reserveWbnb;
        uint256 wbnbForLp = numerator / reserveToken;
        if (numerator % reserveToken != 0) wbnbForLp += 1;
        if (wbnbForLp == 0 || wbnbForLp > maxWbnbForLp) revert InvalidLpRatio();

        IWBNB(wbnb).deposit{value: wbnbForLp}();
        TransferHelper.safeTransfer(wbnb, pair, wbnbForLp);

        uint256 lpBefore = IERC20(pair).balanceOf(DEAD);
        IPancakePair(pair).mint(DEAD);
        uint256 lpBurned = IERC20(pair).balanceOf(DEAD) - lpBefore;
        if (lpBurned == 0) revert InvalidLpRatio();

        uint256 bnbSpent = swapAmount + wbnbForLp;
        totalBuybackBNB += bnbSpent;
        totalLpBurned += lpBurned;
        emit LpBuybackExecuted(_activeCaller, bnbSpent, lpBurned, tokenAdded);
    }

    function _swapBnbForToken(uint256 amount, uint256 minTokenOut, uint64 deadline) internal returns (uint256 bought) {
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = token;

        uint256 before = IERC20(token).balanceOf(address(this));
        IPancakeRouter02(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            minTokenOut, path, address(this), deadline
        );
        bought = IERC20(token).balanceOf(address(this)) - before;
        if (bought < minTokenOut) revert InvalidMinimumOutput();
    }

    function _revertIfNotReady(BuybackReadiness readiness) internal pure {
        if (readiness == BuybackReadiness.Ready) return;
        if (readiness == BuybackReadiness.InsufficientBalance || readiness == BuybackReadiness.TriggerBalanceNotMet) {
            revert InsufficientBalance();
        }
        if (readiness == BuybackReadiness.TooEarly) revert TooEarly();
        if (readiness == BuybackReadiness.InvalidPoolReserves) revert InvalidPoolReserves();
        revert ReserveCapBelowMinimum();
    }

    function _pairReserves() internal view returns (uint256 reserveToken, uint256 reserveWbnb) {
        (uint112 reserve0, uint112 reserve1,) = IPancakePair(pair).getReserves();
        (reserveToken, reserveWbnb) =
            tokenIsToken0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }
}

interface IWBNB {
    function deposit() external payable;
}
