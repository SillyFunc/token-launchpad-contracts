# 前端对接文档 — Token Launchpad(BSC 主网)

> 本文仅维护当前前端调用、参数校验、状态展示与错误处理所需的对接约定，不收录变更记录或内部运维步骤。可读配置以目标合约的链上返回值为准。

---

## 目录

1. [网络与合约地址](#1-网络与合约地址)
2. [业务流程](#2-业务流程)
3. [参数详解](#3-参数详解)
4. [状态机与事件](#4-状态机与事件)
5. [价格与市值](#5-价格与市值)
6. [错误对照表](#6-错误对照表)
7. [注意事项](#7-注意事项)
8. [视图函数清单](#8-视图函数清单)

---

## 1. 网络与合约地址

### 1.1 网络参数

| 项 | 值 |
|---|---|
| 网络 | BSC 主网(BNB Smart Chain Mainnet) |
| chainId | `56` |
| 区块浏览器 | `https://bscscan.com` |
| 第三方 Router(PancakeSwap V2) | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |

### 1.2 前端入口与合约地址

创建代币、配置预售与地址预留通过 `CoordinatorFactory`；认购、开盘、退款和领取直接调用对应实例。

| 合约 | 地址 | 用途 |
|---|---|---|
| CoordinatorFactory | `0xb73bdF3E86737F64E6f624112069F9D282a68e35` | 发币、预售配置、地址预留、平台数据 |
| TokenFactory | `0x0AA8E4edd3D00275B464daC30ac618a2aF14305a` | 仅只读预测代币地址；可通过 `coordinator.tokenFactory()` 获取 |

| 实例 | 地址获取方式 | 前端用途 |
|---|---|---|
| PRESALE | `coordinator.tokenPresales(token)` | 认购、开盘、退款、领取及预售状态 |
| BuybackVault | `coordinator.tokenVaults(token)` | 只读回购状态与统计；`0x0` 表示未启用 |
| TaxProcessor | `coordinator.tokenTaxProcessors(token)` | 只读税收与分红统计 |
| Dividend | `coordinator.tokenDividends(token)` | 查询与领取持币分红 |
| Pancake Pair | `presale.lpAddress()` 或 `token.mainPool()` | 储备、价格与 LP 信息 |

地址来源：[部署清单](../script/deployments/56.json)与[广播产物](../broadcast/Deploy.s.sol/56/run-latest.json)。模板地址不是用户业务入口。

> **对接状态:**当前主网金库的 `MIN_EXECUTION_AMOUNT()` 为 `0.0001 BNB`。源码版本为 `1 wei`，状态为 **pending deployment**，不能视为当前地址能力；前端展示执行下限时读取目标金库的 `MIN_EXECUTION_AMOUNT()`。

### 1.3 平台费用(读链获取,勿硬编码)

| 费用 | 读取 | 说明 |
|---|---|---|
| 发币费 | `coordinator.creationFee()` | 以链上为准 |
| 地址预留费 | `coordinator.reservationFee()` | 以链上为准 |

`msg.value` 超出所需费用的部分会在同一笔交易中退回,并触发 `ExcessRefunded`。

### 1.4 ABI 使用

使用与目标部署匹配的编译产物 ABI，仅保留实际使用的函数、事件与错误定义。所需接口为 `CoordinatorFactory`、`PRESALE`、`FlapTaxTokenV3`、`BuybackVault`、`TaxProcessor`、`Dividend`，以及地址预测用的 `TokenFactory` 和报价用的 Pancake Pair / Router。不要将待部署接口绑定到现有地址。

---

## 2. 业务流程

> 用户只需调用下列业务入口，无需手动迁移代币；上线后代币 owner 为 `0x0`。

### 2.1 流程 A:纯发币(不预售)

| 顺序 | 调用 | 调用者 | 结果 |
|---|---|---|---|
| 1 | `coordinator.createToken(config, salt)` | 创建者，`value ≥ creationFee` | 创建代币与托管仓，全量代币由托管仓持有 |
| 2 | `presale.claimAllTokens()` | 创建者 | 全量代币发给创建者、税生效、代币所有权放弃；触发 `AllTokensClaimed` |

领取后代币即为普通的已上线税代币:转账直接 `transfer`;加池、交易随时在 PancakeSwap 上完成。

### 2.2 流程 B:预售开盘

| # | 调用 | 调用者 | payable | 前置条件 |
|---|---|---|---|---|
| 1 | `coordinator.createToken(config, salt)` | 创建者 | `≥ creationFee` | 工厂启用 |
| 2 | `coordinator.setupPresale(token, pConfig)` | 创建者 | 可选(创建者购买注资) | 每个代币只能配置一次 |
| 3 | `presale.openPresale()` | 创建者 | — | `presaleStatus == 0` |
| 4 | `presale.subscribe()` × N | 认购者 | 认购 BNB | `presaleStatus == 1` 且 `startTime ≤ now < endTime` |
| 5 | `presale.endPresale()` | 创建者(随时)/ 任何人(过 `endTime` 后) | — | `presaleStatus == 1` |
| 6 | `presale.launch()` | 创建者 | — | `presaleStatus == 2` 且 `accumulatedBNB ≥ minLiquidityAmount` |

**时间窗口:**

- `endTime = max(openPresale 时刻, startTime) + presaleDuration`。晚开盘不会缩短认购窗口。
- **硬顶自动结算**:某笔认购使 `accumulatedBNB` 恰好等于 `hardcap` 时,同一笔交易内结束认购(进入状态 2 或 4)。超出硬顶的认购会 revert(`HardcapReached`),调小金额即可。
- **72 小时开盘窗口**:进入状态 2 后,`LAUNCH_DEADLINE`(72 小时)内必须 `launch()`。超时后任何人可调用 `enforceLaunchDeadline()`,使其进入失败态。前端应在状态 2 展示 72 小时倒计时。
- `launch()` 本身不检查 72 小时。超时但尚未有人 enforce 时,创建者仍可开盘;一旦 enforce 之后,状态闸会永久封锁开盘。

`launch()` 成功后进入状态 3：全部募资 BNB 与底池份额加池，LP 永久锁定至 `0xdead`，未售出的预售份额销毁；有创建者注资时执行购买，代币税生效并放弃所有权。

`openPresale()` 会校验配置；前端按[参数约束](#32-presaleconfig11-字段仅-setuppresale-一次性生效)检查输入，失败后仍可在配置期修正并重试。

**开盘后(`presaleStatus == 3`):**

| 动作 | 调用者 | 说明 |
|---|---|---|
| `claim()` | 认购者 / 创建者 | 按 vesting 周期领取 |
| `withdrawRemainingBNB()` | 创建者 | 提取残留 BNB |

### 2.3 分支:预售失败与重开

进入失败态(`presaleStatus == 4`)的条件:

| 途径 | 触发者 | 条件 |
|---|---|---|
| `endPresale()` | 创建者(随时)/ 任何人(过 `endTime` 后) | 状态 1 且 `accumulatedBNB < softCap` |
| `enforceLaunchDeadline()` | 任何人 | 状态 2 超过 72 小时仍未 `launch()` |
| 硬顶自动结算 | 同笔 `subscribe` | 恰达硬顶且未达软顶(正常配置下不会出现) |

失败后的可用操作:

| 动作 | 调用者 | 说明 |
|---|---|---|
| `refund()` | 认购者 | 精确退回本人全部缴款;退款同时作废本人份额 |
| `refundTo(recipient)` | 认购者 | 与 `refund()` 相同,但 BNB 发给指定地址。合约钱包拒收 BNB 时使用此入口 |
| `relaunchPresale()` | 创建者 | 须全部退款完毕(`accumulatedBNB == 0`)。回到配置期,`presaleRound` 加 1 |

失败轮次的代币仍由托管仓持有，无回收入口，只能重开后上线。前端应向参与者突出退款入口，并向创建者展示未退款金额；只要仍有未退款金额，就不能重开(`RefundsOutstanding`)。

> 状态 4 下 `accumulatedBNB` 与 `totalSubscribedTokens` 会随退款递减。历史募资额请以 `PresaleFailed(raisedBNB, softCap)` 事件为准。

### 2.4 地址规则:尾号 8888(CREATE2)

所有代币地址的低 16 位必须为 `0x8888`。`salt = 0` 已被拒绝(`InvalidSalt`),必须提供搜索得到的盐。

```
默认流程(免费):
1 前端本地搜盐 → 找到地址尾号为 8888 的 salt(平均约 65536 次尝试)
2 coordinator.createToken{value: ≥ creationFee}(config, salt)

防抢跑(可选,付费且不退):
1 搜盐
2 coordinator.reserveTokenAddress{value: ≥ reservationFee}(salt)   锁定权属
3 coordinator.createToken(config, salt)                            本人兑现
```

**搜盐规则(必须遵守):**

- 地址公式:`keccak256(0xff ‖ tokenFactory ‖ salt ‖ keccak256(initCode))[12:]`。也可以直接循环调用 `tokenFactory.predictTokenAddress(salt)`(视图函数)。
- **盐必须由随机种子派生**,例如 `salt = keccak256(randomness, counter)`。严禁从 0 或固定值递增,否则用户会撞盐,后到者 `CloneFailed`。
- 命中条件:`uint160(predicted) & 0xFFFF == 0x8888`。
- 只搜 CREATE2 盐,不生成任何私钥。
- 抢跑风险可忽略;在意者使用付费预留。

---

## 3. 参数详解

### 3.1 `TokenConfig`(13 字段)

```solidity
struct TokenConfig {
    string  name;                    // 非空
    string  symbol;                  // 非空
    string  meta;                    // 元数据 URI(如 IPFS CID),可为空串
    uint16  buyTax;                  // 买税 bps,0 ≤ x ≤ 1000
    uint16  sellTax;                 // 卖税 bps,0 ≤ x ≤ 1000
    address feeRecipient;            // 市场通道收款人;非零。启用金库时被覆盖为金库地址
    uint16  marketBps;               // 市场/回购通道占比
    uint16  deflationBps;            // 直接销毁通道占比
    uint16  lpBps;                   // 自动加池并销毁 LP 通道占比
    uint16  dividendBps;             // WBNB 持币分红通道占比
    uint256 minimumShareBalance;     // 参与分红的最小持币量(token wei)
    uint256 antiFarmerDuration;      // 防夹持续时间(秒),0 ~ 365 days
    uint256 liqExpectedOutputAmount; // 清算方向调节参考值(BNB wei);0 = 关闭动态调整,建议固定传 0
}
```

**约束:**

- `buyTax`、`sellTax` 超过 1000 bps 会 revert(`BuyFeeTooHigh` / `SellFeeTooHigh`)。前端滑杆限制在 0–10%。
- `marketBps + deflationBps + lpBps + dividendBps` 必须等于 `10000`(`InvalidTaxDistribution`)。允许某一项为 0。
- `dividendBps == 0` 时 `minimumShareBalance` 必须为 0;`dividendBps > 0` 时必须在 `1 ~ 1_000_000_000 ether` 之间(`InvalidMinimumShareBalance`)。建议默认 `10_000 ether`。
- 分红资产固定为 WBNB,创建者不能选择其他币种。
- 税期固定为 `TAX_DURATION() == 100 * 365 days`,由 Coordinator 注入,不由前端传入。
- `antiFarmerDuration` 不得超过 `MAX_ANTI_FARMER_DURATION() == 365 days`(`InvalidAntiFarmerDuration`)。
- 代币固定 18 位小数,总量通过 `token.maxSupply()` 读取,禁止硬编码。
- 代币支持 ERC20Permit。

**税费到账时机:** 税费异步处理，不保证与买卖交易同时到达收款人、分红合约或金库。当前归集阈值读取 `token.liquidationThreshold()`，待处理量读取 `taxProcessor.pendingTaxTokens()`。

### 3.1.1 自动回购金库(可选)

`createTokenWithVault` 与 `createToken` 参数相同,另加一个 `BuybackConfig`。启用后,市场通道的税金收款人被替换为金库,其余三个通道保持不变。因此 `marketBps` 必须大于 0(`VaultRequiresMarketChannel`)。

```solidity
function createTokenWithVault(TokenConfig tokenConfig, bytes32 salt, BuybackConfig buyback)
    payable returns (address token, address presale, address vault);
```

读取 `coordinator.tokenVaults(token)` 获得金库地址,`0x0` 表示未启用。

```solidity
enum BuybackMode  { TokenBurn, LpBurn }                // 0 买入代币销毁;1 买入代币并加 LP 后锁定(失败回退为 0)
enum TriggerMode  { Time, Balance, TimeAndBalance }    // 0 按时间;1 按余额门槛;2 两者同时满足

struct BuybackConfig {
    BuybackMode mode;
    TriggerMode trigger;
    uint64  firstExecuteAt;     // Unix 秒。trigger=0/2 时必须至少晚于创建 60 秒;trigger=1 时必须为 0
    uint64  intervalSeconds;    // 60 ~ 31536000 秒
    uint256 triggerAmount;      // trigger=0 必须为 0;trigger=1/2 时 ≥ buybackAmount 且 ≤ 1000 BNB
    uint256 buybackAmount;      // 单次上限:0.001 ~ 10 BNB,且为 0.001 BNB 的整数倍；实际执行额仍会被余额与储备安全上限缩小
}
```

| UI 选项 | `trigger` | `firstExecuteAt` | `triggerAmount` | 首次执行条件 |
|---|---:|---:|---:|---|
| 按时间 | `0` | 所选时间的 Unix 秒 | `0` | 到达所选时间 |
| 按金库余额 | `1` | `0` | 门槛(BNB wei) | 余额达到门槛后可立即执行 |
| 时间 + 余额 | `2` | 所选时间的 Unix 秒 | 门槛(BNB wei) | 时间与余额同时满足 |

- `firstExecuteAt` 必须是绝对时间戳。前端显示的时区只影响展示,提交时需转换为 Unix 秒。
- 交易上链时,时间模式的 `firstExecuteAt` 仍须晚于当时区块时间 60 秒,前端应预留钱包确认余量。
- **过期行为**:首次时间过期后,合约不会拒绝执行,也不会顺延。开盘后只要余额、储备与 keeper 条件满足,即会立即执行首次回购,之后按间隔推进。

税费处理与回购执行仅限授权 keeper；前端只展示状态和统计，不向普通用户提供执行按钮。金库没有创建者提款入口。

**`previewBuyback()` 返回值:**

`(executableAmount, readiness)`,其中 `readiness` 为:

| 值 | 含义 |
|---:|---|
| 0 `Ready` | 可执行 |
| 1 `InsufficientBalance` | 金库余额低于 `MIN_EXECUTION_AMOUNT()` |
| 2 `TriggerBalanceNotMet` | 未达余额门槛 |
| 3 `TooEarly` | 未到执行时间 |
| 4 `InvalidPoolReserves` | 交易对无双边储备 |
| 5 `ReserveCapBelowMinimum` | WBNB 储备的 1%(向下取整)低于执行下限 |

`Ready` 时返回的 `executableAmount` 是本次最大允许预算：`min(金库余额, buybackAmount, 交易对 WBNB 储备 × 1%)`，不是保证支出或成交金额。实际成交仍受最低输出等条件约束。

### 3.2 `PresaleConfig`(11 字段,仅 `setupPresale` 一次性生效)

```solidity
struct PresaleConfig {
    uint256 presaleTokenPrice;    // 每枚代币的 BNB 价格(wei,18 位)。例:1e15 = 0.001 BNB/枚
    uint256 maxBuyPerWallet;      // 每钱包认购上限(代币 wei)
    uint256 hardcap;              // 募资硬顶(BNB wei),0 = 不限
    uint256 minLiquidityAmount;   // 加池最低 BNB(也是 launch 的门槛)
    uint256 softCap;              // 认购成功线(BNB wei)
    uint256 startTime;            // 认购开始时间(Unix 秒),0 = 立即
    uint256 duration;             // 认购时长(秒)
    uint256 vestingDelay;         // vesting 每期间隔(秒)
    uint256 vestingRate;          // 每期释放百分比
    uint256 slippage;             // 加池滑点保护 bps,0 = 使用默认 5%
    uint256 creatorBuyTokens;     // 创建者购买目标(代币 wei);0 = quote 模式
}
```

**输入约束:**

| 字段 | 合法区间 | 错误 |
|---|---|---|
| `presaleTokenPrice` | > 0 | `InvalidPrice` |
| `maxBuyPerWallet` | > 0 | `InvalidMaxBuyPerWallet` |
| `minLiquidityAmount` | > 0 | `ZeroMinLiquidity` |
| `softCap` | `≥ minLiquidityAmount`;有硬顶时 `≤ hardcap` | `SoftCapTooLow` / `SoftCapExceedsHardcap` |
| `duration` | **1 小时 ~ 90 小时**(3600 ~ 324000 秒) | `InvalidDuration` |
| `vestingDelay` | **5 分钟 ~ 30 分钟**(300 ~ 1800 秒) | `InvalidVestingDelay` |
| `vestingRate` | 5 ~ 20 | `InvalidVestingRate` |
| `slippage` | ≤ 1000 | `SlippageTooHigh` |
| `creatorBuyTokens > 0` | 需要 `msg.value > 0` | `CreatorBuyTokensWithoutFunding` |

### 3.2.1 `PresaleRoundConfig`(失败后重开)

失败轮次全部退款并调用 `relaunchPresale()` 后,创建者可以用一笔 `setPresaleConfig(config)` 原子覆盖下一轮全部商业参数:

```solidity
struct PresaleRoundConfig {
    uint256 presaleTokenPrice;    // > 0
    uint256 maxPresaleTokens;     // 1 ~ presaleShare
    uint256 maxBuyPerWallet;      // > 0
    uint256 hardcap;              // 0 = 不限
    uint256 minLiquidityAmount;   // > 0
    uint256 softCap;              // minLiquidityAmount ≤ softCap ≤ hardcap(有硬顶时)
    uint256 startTime;            // 0 = 立即
    uint256 duration;             // 1 小时 ~ 90 小时
    uint256 vestingDelay;         // 5 分钟 ~ 30 分钟
    uint256 vestingRate;          // 5 ~ 20
    uint256 slippageProtection;   // 实际滑点 bps,0 ~ 1000
}
```

推荐流程:`relaunchPresale()` → `setPresaleConfig(config)` → `openPresale()`。批量入口只在 `presaleStatus == 0` 时可用,不修改已冻结的份额、模式、Token/Pair/Router 或所有权,也不接受创建者注资。任一字段非法则整笔回滚,旧配置保持不变。

> `setupPresale` 中 `slippage == 0` 表示使用默认 5%;而 `setPresaleConfig` 的 `slippageProtection` 为实际写入值。重开时若要保持 5%,应明确传 `500`,或读取当前 `presale.slippageProtection()` 原样传入。

**份额比例**由管理员配置,前端动态读取,不要提供输入框:

- 配置前读取 `coordinator.creatorBps()`、`poolBps()`、`presaleBps()`。
- 比例在 `setupPresale` 时冻结；已配置的预售应读取实例的 `creatorShare()`、`poolShare()`、`presaleShare()`，不要套用平台当前比例。

### 3.3 创建者购买注资(`setupPresale` 的 `msg.value`)

- `msg.value == 0`:不注资,开盘行为与无购买时一致。
- `msg.value > 0` 且 `creatorBuyTokens == 0`(quote 模式):开盘时按市价买入。花费上限为底池 BNB 的 `1/19`(`MAX_CREATOR_BUY_POOL_BPS = 500`),超出部分与失败时的全部金额会在同一笔交易中退回。
- `msg.value > 0` 且 `creatorBuyTokens > 0`(token 模式):精确买入目标数量,超额部分退回。上限为底池份额的 5%。
- 误注资可以在开盘前通过 `presale.withdrawCreatorBuy()` 撤回。

### 3.4 认购到账公式

```
认购代币量(1e18 精度) = msg.value(wei) × 1e18 / presaleTokenPrice
```

例:价格 `1e15`(0.001 BNB/枚),支付 1 BNB,得 1000 枚。

### 3.5 四通道税收分配(`TokenConfig` 的 `*Bps` 字段)

代币的税分两层:**买税 / 卖税**决定一笔交易收取多少税;**四通道比例**决定收到的税如何分配。

```
交易税     = 交易数量 × 买税或卖税
通道份额   = 交易税 × 对应通道比例(bps / 10000)
marketBps + deflationBps + lpBps + dividendBps = 10000(必须精确相等)
```

| 通道 | 参数 | 处理方式 | 创建者得到什么 |
|---|---|---|---|
| 市场 | `marketBps` | 税代币兑换为 BNB,发送到 `feeRecipient` | 普通模式下为创建者收入;金库模式下进入回购金库 |
| 销毁 | `deflationBps` | 税代币直接发送到 `0xdead`,不经过交易池 | 无,仅通缩 |
| LP | `lpBps` | 一半保留为代币,一半兑换为 BNB,组成 LP 后铸给 `0xdead` | 无,永久增加流动性 |
| 分红 | `dividendBps` | 税代币兑换为 WBNB,存入该代币的 Dividend 合约 | 无,奖励符合条件的持币人 |

**市场通道的两种用法:**

- 普通模式(`createToken`):`marketBps` 对应的 BNB 进入 `feeRecipient`。
- 金库模式(`createTokenWithVault`):`feeRecipient` 被替换为回购金库,市场份额用于自动回购并销毁(或加 LP 后锁定)。金库模式要求 `marketBps > 0`。

**分红展示与领取:**

- 持币达到 `minimumShareBalance` 且未被排除的地址，按有效持仓比例参与分红；托管仓、交易对等系统地址不参与分红。
- 可领取额读取 `dividend.withdrawableDividendOf(user)`，用户调用 `dividend.withdrawDividends()` 领取 BNB。
- 暂无有效持币人时，分红保留在 TaxProcessor 等待后续分配，不转入其他通道；不要将其余额直接展示为用户可领取额。

**配置约束:**

- `dividendBps == 0` 时 `minimumShareBalance` 必须为 0;`dividendBps > 0` 时必须大于 0。
- 四通道参数创建后永久固定:买税、卖税、四通道比例、市场收款地址、分红门槛、是否启用金库。配置错误只能重新创建代币。

---

## 4. 状态机与事件

### 4.1 托管仓 `presaleStatus`

| 值 | 含义 | 可执行的下一步 |
|---:|---|---|
| 0 | 配置期 | `setupPresale`(仅首轮,由 Coordinator)/ `setPresaleConfig`(重开)/ `openPresale` / `claimAllTokens`(纯发币) |
| 1 | 认购中 | `subscribe`;`endPresale` |
| 2 | 认购结束,待开盘 | `launch`(72 小时内);`enforceLaunchDeadline`(超时后) |
| 3 | 已开盘(终态) | `claim`;`withdrawRemainingBNB` |
| 4 | 发行失败 | `refund` / `refundTo`;`relaunchPresale` |

**判断模式:** 读 `presale.presaleEnabled()`。该值在 `setupPresale` 时写入,之后不可改变。

| `presaleEnabled` | `presaleStatus` | 含义 |
|---|---:|---|
| `false` | 0 | 纯发币,未领取 |
| `true` | 0 | 预售配置期(或失败后的新一轮,用 `presaleRound` 区分) |
| `true` | 1 / 2 | 认购中 / 待开盘 |
| `true` | 3 | 成功开盘(终态) |
| `true` | 4 | 失败(可退款或重开) |

纯发币领取完成后,代币 owner 为 `0x0`,`state ≥ 2`。预售失败的代币将停留在 `BondingCurve`,只能经重开后上线。判断模式请使用 `presaleEnabled`,不要根据代币分布或 owner 推断。

### 4.2 代币 `token.state()`(PoolState)

| 值 | 含义 | 税收 |
|---:|---|---|
| 0 `BondingCurve` | 初始态,**禁止与交易对转账** | 无 |
| 1 `Migrating` | 迁移中(仅在出口交易内部存在) | 无 |
| 2 `TaxEnforcedAntiFarmer` | 税与防夹生效 | 买卖税 + 防夹 |
| 3 `TaxEnforced` | 防夹期结束,税继续 | 买卖税 |
| 4 `TaxFree` | 税到期 | 无 |

前端把 `state ≥ 2` 视为"已上线",`state == 0` 视为"未上线"。

判断上线可以组合读取:`token.state() >= 2 && token.owner() == 0x0`。

### 4.3 关键事件与 topic0

使用目标合约 ABI 解码下列事件；`topic0 = keccak256(事件规范签名)`，由 ABI 工具生成，用于订阅或索引。

| 事件 | 用途 |
|---|---|
| `TokenPresalePairCreated(address,address,address,uint256)` | 新代币上架,在 Coordinator 上监听 |
| `BuybackVaultAttached(address,address,uint8,uint8)` | 发币时启用金库 |
| `TaxInfrastructureAttached(address,address,address)` | 代币绑定 TaxProcessor 与 Dividend |
| `TaxQueued(uint256,uint256)` | 税代币进入处理队列,第二项为当前待处理余额 |
| `TaxProcessed(uint256,uint256,uint256,uint256,int8)` | 税费处理完成，用于刷新税收统计 |
| `TaxForwarded(address,uint256,bool)` | quote 已转给最终收款人或金库;`isNative` 区分 BNB 与 WBNB |
| `TokenBuybackExecuted(address,uint256,uint256)` | 代币买入销毁成功 |
| `LpBuybackExecuted(address,uint256,uint256,uint256)` | LP 买回成功 |
| `BuybackFallbackToToken(uint256)` | LP 子路径失败并回退为代币买入销毁 |
| `PoolStateChanged(uint8,uint8)` | 代币状态迁移;0→1→2 连续两条表示出口交易已执行 |
| `AllTokensClaimed(address,uint256,uint256)` | 纯发币领取完成 |
| `Subscribed(address,uint256,uint256)` | 认购流水 |
| `PresaleEnded()` | 认购达标结束(进入状态 2) |
| `PresaleFailed(uint256,uint256)` | 发行失败;`raisedBNB` 为判定时刻快照 |
| `LaunchDeadlineExceeded(uint256,uint256)` | 72 小时未开盘,翻为失败 |
| `PresaleRelaunched(uint256)` | 失败后重开,`round` 为轮次计数 |
| `LaunchFinalized(uint256,uint256,uint256)` | 开盘完成 |
| `UnsoldTokensBurned(uint256,uint256)` | 未售出份额销毁,与 `launch` 同笔 |
| `Refunded(address,uint256)` / `RefundedTo(address,address,uint256)` | 退款 |
| `VestingClaimed(address,uint256,uint256)` | vesting 领取 |
| Pancake `Sync(uint112,uint112)` | 交易对储备变化,用于实时价格 |

---

## 5. 价格与市值

### 5.1 预售阶段(状态 0/1/2,交易对尚无流动性)

价格为固定认购价:

```js
const price = await presale.read.presaleTokenPrice()   // wei,每枚代币的 BNB 价格
```

### 5.2 上线后

从交易对读取储备:

```js
const pair = await presale.read.lpAddress()   // 或 PancakeFactory.getPair(token, WBNB)
const [token0, [r0, r1]] = await Promise.all([pair.read.token0(), pair.read.getReserves()])
const isToken0 = token0.toLowerCase() === token.toLowerCase()
const tokenReserve = isToken0 ? r0 : r1
const bnbReserve   = isToken0 ? r1 : r0
const priceInBNB   = bnbReserve * 10n ** 18n / tokenReserve   // 18 位定点
```

- 实时更新:订阅交易对的 `Sync` 事件,或每 3–5 秒轮询 `getReserves()`。
- 储备为 0 时显示"未开盘/无流动性",不要显示 0 价格。

### 5.3 展示价与执行价

- 储备比值是中间价,仅用于展示。
- 买入预估使用 `router.getAmountsOut(...)`,包含 0.25% 路由费与滑点。
- 税代币买家实收 = 报价输出 × (1 − buyTax / 10000)。

### 5.4 市值

代币总量恒定,市值直接按总量计算:

```
市值(USD) = 价格(USD) × totalSupply
```

| 阶段 | 价格来源 |
|---|---|
| 预售中 | `presaleTokenPrice()` |
| 已上线 | 交易对储备比 |
| 未开盘 | 显示 "—" |

BNB/USD 获取:

- 链上:`router.getAmountsOut(1e18, [WBNB, USDT])`,或 Binance 公共 API。

---

## 6. 错误对照表

错误以 4 字节 selector 表示。下表列出前端需要翻译的常见错误。

### 6.1 CoordinatorFactory

| 错误 | 含义 |
|---|---|
| `FactoryDisabled` | 工厂已暂停 |
| `InsufficientCreationFee` | 发币费不足 |
| `EmptyTokenName` / `EmptyTokenSymbol` | 名称或符号为空 |
| `InvalidSalt` | 盐为 0 |
| `InvalidVanitySuffix` | 地址尾号不是 8888 |
| `NotReserver` | 地址已被他人预留 |
| `AddressAlreadyReserved` / `AddressAlreadyDeployed` | 地址已预留或已部署 |
| `InvalidAntiFarmerDuration` | 防夹时长超过 365 天 |
| `InvalidTaxDistribution` | 四通道占比之和不是 10000 |
| `InvalidMinimumShareBalance` | 分红最小持币量与分红比例不匹配 |
| `VaultRequiresMarketChannel` | 启用金库时 `marketBps == 0` |
| `BuybackVaultFactoryNotSet` / `TaxInfrastructureFactoryNotSet` | 平台配置异常，提示稍后重试或联系支持 |
| `AlreadyConfigured` | 该代币预售已配置过 |
| `NotTokenCreator` | 调用者不是代币创建者 |
| `TokenNotRegistered` | 代币不是本平台创建 |
| `InvalidPrice` | 预售价格为 0 |
| `ZeroMinLiquidity` | 加池最低 BNB 为 0 |
| `InvalidMaxBuyPerWallet` | 每钱包上限为 0 |
| `CreatorBuyTokensWithoutFunding` | 设置了创建者购买数量但未注资 |

### 6.2 PRESALE(托管仓)

| 错误 | 含义 |
|---|---|
| `PresaleNotOpen` | 当前状态不接受认购 |
| `PresaleNotStarted` | 认购尚未开始 |
| `PresaleExpired` | 认购窗口已结束 |
| `ZeroValue` | 认购金额为 0 |
| `AmountTooSmall` | 认购换算出的代币数为 0 |
| `PresaleSoldOut` | 超过预售份额上限 |
| `WalletLimitExceeded` | 超过每钱包上限 |
| `HardcapReached` | 超过募资硬顶 |
| `InvalidStatus` | 当前状态不允许该操作 |
| `InsufficientBNB` | 募资低于加池门槛 |
| `PresaleNotExpired` | 尚未到期，当前调用者不能提前结束认购 |
| `LaunchDeadlineNotReached` | 尚未达到 72 小时开盘期限 |
| `RefundsOutstanding` | 仍有未退款金额,不能重开 |
| `NothingToClaim` / `NoTokensToClaim` / `TokensAlreadyClaimed` | 无可领取内容 |
| `InvalidDuration` | 认购时长超出 1 小时 ~ 90 小时 |
| `InvalidVestingDelay` | vesting 间隔超出 5 分钟 ~ 30 分钟 |
| `InvalidVestingRate` | vesting 比例超出 5 ~ 20 |
| `SlippageTooHigh` | 滑点超过 1000 bps |
| `SoftCapTooLow` / `SoftCapExceedsHardcap` | 软顶配置不合法 |
| `CreatorBuyLocked` | 开盘后不能撤回创建者购买 |
| `PairAlreadyInitialized` | 交易对已有流动性,拒绝重复开盘 |

### 6.3 回购金库创建参数

| 错误 | 含义 |
|---|---|
| `InvalidBuybackMode` / `InvalidTriggerMode` | 模式枚举越界 |
| `InvalidInterval` | 间隔不在 60 秒 ~ 365 天之间 |
| `InvalidFirstExecuteTime` | 首次时间不足 60 秒余量,或余额模式未填 0 |
| `InvalidTriggerAmount` | 门槛不合法 |
| `InvalidBuybackAmount` | 单次上限不在 0.001 ~ 10 BNB,或非 0.001 整数倍 |

---

## 7. 注意事项

### 7.1 费用与退款

- 发币费与预留费不可退。超额的 `msg.value` 同笔退回。
- 失败的预售不收取额外费用,认购者可全额退款。

### 7.2 税收对买卖的影响

- 税收由代币合约自动扣除,买家实收少于报价。
- 卖出时税金先进入代币合约,达到归集阈值后异步处理。
- 税期内转账受防夹规则约束(`antiFarmerDuration` 期间)。

### 7.3 LP 信任差异

- 预售加池的 LP 直接发送到 `0xdead`,永久锁定,创建者无法撤池。
- 纯发币模式下,创建者在上线后负责自行加池;前端应提示用户查看交易对的 LP 持有人。

### 7.4 时间相关参数

所有时间参数均为 **Unix 秒**。前端可以展示为小时或天,写入合约前必须换算。

### 7.5 金额单位

所有金额均为 wei(18 位小数)。前端输入使用 `parseEther`,展示使用 `formatEther`。

### 7.6 平台代币识别

判断代币是否为本平台创建,应检查 `tokenExists(token)`;代币总量以 `token.maxSupply()` 读取。非本平台创建的代币不应展示为本平台代币。

---

## 8. 视图函数清单

### 8.1 CoordinatorFactory(入口,只读)

| 函数 | 返回 |
|---|---|
| `creationFee()` / `reservationFee()` | 平台费用 |
| `factoryEnabled()` | 工厂是否启用 |
| `creatorBps()` / `poolBps()` / `presaleBps()` | 当前份额比例 |
| `routerAddress()` | PancakeSwap Router |
| `tokenFactory()` | 地址预测用的 TokenFactory |
| `tokenPresales(token)` | 代币对应的托管仓 |
| `tokenCreators(token)` | 代币创建者 |
| `tokenVaults(token)` | 代币对应的回购金库(0 = 未启用) |
| `tokenTaxProcessors(token)` / `tokenDividends(token)` | 税收处理器与分红合约 |
| `tokenExists(token)` | 是否为本平台创建 |
| `tokenAddressReserver(address)` | 地址预留者 |
| `getTokenPresalePairDetails(token)` | 代币与托管仓的基础信息 |
| `getAllTokenPresalePairs(offset, limit)` | 全量分页列表 |
| `getTokenPresalePairsByCreator(creator, offset, limit)` | 按创建者分页 |
| `getCreatorTokenCount(creator)` / `getTotalTokenCount()` | 计数 |

### 8.2 PRESALE(托管仓实例)

| 函数 | 返回 |
|---|---|
| `presaleStatus()` | 状态 0–4 |
| `presaleEnabled()` | 是否为预售模式 |
| `presaleRound()` | 当前轮次 |
| `presaleTokenPrice()` | 认购价 |
| `maxBuyPerWallet()` / `hardcap()` / `softCap()` | 上限与门槛 |
| `minLiquidityAmount()` | 加池最低 BNB |
| `startTime()` / `endTime()` / `presaleDuration()` | 时间窗口 |
| `accumulatedBNB()` | 当前累计募资 |
| `totalSubscribedTokens()` | 当前认购代币量 |
| `subscribedTokens(user)` / `contributions(user)` | 个人认购与缴款 |
| `getVestedAmount(user)` | 当前可领取量 |
| `vestingDelay()` / `vestingRate()` / `vestingStart()` | vesting 参数 |
| `slippageProtection()` | 滑点保护 |
| `coinAddress()` / `lpAddress()` | 代币与交易对地址 |
| `creatorShare()` / `poolShare()` / `presaleShare()` | 三项份额 |
| `LAUNCH_DEADLINE()` | 72 小时常量 |
| `getContractBalances()` | 托管仓代币与 BNB 余额 |

### 8.3 代币(克隆实例)

| 函数 | 返回 |
|---|---|
| `state()` | `PoolState`(0–4) |
| `owner()` | 当前 owner(上线后为 0x0) |
| `maxSupply()` | 固定总量 |
| `buyTaxRate()` / `sellTaxRate()` | 当前买卖税 |
| `liquidationThreshold()` | 当前归集阈值 |
| `taxExpirationTime()` / `antiFarmerExpirationTime()` | 税与防夹到期时间 |
| `mainPool()` | 主交易对 |
| `taxProcessor()` / `dividendContract()` | 税收处理器与分红合约 |
| `getPoolStateData()` | 池状态打包数据 |

### 8.4 BuybackVault(回购金库)

| 函数 | 返回 |
|---|---|
| `previewBuyback()` | `(最大允许预算, readiness)`，见 3.1.1 |
| `canExecuteBuyback()` | 是否满足当前执行条件，不保证交易成交 |
| `MIN_EXECUTION_AMOUNT()` | 目标金库的执行下限，以链上返回值为准 |
| `getVaultStats()` | 完整统计:余额、模式、触发、上次与下次时间、累计买回量等 |
| `nextExecuteTime()` / `lastExecuteTime()` | 下次与上次执行时间 |
| `totalBuybackBNB()` / `totalBurnedToken()` / `totalLpBurned()` | 累计数据 |

### 8.5 TaxProcessor

| 函数 | 返回 |
|---|---|
| `pendingTaxTokens()` | 待处理税代币数量 |
| `dividendQuoteBalance()` | 待分红 WBNB 余额 |
| `totalQuoteSentToDividend()` | 累计分红金额 |
| `getQuoteToken()` | 计价币(WBNB) |

### 8.6 Dividend

通过 `coordinator.tokenDividends(token)` 或 `token.dividendContract()` 获取实例。

| 函数 | 返回 |
|---|---|
| `withdrawableDividendOf(user)` | 用户当前可领取金额 |
| `withdrawnDividends(user)` | 用户累计已领取金额 |
| `minimumShareBalance()` | 参与分红的最小持币量 |
| `totalShares()` | 当前有效持仓总量 |
| `totalDividendsDistributed()` | 累计已分配金额 |
| `dividendToken()` | 分红资产地址；本平台为 WBNB，领取时解包为 BNB |
