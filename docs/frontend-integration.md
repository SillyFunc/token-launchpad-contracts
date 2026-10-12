# 前端对接文档 — Token Launchpad(BSC 主网)

> 当前部署网络:**BSC 主网(chainId 56)**。本文只描述这次主网部署的地址与参数,按当前源码编写。
>
> 地址以 `broadcast/Deploy.s.sol/56/run-latest.json` 与 `script/deployments/56.json` 为准。

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
9. [平台管理(仅管理员)](#9-平台管理仅管理员)
10. [附录:当前部署记录](#10-附录当前部署记录)

---

## 1. 网络与合约地址

### 1.1 网络参数

| 项 | 值 |
|---|---|
| 网络 | BSC 主网(BNB Smart Chain Mainnet) |
| chainId | `56` |
| 区块浏览器 | `https://bscscan.com` |
| 第三方 Router(PancakeSwap V2) | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| 代币初始 / 最低归集阈值 | 40 万 / 5 万 枚(以模板的 `START_LIQ_THRESHOLD()` 与 `MIN_LIQ_THRESHOLD()` 为准) |
| Keeper 地址(Java 服务) | `0xde9fB6fd189e802bce892058c26aa148eBEdB3Fa` |

### 1.2 前端入口与合约地址

**前端只需要直接调用 `CoordinatorFactory`。** 其余合约由 Coordinator 调度,或通过代币/预售实例间接访问。

| 合约 | 地址 | 前端是否直接调用 |
|---|---|---|
| **CoordinatorFactory** | `0xb73bdF3E86737F64E6f624112069F9D282a68e35` | ✅ 创建代币、配置预售、读平台数据 |
| FlapTaxTokenV3 模板 | `0x6980190344e6E485119039C9DC6bEC7971E28BC2` | ❌ 仅作为克隆实现 |
| TokenFactory | `0x0AA8E4edd3D00275B464daC30ac618a2aF14305a` | ❌ 由 Coordinator 调度 |
| PRESALE 模板 | `0x9CA45c3aE5A9Ca8cCf3f09E4B91B48c52eF23CeD` | ❌ 仅作为克隆实现(已锁定) |
| PresaleFactory | `0x350597F41B981cf5493a0d387FeD8646b76A0AFb` | ❌ 由 Coordinator 调度 |
| TaxProcessor 模板 | `0xeD32EEf193Cf589c4abFA76e19d6A35614F8bA0d` | ❌ 每个代币使用 EIP-1167 克隆 |
| Dividend 模板 | `0x53E6E5487D954AF595532b0D0660bBCd06Db8bFC` | ❌ 每个代币使用 EIP-1167 克隆 |
| TaxInfrastructureFactory | `0x7f28Ebdc94301D349C5CD1924A7dE3d6BD7b74A6` | ❌ 由 Coordinator 调度 |
| BuybackVault 模板 | `0x193335e9C56b4F34466b9FF66E9fB3D72dE685Bf` | ❌ 新建金库通过克隆得到 |
| BuybackVaultFactory | `0x81E3a74e859248737E43d60Fc1D66F44a203aBc5` | ❌ 由 Coordinator 调度 |

> 以上地址来自 2026-10-12 的主网部署,15 笔广播交易全部上链且回执成功,链上代码与接线(`routerAddress`、`taxInfrastructureFactory`、`buybackVaultFactory`、`KEEPER_ROLE`、`DEFAULT_ADMIN_ROLE`)已核对,10 个合约已在 BscScan 完成源码验证。
>
> 本次部署使用的 `TokenFactory` 与 `CoordinatorFactory` 是当前 ABI。请以本文的 `TokenConfig`(13 字段)与 `createTokenWithVault` 为准调用。

### 1.3 平台费用(读链获取,勿硬编码)

| 费用 | 读取 | 说明 |
|---|---|---|
| 发币费 | `coordinator.creationFee()` | 以链上为准 |
| 地址预留费 | `coordinator.reservationFee()` | 以链上为准 |

`msg.value` 超出所需费用的部分会在同一笔交易中退回,并触发 `ExcessRefunded`。

### 1.4 ABI 获取

ABI 以编译产物为唯一来源。前端仓库只保留实际调用的最小 ABI,不要复制整份产物。

```bash
forge inspect CoordinatorFactory abi --json > coordinator.abi.json
forge inspect PRESALE abi --json > presale.abi.json
forge inspect FlapTaxTokenV3 abi --json > token.abi.json
```

前端主要需要的合约:

- `CoordinatorFactory`:发币、预售配置、读取平台数据。
- `PRESALE`:每个代币的托管仓,地址由 `tokenPresales(token)` 获得。
- `FlapTaxTokenV3`:ERC20 + `state()`、`taxProcessor()` 等只读方法。
- `BuybackVault`:仅当代币启用金库时需要,地址由 `tokenVaults(token)` 获得。
- PancakeSwap `IPancakePair` / `IPancakeRouter02`:价格与报价。

---

## 2. 业务流程

> 核心原则:**状态迁移由合约在出口交易中自动完成**,用户全程只需调用业务入口。代币上线后 owner 为 `0x0`,这一点由合约保证。

### 2.1 流程 A:纯发币(不预售)

```
1. coordinator.createToken(config, salt)          创建者,value ≥ creationFee
     └ 链上:克隆代币 + 创建/复用 Pair + 克隆 TaxProcessor 与 Dividend + 建托管仓
       全量代币转入托管仓;代币 owner → 托管仓;托管仓 owner → 创建者

2. presale.claimAllTokens()                       创建者(托管仓 owner)
     └ 链上一笔内:startMigration → finalizeMigration(税生效)
       → renounceOwnership → 全量代币发放给创建者
       事件:AllTokensClaimed + 两条 PoolStateChanged(0→1, 1→2)
```

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

**`launch()` 在一笔交易内完成:**

1. `startMigration`(BondingCurve → Migrating)。
2. 用全部募资 BNB 与底池份额加池,LP 直接发送到 `0xdead`(永久锁定)。
3. 销毁未售出的预售份额(`presaleShare - totalSubscribedTokens`,转入 `0xdead`)。
4. 若创建者注资,执行创建者购买。
5. `finalizeMigration`(Migrating → TaxEnforcedAntiFarmer,税生效)。
6. `renounceOwnership`,并将 `presaleStatus` 置为 3。

前端无需任何手动迁移步骤。

**开盘终检**:`openPresale()` 在冻结条款前会检查以下条件,不满足则拒绝开盘:

- `presaleTokenPrice > 0`(`InvalidPrice`)。
- `presaleDuration` 在 `1 hours ~ 90 hours` 之间(`InvalidDuration`)。
- `maxBuyPerWallet > 0`(`InvalidMaxBuyPerWallet`)。
- `maxPresaleTokens` 在 `1 ~ presaleShare` 之间(`InvalidMaxPresaleTokens`)。
- `softCap ≥ minLiquidityAmount`(`SoftCapTooLow`);`minLiquidityAmount > 0`(`ZeroMinLiquidity`);有硬顶时 `softCap ≤ hardcap`(`SoftCapExceedsHardcap`)。
- 三份份额之和与托管余额一致(`AllocationMismatch`)。

通过 `setupPresale` 配置的路径恒满足这些条件。被拒绝时只需在配置期修正参数后重新调用,拒绝不消耗状态。

**开盘后(`presaleStatus == 3`):**

| 动作 | 调用者 | 说明 |
|---|---|---|
| `claim()` | 认购者 / 创建者 | 按 vesting 周期领取 |
| `withdrawRemainingBNB()` | 创建者 | 提取残留 BNB |

### 2.3 分支:预售失败与重开

进入失败态(`presaleStatus == 4`)的四种途径:

| 途径 | 触发者 | 条件 |
|---|---|---|
| `endPresale()` | 创建者(随时)/ 任何人(过 `endTime` 后) | 状态 1 且 `accumulatedBNB < softCap` |
| `enforceLaunchDeadline()` | 任何人 | 状态 2 超过 72 小时仍未 `launch()` |
| 硬顶自动结算 | 同笔 `subscribe` | 恰达硬顶且未达软顶(正常配置下不会出现) |

失败后的唯一出口:

| 动作 | 调用者 | 说明 |
|---|---|---|
| `refund()` | 认购者 | 精确退回本人全部缴款;退款同时作废本人份额 |
| `refundTo(recipient)` | 认购者 | 与 `refund()` 相同,但 BNB 发给指定地址。合约钱包拒收 BNB 时使用此入口 |
| `relaunchPresale()` | 创建者 | 须全部退款完毕(`accumulatedBNB == 0`)。回到配置期,`presaleRound` 加 1 |

**无代币回收出口**:失败局的代币锁在托管仓中,只能经重开新一轮上线。若有参与者永不退款,`relaunchPresale` 会一直阻塞(`RefundsOutstanding`),代币随之锁定。这是已知边界,前端应在状态 4 向参与者突出"请退款"引导,并对创建者显示未退款金额。

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

**税代币归集阈值:** 代币在卖出累积税金,达到阈值后,下一笔指向主池的转账会把税金转入 TaxProcessor 的处理队列。入队不会在用户交易中执行 swap,处理由 keeper 异步完成。阈值由模板的不可变参数决定,读 `token.liquidationThreshold()` 获取当前值。当前主网模板为 40 万(初始)/ 5 万(最低)枚。

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
    uint256 buybackAmount;      // 单次上限:0.001 ~ 10 BNB,且为 0.001 BNB 的整数倍
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

**Keeper 执行链:**

1. 代币达到归集阈值后,税代币进入 TaxProcessor 的队列。
2. keeper 调用 `processPendingTax(amountIn, minQuoteOut, deadline)` 分批将税代币换为 WBNB/BNB。失败则整笔回滚,税代币保留在处理器中等待重试。
3. 启用金库时,keeper 先调用 `previewBuyback()` 获取安全输入额,再报价并调用 `executeBuyback(expectedBnbIn, minTokenOut, minLpTokenOut, deadline)`。

两个 keeper 入口都要求 `deadline` 位于当前区块时间与未来 10 分钟之间,最低输出不得为 0。前端只读取状态,不向普通用户展示执行按钮。金库没有创建者提款入口。

**`previewBuyback()` 返回值:**

`(executableAmount, readiness)`,其中 `readiness` 为:

| 值 | 含义 |
|---:|---|
| 0 `Ready` | 可执行 |
| 1 `InsufficientBalance` | 余额低于执行下限(0.0001 BNB) |
| 2 `TriggerBalanceNotMet` | 未达余额门槛 |
| 3 `TooEarly` | 未到执行时间 |
| 4 `InvalidPoolReserves` | 交易对无双边储备 |
| 5 `ReserveCapBelowMinimum` | 储备的 1% 低于执行下限 |

实际可执行额恒为 `min(金库余额, buybackAmount, 交易对 WBNB 储备 × 1%)`。低流动性时会自动缩小,不会因固定金额超限而永久卡住。

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

**约束(与源码 `Presale.sol` 一致):**

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

- 默认:创建者 30% / 底池 20% / 预售 50%。
- 读取 `coordinator.creatorBps()`、`poolBps()`、`presaleBps()`。
- 比例在 `setupPresale` 时刻写入托管仓并冻结,之后的管理员调整只影响新代币。

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

**LP 通道细节:** 合约读取交易对的实际到账量,按真实储备计算需要的 BNB,不会按名义数量盲目加池。加池时产生的二次税进入下一轮处理,不会丢失。LP 直接铸给 `0xdead`,创建者、管理员、keeper 都无法提取。

**分红通道细节:**

- 持币达到 `minimumShareBalance` 的地址才参与分红,按有效持仓比例分配。
- 以下地址永远不参与分红:零地址、`0xdead`、代币合约自身、交易对、TaxProcessor、Dividend 合约、`flapBlackHole`,以及被管理员显式排除的地址。
- 用户调用 `withdrawDividends()` 领取,WBNB 在领取时自动解包为 BNB。
- 若当前没有符合条件的持币人,分红资金**不会**重新分给其他通道,而是保留在 TaxProcessor 中,等待下一次重试(`DividendDepositDeferred`)。

**配置约束:**

- `dividendBps == 0` 时 `minimumShareBalance` 必须为 0;`dividendBps > 0` 时必须大于 0。
- 四通道参数创建后永久固定:买税、卖税、四通道比例、市场收款地址、分红门槛、是否启用金库。配置错误只能重新创建代币。

**收益示例(演示数字,非承诺):** 卖税 3%、市场 40% / 销毁 10% / LP 20% / 分红 30%,用户卖出 10,000 枚代币:

```
税代币 = 10,000 × 3% = 300 枚
市场 120 枚 | 销毁 30 枚 | LP 60 枚 | 分红 90 枚
```

- 销毁 30 枚直接进入 `0xdead`。
- LP 的 60 枚中 30 枚保留、30 枚兑换;市场 120 枚与分红 90 枚也参与兑换,合计 240 枚在一次清算中兑换为 WBNB。
- 兑换所得按参与数量分配。若得到 2.4 BNB,则市场约得 1.2 BNB,LP 约得 0.3 BNB 加上 30 枚代币组成 LP,分红约得 0.9 WBNB。
- 实际结果取决于池储备、成交价、卖税造成的实际到账差异、滑点与 keeper 的最低输出保护。

**协议费与佣金通道(当前未启用):** TaxProcessor 中还有 `feeRate`(协议费)与 `commissionBps`(佣金)两个通道。平台当前发币时两者固定为 0,因此不会产生任何分配。取整余数(几个 wei)会归入协议费收款人,确保每一个 wei 都有归属。

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

topic0 为事件签名的 keccak 值,可直接用于 WebSocket 订阅或索引。

| 事件 | 用途 |
|---|---|
| `TokenPresalePairCreated(address,address,address,uint256)` | 新代币上架,在 Coordinator 上监听 |
| `BuybackVaultAttached(address,address,uint8,uint8)` | 发币时启用金库 |
| `TaxInfrastructureAttached(address,address,address)` | 代币绑定 TaxProcessor 与 Dividend |
| `TaxQueued(uint256,uint256)` | 税代币进入处理队列,第二项为当前待处理余额 |
| `TaxProcessed(uint256,uint256,uint256,uint256,int8)` | keeper 成功清算;含输入、quote 输出、销毁量、LP 储备量、方向信号 |
| `TaxForwarded(address,uint256,bool)` | quote 已转给最终收款人或金库;`isNative` 区分 BNB 与 WBNB |
| `TokenBuybackExecuted(address,uint256,uint256)` | 代币买入销毁成功 |
| `LpBuybackExecuted(address,uint256,uint256,uint256)` | LP 买回成功 |
| `BuybackFallbackToToken(uint256)` | LP 子路径失败并回退为代币买入销毁 |
| `TokenCreated(address,address,address)` | TokenFactory 创建代币;第三项为交易对 |
| `PresaleCreated(address,address)` | PresaleFactory 克隆托管仓 |
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

> 事件 topic0 与签名需要在新部署后用 `cast sig-event` 或 `forge inspect ... events` 重新核对,不要手抄。

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
| `BuybackVaultFactoryNotSet` | 金库工厂未配置(当前部署已配置,正常不会出现) |
| `TaxInfrastructureFactoryNotSet` | 税收基础设施未配置(当前部署已配置,正常不会出现) |
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
| `PresaleExpired` / `PresaleNotExpired` | 认购窗口未到或已过 |
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

### 6.3 BuybackVault(回购金库)

| 错误 | 含义 |
|---|---|
| `InvalidBuybackMode` / `InvalidTriggerMode` | 模式枚举越界 |
| `InvalidInterval` | 间隔不在 60 秒 ~ 365 天之间 |
| `InvalidFirstExecuteTime` | 首次时间不足 60 秒余量,或余额模式未填 0 |
| `InvalidTriggerAmount` | 门槛不合法 |
| `InvalidBuybackAmount` | 单次上限不在 0.001 ~ 10 BNB,或非 0.001 整数倍 |
| `TooEarly` | 未到执行时间 |
| `InsufficientBalance` | 金库余额不足 |
| `UnsafeExecutionAmount` | 预算超过实时安全上限(仅 keeper 调用) |
| `UnauthorizedKeeper` | 调用者不是授权 keeper |

### 6.4 TaxProcessor(每个代币一个实例)

| 错误 | 含义 |
|---|---|
| `NotTaxToken` | 调用者不是该代币 |
| `UnauthorizedTaxKeeper` | 调用者不是授权 keeper |
| `InvalidTaxAmount` | 税金数量非法 |
| `UnsafeMinQuoteOut` | 最低输出为 0 |
| `InvalidProcessingDeadline` | deadline 超出允许范围 |
| `InsufficientQuoteOutput` | 实际输出低于最低要求 |
| `InvalidBurnAmount` | 通缩销毁数量非法 |

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

### 7.6 新旧代币区分

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
| `previewBuyback()` | `(可执行额, readiness)` |
| `canExecuteBuyback()` | 是否可执行 |
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

通过 `token.dividendContract()` 获取,使用标准 OpenZeppelin 与分红接口读取持有人可领取额。

---

## 9. 平台管理(仅管理员)

以下操作仅 `CoordinatorFactory.DEFAULT_ADMIN_ROLE` 可执行,前端只需读取其结果。

| 函数 | 用途 |
|---|---|
| `setCreationFee(fee)` / `setReservationFee(fee)` | 修改费用,必须非零 |
| `setFactoryEnabled(bool)` | 暂停或恢复发币 |
| `setAllocation(creatorBps, poolBps, presaleBps)` | 修改份额比例,三项均大于 0 且和为 10000 |
| `withdrawFees()` | 提取平台收入到调用者地址 |

管理员脚本示例:

```bash
forge script script/SetPlatformFees.s.sol:SetPlatformFees \
  --sig "run(address,uint256,uint256)" \
  <CoordinatorFactory 地址> 5000000000000000 1000000000000000 \
  --rpc-url <BSC 主网 RPC> \
  --account <FOUNDRY_ACCOUNT> \
  --broadcast
```

上例将创建费设为 0.005 BNB,预留费设为 0.001 BNB。两项费用是两个独立的 setter,变更两项会产生两笔交易,不是原子操作。

---

## 10. 附录:当前部署记录

### 10.1 当前部署

| 网络 | chainId | 广播文件 | 部署日期 | 交易 | 回执 |
|---|---:|---|---|---:|---|
| BSC 主网 | 56 | `broadcast/Deploy.s.sol/56/run-latest.json` | 2026-10-12 | 15 | 15/15 成功 |

模板参数为 `MIN = 50,000 ether`、`START = 400,000 ether`(即最低 5 万 / 初始 40 万枚),已由链上 `START_LIQ_THRESHOLD()` 与 `MIN_LIQ_THRESHOLD()` 核实。

部署所用源码包含预售托管仓的分红修复:`TaxInfrastructureFactory.createInfrastructure` 会对 Dividend 调用 `excludeAddress(presale)`。

### 10.2 核对与验证状态

- 10 个合约均有链上代码,地址与 `script/deployments/56.json` 一致。
- 接线已核对:`routerAddress` 为 PancakeSwap V2 主网路由器;`taxInfrastructureFactory`、`buybackVaultFactory` 指向本次部署地址。
- 角色已核对:Keeper 持有 `KEEPER_ROLE`,部署账户持有 `DEFAULT_ADMIN_ROLE`。
- 10 个合约均已在 BscScan 完成源码验证。

### 10.3 后续待办

1. 用最小金额完整走一遍:创建、配置、认购、结算、开盘、领取。金库流程需单独验证。

### 10.3 上线前核对清单

1. 读取 `broadcast/Deploy.s.sol/<chainId>/run-latest.json`,确认全部回执状态为成功。
2. 对每个部署地址核对链上代码与构造参数。
3. 在目标网络读取 `coordinator.routerAddress()`,确认其 `WETH()` 与 `factory()` 调用成功。
4. 读取模板的 `START_LIQ_THRESHOLD()` 与 `MIN_LIQ_THRESHOLD()`,与预期值比对。
5. 用最小金额完整走一遍:创建、配置、认购、结算、开盘、领取。金库流程需单独验证。
