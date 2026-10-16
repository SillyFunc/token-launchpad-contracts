# 前端对接文档 — Token Launchpad(BSC 主网)

> 当前部署网络:**BSC 主网(chainId 56)**。第 1–10 节描述 2026-10-12 已部署版本;第 11 节描述 2026-10-16 源码新增能力,状态为 **pending deployment（待部署）**。
>
> 地址以 `broadcast/Deploy.s.sol/56/run-latest.json` 与 `script/deployments/56.json` 为准。
>
> 当前源码的新 ABI 不得直接绑定上述旧地址。新 Coordinator、TaxProcessor、Vault 与 Reader 尚无本轮已核验部署地址。

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
11. [待部署版本:执行开关、统一读取与资金回收](#11-待部署版本执行开关统一读取与资金回收)

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
> 本表对应 2026-10-12 部署版本的 ABI。该版本的 `TokenConfig` 为 13 字段,支持本文既有 `createTokenWithVault` 接口;第 11 节的新维护接口不在这些旧地址上生效。

### 1.3 平台费用(读链获取,勿硬编码)

| 费用 | 读取 | 说明 |
|---|---|---|
| 发币费 | `coordinator.creationFee()` | 以链上为准 |
| 地址预留费 | `coordinator.reservationFee()` | 以链上为准 |

`msg.value` 超出所需费用的部分会在同一笔交易中退回,并触发 `ExcessRefunded`。

### 1.4 ABI 获取

ABI 以编译产物为唯一来源。前端仓库只保留实际调用的最小 ABI,不要复制整份产物。

旧地址须使用相应部署版本的 ABI。下列命令读取的是**当前工作区源码**:本轮新增接口尚未部署,不能据此将旧地址升级为新版配置。部署核验前,新方法只用于本地验证或待部署配置。

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

本节数值与就绪原因对应第 1.2 节的已部署版本。取消固定 0.0001 BNB 下限及新增暂停状态属于第 11 节的待部署版本。

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

实际可执行额恒为 `min(金库余额, buybackAmount, 交易对 WBNB 储备 × 1%)`。已部署版本要求结果至少为 0.0001 BNB;因此 WBNB 储备少于 0.01 BNB 时仍会返回 `ReserveCapBelowMinimum`,即使金库余额充足也不能执行。新版处理见第 11 节。

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

---

## 11. 待部署版本:执行开关、统一读取与资金回收

**状态:pending deployment。以下接口没有本轮已核验的主网或测试网地址,不得向第 1.2 节的旧地址发送这些新调用。** 本轮没有修改 `broadcast/`、`script/deployments/56.json` 或 `script/deployments/97.json` 的既有部署含义。

旧 clone 固定指向原实现,Factory 的实现地址不可变,旧 Coordinator 的工厂接线只能配置一次。因此这次源码改造不会升级已有代币实例,也不能取出旧 Vault 的 BNB。部署并核对接线、角色、代码和 ABI 后,才能单独发布新版地址配置。

### 11.1 三个全局执行开关

新版 Coordinator 是执行控制注册中心。仅其 `DEFAULT_ADMIN_ROLE` 可更新开关,Keeper 角色没有更新权限。

```solidity
function executionFlags() external view returns (uint8);
function setExecutionControls(
    bool taxProcessingEnabled,
    bool liquidityEnabled,
    bool buybackEnabled
) external;
event ExecutionControlsUpdated(uint8 executionFlags);
error ExecutionPaused(uint8 operation);
```

| 位值 | 状态读取 | 关闭后禁止的资金操作 |
|---:|---|---|
| `1` | `(flags & 1) != 0` | TaxProcessor 的 `processPendingTax`、`processPendingBurn` |
| `2` | `(flags & 2) != 0` | TaxProcessor 的 `addPendingLiquidity`;Vault 的整笔 `LpBurn` 回购 |
| `4` | `(flags & 4) != 0` | Vault 的 `executeBuyback`,包括 TokenBurn 和 LpBurn |

初始值 `7` 表示全部允许;`setExecutionControls(false,false,false)` 写入 `0`,表示全部暂停。它与发币开关 `factoryEnabled` 独立。LpBurn 需同时允许 liquidity 与 buyback;LP 暂停在外层回购入口检查,不会触发 fallback 改为 TokenBurn 后继续支出。

各维护入口均在链上重新读取注册中心并强制检查,注册中心调用失败时禁止执行。设置暂停本身不改资产余额、分账、回购次数或冷却;正常收税、`processTaxTokens` 入队、固定收款人 `dispatch()`、正常交易和已有分红领取继续可用。仅暂停 LP 而保持清算时,LP 两边资产保留在 `lpTokenBalance/lpQuoteBalance`,恢复后重新报价继续处理。**同时关闭 TAX 和 LIQUIDITY 时,还会向所有代币的原始创建者开放第 11.4 节的 TaxProcessor 结算权**,包括临时暂停;已结算资产不会在恢复开关后自动归还。

`ExecutionPaused` 的参数为被禁止的操作位值。暂停交易先上链后,此前已签名的 Keeper 交易仍会回滚并消耗 Gas;前端显示状态不能保证未来交易一定执行。旧实例没有新开关检查,不能用新 Coordinator 的开关控制旧实例。

| ABI 项 | selector / topic0 |
|---|---|
| `executionFlags()` | `0xa9a0c49f` |
| `setExecutionControls(bool,bool,bool)` | `0x1f7d747d` |
| `ExecutionPaused(uint8)` | `0xfec64777` |
| `ExecutionControlsUpdated(uint8)` | `0x791dc0b316c439749670138dc38ad814b0c98686387c86b96201eca4d91d2d3c` |

以上签名已用 `cast sig` / `cast keccak` 从源码签名计算,不代表任何地址已部署。

### 11.2 小额回购与就绪状态

新版取消固定 **0.0001 BNB** 执行下限,输入仍必须至少为 **1 wei**,且不得超过 `min(BNB余额,buybackAmount,WBNB储备×1%)`。保留 Keeper 角色、十分钟 deadline、非零最低输出、实际到账检查和既有回购模式。1% 上限不会因为取消最低金额而放宽。

WBNB 储备少于 0.01 BNB 的小池可以产生正数执行额;若储备比例向下取整为零、买入实际输出为零或 LP 整数舍入无法铸造有效 LP,仍须停止或回滚,不能仅增加统计而记作成功。创建时 `buybackAmount` 仍是原范围的单次**上限**,没有放宽创建参数的范围或精度。

`previewBuyback()` 仍返回 `(uint256 executableAmount,uint8 readiness)`,原 `0–5` 的编号保留,新增 `6 Paused`。注册中心读取失败会直接报错,不伪装为 `Paused`。

| readiness | 名称 | 新版含义 |
|---:|---|---|
| `0` | `Ready` | 合约前置条件满足;仍需有效输出报价、Keeper 权限与 Gas 判断 |
| `1` | `InsufficientBalance` | 金库 BNB 为零 |
| `2` | `TriggerBalanceNotMet` | 余额触发模式下未达到创建者配置的门槛 |
| `3` | `TooEarly` | 首次时间或执行间隔尚未满足 |
| `4` | `InvalidPoolReserves` | 任一资产储备为零 |
| `5` | `ReserveCapBelowMinimum` | 保留旧名称;新版指 1% 储备上限向下取整后不足 1 wei |
| `6` | `Paused` | buyback 关闭,或当前为 LpBurn 且 liquidity 关闭 |

`getVaultStats()` 保留原有 **17 个字段及顺序**,提款累计数据通过独立 getter 获取。

Keeper 仍可因价格锚点、输出舍入、Gas 经济性或预算返回等待状态。`MAX_GAS_COST_BPS` 默认 `1000`（最大 Gas 费用不超过本笔保守价值的 10%）,可配置范围为 `1–10000`;每币和全局窗口 Gas 预算继续适用。因此“链上允许小额回购”不代表自动服务会为不经济的小额交易花 Gas。

### 11.3 BuybackVault 创建者提款

当前测试阶段使用**一个 `BuybackVault` 实现**,直接包含 BNB/WBNB 提款,不再区分测试与正式实现。后续正式上线时重新部署合约。本轮沿用原 initializer、Factory 与 `BuybackConfig`,不新增创建者初始化参数或存储。前端必须明确提示**创建者可提取金库资金**,不能将本版金库宣传为不可撤回。

金库以 `Coordinator.tokenCreators(token)` 确认原始创建者,不以预售 owner 或后来持币地址确定权限。仅该创建者可以调用 `withdrawAll(recipient)`,将执行时的 BNB/WBNB 全部余额转至其指定的非零、非金库自身地址。无需填写金额,一笔交易完成。权限覆盖税金与直接注资,不区分“本金”和“收益”。BNB 与 WBNB 分别计量;展示 WBNB 余额时需读取该资产的 ERC20 `balanceOf(vault)`,不能将 BNB 余额视为二者之和。

合约先读取两种余额并更新各自累计提款量,再依次转出非零 WBNB、非零 BNB。某种余额为零时跳过该资产;两者均为零时成功无操作且不发事件。提款与回购共用重入保护,任一步转账或接收者回调失败时,两种资产转账、累计提款量和事件全部回滚。提款不会推进回购冷却或增加累计回购支出。提款先执行使已报价回购余额不足时,回购须回滚并重新报价;不能自动缩额继续使用旧报价。接收者若在回调中主动返还资产,该新增余额留待下一次提款。

使用 `script/Deploy.s.sol:Deploy` 与 `script/deployments/<chainId>.json` 单一路径,新版部署记录包含 `reader` 与 `readerSchemaVersion=1`。本轮没有执行部署或改写现有部署记录,不能因脚本已更新就将旧记录当作支持提款的新地址。

新版金库接口如下,累计量和事件金额均为对应资产的最小单位。`withdrawAll` 原样转出 WBNB,不会解包为 BNB;该方法不依赖三个自动化开关的开闭状态。本次以它替换此前草案中的两个按金额提款方法,不再保留部分提款入口。

```solidity
function creator() external view returns (address);
function totalWithdrawnBNB() external view returns (uint256);
function totalWithdrawnWBNB() external view returns (uint256);
function withdrawAll(address payable recipient) external;
event BNBWithdrawn(address indexed creator, address indexed recipient, uint256 amount);
event WBNBWithdrawn(address indexed creator, address indexed recipient, uint256 amount);
```

| 金库方法 / 错误 | selector | 含义 |
|---|---|---|
| `creator()` | `0x02d05d3f` | 从固定 Coordinator 记录查询原始创建者 |
| `totalWithdrawnBNB()` | `0x03c52528` | 累计成功回收的 BNB |
| `totalWithdrawnWBNB()` | `0x683eee78` | 累计成功回收的 WBNB |
| `withdrawAll(address)` | `0xfa09e630` | 创建者一次回收执行时全部 BNB 和 WBNB;两者均为零时成功无操作 |
| `UnauthorizedCreator()` | `0x8ef0dd5d` | 调用者不是原始创建者;Keeper/管理员角色本身不授予提款权 |
| `InvalidWithdrawalRecipient()` | `0xb6061256` | 接收人为零地址或金库自身 |
| `ETHTransferFailed(address)` | `0x1c988062` | 接收者拒绝 BNB 或回调失败;整笔提款回滚 |
| `TransferFailed(address,address)` | `0x523c3aaa` | WBNB 转账失败;参数依次为资产与接收者 |

| 金库事件 | topic0 |
|---|---|
| `BNBWithdrawn(address,address,uint256)` | `0x7d1ee786b44013dac56ff80394b0f72d1a7d8120f5cde9a1304eabc78a7980ce` |
| `WBNBWithdrawn(address,address,uint256)` | `0x5f92646e296b84d55bbd67199030fcfaac2af3236ec4b5d0693b6185f21ea07a` |

两个事件的 `topic1/topic2` 分别为原始创建者与接收者,数量在 data 中;仅对非零资产的实际转账发出对应事件。提款失败时累计回收量和事件也一并回滚;共享的 `ReentrancyGuard` 阻止提款与回购的交叉重入。创建者记录读取失败时拒绝提款,不会以管理员或预售 owner 作为备用授权人。`withdrawAll` 没有金额参数,因此移除原草案的金额检查错误。以上 selector/topic 均由实际源码签名计算,仍为 **pending deployment**。

验收脚本 `KeeperAcceptance` 与 `PresaleAcceptance` 使用 `script/deployments/<chainId>.json`;产物分别为 `<chainId>-keeper-acceptance.json` 与 `<chainId>-presale-acceptance.json`。不再提供实现模式切换。验收仍需核对目标 Coordinator 与代币创建者、预售仓、金库的链上归属;脚本仅支持 BSC 测试网 chainId `97`,不会自动部署。

本节只覆盖已进入金库的 BNB/WBNB。TaxProcessor 中的待清税费、单边 LP、尚未分配分红与直接收到的 BNB 使用下一节的独立结算入口;已经进入 Dividend 的资产仍保障持有人领取。已销毁代币与发往 dead 的 LP 是预期不可逆终态。

### 11.4 TaxProcessor 暂停后的创建者结算

**状态:pending deployment,源码实现与本地资金回归已完成,尚未部署。** 用户已明确授权待加池资产及尚未进入 Dividend 的分红资金归原始代币创建者。使用新版部署的 `Coordinator.tokenTaxProcessors(token)` 定位对应处理器,直接向该处理器调用以下新方法;不得向 Coordinator、Vault 或旧 TaxProcessor 地址误发调用。

```solidity
function withdrawAll(address recipient) external;
event TaxAssetsWithdrawn(
    address indexed creator,
    address indexed asset,
    address indexed recipient,
    uint256 amount
);
error TaxProcessingActive();
error UnauthorizedTaxCreator();
error InvalidTaxWithdrawalRecipient();
```

调用者必须是 `Coordinator.tokenCreators(taxToken)` 登记的原始创建者,预售 owner 变更不会转移权限;Keeper 和管理员角色本身没有结算权。管理员须先把 TAX 与 LIQUIDITY 两位均关闭,即 `(executionFlags & 3) == 0`;BUYBACK 位可以保持开启。仅关闭其中一项不足以结算。**这里没有永久停用状态,任何临时全局暂停也会让所有代币创建者获得同样的结算机会**,前端和管理员必须明确这一权限效果。

`recipient` 只决定归属创建者部分的接收地址,不改变平台费、佣金和普通市场收款人的归属。拒绝零地址、TaxProcessor 自身、税代币、Dividend、router、quote、WBNB 和该税代币登记的任意 pool 地址,防止将回收款送回交易或内部记账入口。创建者指定 recipient 还不得是 Coordinator 登记的本币 Vault,避免原始税代币转入仅支持 BNB/WBNB 提款的 Vault。每笔非零转出的实际固定收款人也须通过上述危险地址检查;无效时整笔回滚,不因属于固定配置就绕过校验。固定 quote 通道仍可向本币 Vault 分配,其中 raw 税代币通道则按下表改发创建者。固定 Coordinator 的读取失败时拒绝结算,不退回管理员授权或绕过开关。

| 处理器持有的资产 | 结算去向 |
|---|---|
| 未清算税代币的 fee / commission / market 份额 | 沿用 `_splitTax` 的原配比与舍入规则,原币发原收款人;若原收款人是 Coordinator 为本币登记的非零 Vault,该税代币份额改发创建者指定 recipient,避免在只支持 BNB/WBNB 提款的 Vault 形成税代币滞留 |
| 未清算税代币的 burn 份额 | 原币转入 dead |
| 已预留 LP 税代币及未清税的 LP / dividend 份额 | 原币发创建者指定 recipient |
| 已记账的 fee / commission / market quote | quote 原币发原固定收款人;其中 Vault 收到 WBNB 后,创建者再调用 Vault.withdrawAll 取出 |
| `lpQuoteBalance` / `pendingDividendQuoteTokenBalance` / `dividendTokenBalance` | quote 原币发创建者指定 recipient,不必凑齐双边 LP,不要求存在合格分红持有人 |
| `pendingDeflationQuoteBalance` | quote 原币发 dead,不兑换税代币、不记录为已买回税代币 |
| 处理器原生 BNB | 先包装为 WBNB;quote 是 WBNB 时按既有 donation 规则归 feeReceiver,否则额外 WBNB 原币发 feeReceiver |
| 超出 quote 账本的捐赠余额 | 沿用既有 donation 规则归 feeReceiver |
| 已进入 Dividend 的资金 | 不受本入口影响,仍由持有人按原领取规则领取 |

本方法不执行 DEX swap、加池或价格换算,所有 WBNB 均以 ERC20 原币转出,不会转成 BNB。先核对实际余额覆盖账本,清零本批全部待处理账本与 `pendingDirection`,再执行分配。任何转账、包装或外部调用失败均整笔回滚,先前转账、账本变化、统计和事件不保留;入口与现有维护/dispatch 共用重入保护。接收者拒收或外部资产合约失效仍可能阻塞本次结算,不能宣传为任意故障下的通用资产救援。

仅实际 raw 税代币销毁增加 `totalTaxTokenBurned`,实际 quote 销毁增加 `totalQuoteBurned`;quote 派发沿用 `totalQuoteSentToReceiver`,市场 quote 派发同时增加 `totalQuoteSentToMarketing`。归创建者的 LP / dividend 资产退出不增加加池成功量、已派发分红量或回购统计。每笔非零转出发出 `TaxAssetsWithdrawn`;amount 是处理器转出的对应资产最小单位,不对未知转账税资产承诺接收者一定等额到账。全零余额时成功无操作且不发转出事件。

| 方法 / 错误 | selector | 含义 |
|---|---|---|
| `withdrawAll(address)` | `0xfa09e630` | 原始创建者在 TAX 与 LIQUIDITY 均关闭时按通道结算处理器全部受管资产;与 Vault 方法同 selector,调用目标和语义不同 |
| `TaxProcessingActive()` | `0x7bb6b217` | TAX 或 LIQUIDITY 仍开启 |
| `UnauthorizedTaxCreator()` | `0x62804125` | 调用者不是该税代币原始创建者 |
| `InvalidTaxWithdrawalRecipient()` | `0xb8c5c4a1` | 创建者指定 recipient 属于禁止范围（含本币 Vault）,或非零转出的实际固定收款人属于危险地址;固定 quote 通道的正常 Vault 收款不因此被禁止 |
| `AccountingInvariant()` | `0x1406395f` | 实际资产不足以覆盖对应待处理账本,整笔回滚 |

| 事件 | topic0 |
|---|---|
| `TaxAssetsWithdrawn(address,address,address,uint256)` | `0x34156777a4223d89a71e842e63e755cc0b318be7a36347edf7c4a339561933b0` |

事件 `topic1/topic2/topic3` 依次是原始创建者、资产、实际接收地址,amount 在 data 中;按出账逐笔记录,同一资产和接收者可能出现多个通道事件,客户端汇总时累加即可。以上 selector/topic 从签名计算,不是已部署证明。

暂停期间 `processTaxTokens` 仍可收到后续税,原始创建者可再次调用本方法结算,不把首次清空当作永远无余额。`dispatch()` 继续允许把待分红款存入 Dividend;若它先上链,已入 Dividend 的那部分不能再由创建者取走。结算和正常派发之间的交易排序不构成对同一笔资产的双重领取。恢复开关只恢复后续维护能力,不会撤销已完成的创建者结算。

本方法只处理约定的税代币、quote 与 BNB/WBNB,不提供任意 ERC20 sweep,不挪用 Dividend 已记账资金,不修改旧实例。本轮已完成 26 项退出边界测试、真实 Flap/Dividend 领取权益集成与 BSC/Pancake fork 验证,全量结果及成本见 [维护设计](maintenance-design.md)。新接口仍需新部署与接线核验;当前地址继续使用旧部署 ABI。

### 11.5 Reader 统一只读快照

新版全平台只部署一个 `Reader`,构造时固定绑定新版 Coordinator。它不托管资产、不需要 Keeper 角色。入口为 `getTokenSnapshot(address token)`（selector `0x1bd26a50`）,返回一个带命名组件的 ABI tuple,客户端解码为对象;不是链上 JSON 字符串。

| 对象字段 | 内容 |
|---|---|
| `schemaVersion` | `uint8`,快照结构版本,本轮版本 `1` |
| `blockNumber` / `blockTimestamp` | 均为 `uint256`,同一次只读执行的区块号与 Unix 秒 |
| `contracts` | 五个 `address`:`token`、`pair`、`taxProcessor`、`vault`、`wbnb` |
| `controls` | `uint8 executionFlags`,按 `1/2/4` 解码 |
| `pool` | 三个 `uint256`:`reserveToken`、`reserveWbnb`、`totalSupply`;`uint8 state`;`uint16 buyTaxRate/sellTaxRate`;`uint256 taxExpirationTime` |
| `tax` | `uint256 pendingAmount`、`feeConfig`（既有 `feeConfigV2` 结构） |
| `liquidity` | 两个 `uint256`:`pendingToken`、`pendingWbnb` |
| `buyback` | 两个 `uint256`:BNB `balance`、`executableAmount`;两个 `uint8`:`mode`、`readiness`;`uint64 nextExecuteTime` |

没有金库时 `contracts.vault` 明确为零地址,整个 `buyback` 对象为零值;必须先判断 Vault 地址,不能将零值 `readiness=0` 解读为存在可执行金库。注册代币、合约接线与核心状态读取失败时应报错,不能把异常包装成零余额或“无需执行”。返回的即时储备只用于展示和约束量级,不能作为同池成交的独立抗操纵报价。

| Reader 方法 / 错误 | selector | 含义 |
|---|---|---|
| `coordinator()` | `0x0a009097` | Reader 固定绑定的 Coordinator |
| `getTokenSnapshot(address)` | `0x1bd26a50` | 读取注册代币的完整快照 |
| `InvalidReaderCoordinator()` | `0x640c6747` | 构造参数无代码或控制位不符合本版约定;不支持的 Coordinator ABI 也会使构造失败 |
| `ReaderUnknownToken(address)` | `0x507cd83f` | Coordinator 未登记该代币的创建者 |
| `ReaderInvalidPair()` | `0x8328f762` | Pair 的两种资产不是该代币与 WBNB |

Keeper 通过配置 `READER_ADDRESS` 启用 Reader,并核对其 `coordinator()` 与所配置 Coordinator 一致。新版部署应配置部署记录中的 Reader,以便服务提前识别暂停并跳过任务;未配置仅保留既有旧版批量读取适配,不会主动读取新版控制位,链上检查仍会拒绝被暂停操作。新版 Reader 不支持旧 Coordinator;显式启用后,读取失败、版本不符或接线不符必须报错,不能吞错退回旧版。Reader 与新地址均仍为 **pending deployment**,目前不要为旧部署填入虚构的 Reader 地址。

### 11.6 maintainToken 链下调度

`maintainToken` 是 Keeper 内部方法,不是新增链上函数或任意人可调用的资金入口。它按 **tax → liquidity → buyback** 的顺序安排允许且经济的任务。候选任务可以复用同一只读快照,但每次真正签名前 Signer 都重新读取状态并重新计算报价。已提交、已有提交或 Signer 忙碌时即停止本轮后续步骤,由后续持久化轮次继续;不为一个方法调用阻塞等待链上,也不把三个步骤强行合成一笔交易。

签名前仍检查 Keeper 角色、链上开关、历史价格锚点、模拟、输出边界、冷却、余额与 Gas 预算。正常暂停和经济等待不作为交易失败刷告警,签名、广播或记账异常仍进入重试与诊断。没有增加链上批处理、任意目标 `call`、跨合约 `delegatecall`、资产托管或代币授权。

部署成本沿用 EIP-1167 clone:Reader 全平台共享,`maintainToken` 在链下运行,BuybackVault 直接包含提款代码但通过既有 Coordinator 记录识别创建者,不新增 creator 存储或 initializer 参数。三个控制位使用一个 `uint8`,与已有布尔/地址状态一起打包;最终合约大小与部署 Gas 度量见 [维护设计](maintenance-design.md),须按实际编译结果记录,不将估计值当作已支付费用。
