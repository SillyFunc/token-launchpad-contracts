// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
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

struct BuybackConfig {
    BuybackMode mode;
    TriggerMode trigger;
    uint64 startDelayMinutes; // 模式 1 必须 0；0/2 为 1…525600
    uint64 intervalMinutes; // 1…525600
    uint256 triggerAmount; // 模式 0 必须 0；1/2 为 1…1000 整 BNB
    uint256 buybackAmount; // 0.001…10 BNB，0.001 精度
    uint256 callerReward; // 成功执行付给 msg.sender，可为 0
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
    uint256 callerReward;
    uint256 totalBuybackBNB;
    uint256 totalBurnedToken;
    uint256 totalLpBurned;
    uint256 buybackCount;
    bool canExecute;
}

// ---------------------------------------------------------------------------
// 错误
// ---------------------------------------------------------------------------

error AlreadyInitialized();
error ZeroAddress();
error InvalidBuybackMode();
error InvalidTriggerMode();
error InvalidInterval();
error InvalidStartDelay();
error InvalidTriggerAmount();
error InvalidBuybackAmount();
error InvalidCallerReward();
error InsufficientBalance();
error TooEarly();
error OnlySelf();

/// @notice 自动回购金库：接收 TaxProcessor 清算所得 BNB，按发币配置买回并销毁（或加 LP 死锁）。
/// @dev `executeBuyback` 是公开入口，供任何人调用——前端按钮、独立 keeper、MEV 机器人均可。
///      不在 `receive()` 里回购：清算发生在用户卖出交易内，嵌套 swap 会撑爆 gas 并变成夹子靶。
///      不接 Flap VaultPortal / Guardian / Trigger Service：那是他们平台的注册表与后端调度，
///      引入后要绑 Flap 链下 keeper、付他们的 trigger 费，合约工作量不减、运维耦合增加。
contract BuybackVault is ReentrancyGuard {
    uint64 public constant MIN_INTERVAL_MINUTES = 1;
    uint64 public constant MAX_INTERVAL_MINUTES = 525_600; // 365 天
    uint256 public constant MIN_BUYBACK_AMOUNT = 0.001 ether;
    uint256 public constant MAX_BUYBACK_AMOUNT = 10 ether;
    uint256 public constant BUYBACK_PRECISION = 0.001 ether;
    uint256 public constant MIN_TRIGGER_AMOUNT = 1 ether;
    uint256 public constant MAX_TRIGGER_AMOUNT = 1000 ether;
    uint256 public constant MAX_CALLER_REWARD = 0.01 ether;
    uint256 public constant SLIPPAGE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEADLINE_BUFFER = 300;
    address public constant DEAD = address(0xdead);

    bool private _initialized;

    address public token;
    address public pair;
    address public router;
    address public wbnb;

    BuybackMode public mode;
    TriggerMode public trigger;
    uint64 public intervalSeconds;
    uint64 public nextExecuteTime;
    uint64 public lastExecuteTime;
    uint64 public createdAt;
    uint256 public triggerAmount;
    uint256 public buybackAmount;
    uint256 public callerReward;

    uint256 public totalBuybackBNB;
    uint256 public totalBurnedToken;
    uint256 public totalLpBurned;
    uint256 public buybackCount;
    address private _activeCaller;

    event Initialized(address indexed token, address indexed pair, BuybackMode mode, TriggerMode trigger);
    event RevenueReceived(address indexed from, uint256 amount);
    event TokenBuybackExecuted(address indexed caller, uint256 bnbSpent, uint256 tokensBurned);
    event LpBuybackExecuted(address indexed caller, uint256 bnbSpent, uint256 lpBurned, uint256 tokensBurned);
    event BuybackFallbackToToken(uint256 bnbSpent);

    constructor() {
        _initialized = true;
    }

    /// @notice 克隆实例一次性初始化。由 BuybackVaultFactory 在发币同一笔交易内调用。
    function initialize(address token_, address pair_, address router_, address wbnb_, BuybackConfig calldata config)
        external
    {
        if (_initialized) revert AlreadyInitialized();
        if (token_ == address(0) || pair_ == address(0) || router_ == address(0) || wbnb_ == address(0)) {
            revert ZeroAddress();
        }
        _validateConfig(config);

        _initialized = true;
        token = token_;
        pair = pair_;
        router = router_;
        wbnb = wbnb_;
        mode = config.mode;
        trigger = config.trigger;
        triggerAmount = config.triggerAmount;
        buybackAmount = config.buybackAmount;
        callerReward = config.callerReward;
        intervalSeconds = uint64(uint256(config.intervalMinutes) * 60);
        createdAt = uint64(block.timestamp);
        nextExecuteTime = uint64(block.timestamp + uint256(config.startDelayMinutes) * 60);

        emit Initialized(token_, pair_, config.mode, config.trigger);
    }

    /// @dev 只收 BNB、记账。TaxProcessor 清算会走这条路径；零值 ping 静默忽略。
    receive() external payable {
        if (msg.value > 0) emit RevenueReceived(msg.sender, msg.value);
    }

    /// @notice 条件满足时执行一笔回购。任何人可调用（用户 / 机器人 / 平台 keeper）。
    /// @dev 成功才推进冷却；swap 失败整笔回滚。`callerReward` 从金库余额支付给 `msg.sender`。
    function executeBuyback() external nonReentrant {
        if (address(this).balance < buybackAmount + callerReward) revert InsufficientBalance();
        if (
            (trigger == TriggerMode.Balance || trigger == TriggerMode.TimeAndBalance)
                && address(this).balance < triggerAmount
        ) {
            revert InsufficientBalance();
        }
        if (!_timeOk()) revert TooEarly();

        lastExecuteTime = uint64(block.timestamp);
        nextExecuteTime = uint64(block.timestamp + intervalSeconds);
        unchecked {
            buybackCount += 1;
        }
        _activeCaller = msg.sender;

        if (callerReward > 0) {
            TransferHelper.safeTransferETH(msg.sender, callerReward);
        }

        if (mode == BuybackMode.LpBurn) {
            try this.lpBuybackAndBurn(buybackAmount) {}
            catch {
                emit BuybackFallbackToToken(buybackAmount);
                _tokenBuybackAndBurn(buybackAmount);
            }
        } else {
            _tokenBuybackAndBurn(buybackAmount);
        }
        _activeCaller = address(0);
    }

    /// @notice LP 买毁路径，仅供本合约 `try this.` 调用。失败则外层回退 Token 买毁。
    function lpBuybackAndBurn(uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _lpBuybackAndBurn(amount);
    }

    function canExecuteBuyback() public view returns (bool) {
        if (address(this).balance < buybackAmount + callerReward) return false;
        if (
            (trigger == TriggerMode.Balance || trigger == TriggerMode.TimeAndBalance)
                && address(this).balance < triggerAmount
        ) {
            return false;
        }
        return _timeOk();
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
        stats.callerReward = callerReward;
        stats.totalBuybackBNB = totalBuybackBNB;
        stats.totalBurnedToken = totalBurnedToken;
        stats.totalLpBurned = totalLpBurned;
        stats.buybackCount = buybackCount;
        stats.canExecute = canExecuteBuyback();
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

    function _validateConfig(BuybackConfig calldata config) internal pure {
        if (uint8(config.mode) > uint8(BuybackMode.LpBurn)) revert InvalidBuybackMode();
        if (config.intervalMinutes < MIN_INTERVAL_MINUTES || config.intervalMinutes > MAX_INTERVAL_MINUTES) {
            revert InvalidInterval();
        }
        if (
            config.buybackAmount < MIN_BUYBACK_AMOUNT || config.buybackAmount > MAX_BUYBACK_AMOUNT
                || config.buybackAmount % BUYBACK_PRECISION != 0
        ) {
            revert InvalidBuybackAmount();
        }
        if (config.callerReward > MAX_CALLER_REWARD || config.callerReward >= config.buybackAmount) {
            revert InvalidCallerReward();
        }

        TriggerMode t = config.trigger;
        if (t == TriggerMode.Time) {
            if (config.triggerAmount != 0) revert InvalidTriggerAmount();
            if (config.startDelayMinutes < MIN_INTERVAL_MINUTES || config.startDelayMinutes > MAX_INTERVAL_MINUTES) {
                revert InvalidStartDelay();
            }
        } else if (t == TriggerMode.Balance) {
            if (config.startDelayMinutes != 0) revert InvalidStartDelay();
            _validateTriggerAmount(config.triggerAmount);
        } else if (t == TriggerMode.TimeAndBalance) {
            if (config.startDelayMinutes < MIN_INTERVAL_MINUTES || config.startDelayMinutes > MAX_INTERVAL_MINUTES) {
                revert InvalidStartDelay();
            }
            _validateTriggerAmount(config.triggerAmount);
        } else {
            revert InvalidTriggerMode();
        }
    }

    function _validateTriggerAmount(uint256 amount) internal pure {
        if (amount < MIN_TRIGGER_AMOUNT || amount > MAX_TRIGGER_AMOUNT || amount % 1 ether != 0) {
            revert InvalidTriggerAmount();
        }
    }

    function _tokenBuybackAndBurn(uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        _swapBnbForToken(amount);
        uint256 bought = IERC20(token).balanceOf(address(this)) - before;
        if (bought > 0) {
            TransferHelper.safeTransfer(token, DEAD, bought);
        }
        totalBuybackBNB += amount;
        totalBurnedToken += bought;
        emit TokenBuybackExecuted(_activeCaller, amount, bought);
    }

    function _lpBuybackAndBurn(uint256 amount) internal {
        uint256 half = amount / 2;
        uint256 rest = amount - half;
        uint256 before = IERC20(token).balanceOf(address(this));
        _swapBnbForToken(half);
        uint256 bought = IERC20(token).balanceOf(address(this)) - before;

        uint256 sellBps = _sellTaxBps();
        uint256 discount = SLIPPAGE_BPS + sellBps;
        uint256 minToken = discount >= BPS_DENOMINATOR ? 0 : (bought * (BPS_DENOMINATOR - discount)) / BPS_DENOMINATOR;
        uint256 minBnb = (rest * (BPS_DENOMINATOR - SLIPPAGE_BPS)) / BPS_DENOMINATOR;

        TransferHelper.safeApprove(token, router, bought);
        (,, uint256 liquidity) = IPancakeRouter02(router).addLiquidityETH{value: rest}(
            token, bought, minToken, minBnb, DEAD, block.timestamp + DEADLINE_BUFFER
        );

        uint256 leftover = IERC20(token).balanceOf(address(this));
        if (leftover > 0) {
            TransferHelper.safeTransfer(token, DEAD, leftover);
            totalBurnedToken += leftover;
        }

        totalBuybackBNB += amount;
        totalLpBurned += liquidity;
        emit LpBuybackExecuted(_activeCaller, amount, liquidity, leftover);
    }

    function _swapBnbForToken(uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = token;

        uint256[] memory amounts = IPancakeRouter02(router).getAmountsOut(amount, path);
        uint256 taxBps = _buyTaxBps();
        uint256 discount = SLIPPAGE_BPS + taxBps;
        uint256 minOut = discount >= BPS_DENOMINATOR ? 0 : (amounts[1] * (BPS_DENOMINATOR - discount)) / BPS_DENOMINATOR;

        IPancakeRouter02(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            minOut, path, address(this), block.timestamp + DEADLINE_BUFFER
        );
    }

    function _buyTaxBps() internal view returns (uint256) {
        try IFlapTaxTokenV3(token).buyTaxRate() returns (uint16 rate) {
            return uint256(rate);
        } catch {
            return 0;
        }
    }

    function _sellTaxBps() internal view returns (uint256) {
        try IFlapTaxTokenV3(token).sellTaxRate() returns (uint16 rate) {
            return uint256(rate);
        } catch {
            return 0;
        }
    }
}
