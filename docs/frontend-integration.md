# 前端对接文档 — Token Launchpad（BSC 测试网）

> 主网对接请使用 [主网专用文档](frontend-integration-mainnet.md)。两份文档的网络、部署地址和时间参数彼此独立维护。

> 源码版本：**testnet 分支待部署安全修复版**（新增配置方一次性锁、份额/余额守恒校验、Pair 预创建复用与单边储备安全加池、`refundTo` 合约钱包退款）。下列地址仍是当前链上旧部署；新版本部署并经 `broadcast/` 与链上核验后才能替换，前端在此之前不得把新 ABI 用于这些地址。
> 部署验证：BscScan 源码验证 5/5 全绿 + 全场景链上冒烟测试通过（成功链路 / 硬顶自动结算 / 到期 force-end 三段 / 失败单出口 / 退款跨轮 / 72h 门禁 / 预留费），交易哈希见附录 A
> ⚠️ **本节地址即当前链上旧部署**（97 链），不包含本分支安全修复。
> ⚠️ 当前开发代码新增 `setPresaleConfig` 批量配置入口；本节所列旧部署在重新部署前不支持该 ABI。

---

## 目录

1. [网络与合约地址](#1-网络与合约地址)
2. [两条业务流程](#2-两条业务流程)
3. [参数详解](#3-参数详解)
4. [状态机与事件](#4-状态机与事件)
5. [价格方案](#5-价格方案)
6. [错误对照表](#6-错误对照表)
7. [注意事项与坑位清单](#7-注意事项与坑位清单)
8. [视图函数清单](#8-视图函数清单)
9. [viem 快速上手](#9-viem-快速上手)
10. [附录 A：部署核验记录](#附录-a部署核验记录)

---

## 1. 网络与合约地址

### 1.1 网络

| 项 | 值 |
|---|---|
| 链 | BSC 测试网（BNB Smart Chain Testnet） |
| chainId | `97` |
| RPC（HTTP） | `https://bsc-testnet-rpc.publicnode.com` |
| RPC（WebSocket） | `wss://bsc-testnet-rpc.publicnode.com` |
| 区块浏览器 | `https://testnet.bscscan.com` |

### 1.2 本平台合约（当前链上部署，源码已验证）

| 合约 | 地址 | 前端是否直接交互 |
|---|---|---|
| **CoordinatorFactory（唯一入口）** | `0x4d2B161095f6B2A88832eae8FA07aeF8C1E1Be7c` | ✅ 主要交互对象 |
| FlapTaxTokenV3 实现（模板） | `0xf6F1Ca2741AC526d74696dDbD8ADba4cc9064329` | ❌ 仅克隆实现，不直接调用 |
| TokenFactory | `0x9AF920a4556419b544cFEb41F71672174827290F` | ❌ 由 Coordinator 调度 |
| PRESALE 模板 | `0xA961A6C6131a4E00267dAc75880364762E886B9A` | ❌ 仅克隆实现（已初始化锁定，owner=0x1） |
| PresaleFactory | `0x23095009C1C912615d3707d5BE9a28f0220d8684` | ❌ 由 Coordinator 调度 |

### 1.3 第三方合约（PancakeSwap V2 测试网）

| 合约 | 地址 |
|---|---|
| Router V2 | `0xD99D1c33F9fC3444f8101754aBC46c52416550D1` |
| Factory V2 | `0x6725F303b657a9451d8BA641348b6761A6CC7a17` |
| WBNB | `0xae13d989daC2F0dEbFf460aC112a837C89BAa7cd` |

### 1.4 平台费用（读链获取，勿硬编码）

- 发币费 `coordinator.creationFee()` — 当前 **0.005 BNB**
- 地址预留费 `coordinator.reservationFee()` — 当前 **0.001 BNB**

两处均为"多退少不补"：`msg.value > 费用` 时超额部分**同交易自动退回**（事件 `ExcessRefunded`）。

### 1.5 ABI 获取

单一信息源，合约更新后自动同步，**勿复制粘贴 ABI 到前端仓库**：

```bash
# 方式一：forge inspect（推荐，按合约名，输出 JSON 含 abi + bytecode）
forge inspect CoordinatorFactory json > coordinator.json
forge inspect PRESALE json > presale.json
forge inspect FlapTaxTokenV3 json > token.json

# 方式二：编译产物（forge build 后生成；注意本仓库产物按「文件名」平铺在 out/ 根下，非嵌套路径）
out/CoordinatorFactory.sol/CoordinatorFactory.json   # 取其中 abi 字段
out/Presale.sol/PRESALE.json                         # 同目录另有 ITokenMigration.json
out/FlapTaxTokenV3.sol/FlapTaxTokenV3.json
```

> 提取纯 ABI（前端可直接 import 的数组）：
> ```bash
> cast abi-json out/Presale.sol/PRESALE.json 2>/dev/null || \
> python3 -c "import json;json.dump(json.load(open('out/Presale.sol/PRESALE.json'))['abi'],open('presale.abi.json','w'),indent=2)"
> ```
>
> ⚠️ `out/` 在 .gitignore 中且会被 `forge clean` 清空——前端构建流程不要依赖仓库内拷贝，应在 CI 里执行 `forge build` / `forge inspect` 动态生成，或由后端发布 ABI 包。

前端主要需要的 ABI：`CoordinatorFactory`（发币/配置入口）、`PRESALE`（每个代币的托管仓实例，地址由 `tokenPresales(token)` 查得）、`FlapTaxTokenV3`（ERC20 + `state()` + `maxSupply()`）、Pancake `IPancakePair`/`IPancakeRouter02`（价格与加池）。

---

## 2. 两条业务流程

> 核心心智模型：**状态迁移全部由合约在"出口动作"内代办**，用户全程不接触状态机。
> `createToken` 后 token 所有权自动在托管仓（`launch`/`claimAllTokens` 的迁移编排前提）；任一出口完成后 token **必然无主（owner = 0x0）**。

### 2.1 流程 A：纯发币（不预售）— 共 2 笔交易

```
① coordinator.createToken(config, salt)      创建者，payable ≥ creationFee
      └→ 链上自动：克隆代币 + 建立/复用 canonical Pair + 部署 TaxProcessor + 建托管仓
         全量代币入托管仓，token 所有权 → 托管仓，托管仓所有权 → 创建者
         （salt 必为搜好的 8888 靓号盐，见 2.4；地址尾号强制 8888）

② presale.claimAllTokens()                   创建者（托管仓 owner）
      └→ 一笔内自动：startMigration → finalizeMigration（税生效）
         → renounceOwnership → 全量代币发放给创建者
         事件：AllTokensClaimed + 两条 PoolStateChanged(0→1, 1→2)
```

**领取完成后的代币 = 普通的已上线 FoT 代币**：
- 分发：直接 `transfer` 转账
- 加池/交易：随时去 PancakeSwap 标准 V2 界面操作（approve + addLiquidityETH），数量与时机完全由用户决定
- 买卖税按发币配置即时生效（见 7.3）

### 2.2 流程 B：预售开盘 — 共 6 笔交易

| # | 调用 | 调用者 | payable | 前置状态 |
|---|---|---|---|---|
| ① | `coordinator.createToken(config, salt)` | 创建者 | `≥ creationFee` | 工厂启用 |
| ② | `coordinator.setupPresale(token, pConfig)` | 创建者 | 可选（创建者购买注资） | 未配置过（一次性） |
| ③ | `presale.openPresale()` | 创建者 | — | `presaleStatus == 0` |
| ④ | `presale.subscribe()` × N | 散户 | 认购 BNB | `presaleStatus == 1` 且 `startTime ≤ now < endTime` |
| ⑤ | `presale.endPresale()` | 创建者（随时）/ 任何人（过 `endTime` 后） | — | `presaleStatus == 1` |
| ⑥ | `presale.launch()` | 创建者 | — | `presaleStatus == 2`、`accumulatedBNB ≥ minLiquidityAmount`（超 72h 后任何人可先 enforce 翻失败封锁开盘，见下） |

`endTime = max(openPresale 时刻, startTime) + duration`：晚开盘不缩水认购窗口。**硬顶恰达自动结算**：某笔认购使 `accumulatedBNB` 恰好等于 `hardcap` 时，该笔交易成交后同笔完成结束判定（1→2，`emit PresaleEnded`）——达硬顶即闭市，无需等 ⑤；超额认购照旧 revert（`HardcapReached`，调小金额重试）。**72h 开盘窗口**：进入状态 2 后 72 小时（`LAUNCH_DEADLINE` 常量）内未 `launch()`，任何人可调 `presale.enforceLaunchDeadline()` 翻转为发行失败（状态 4）开放退款——前端应在进入状态 2 后展示 72h 倒计时。注意 `launch()` 本身不检查 72h：超时但尚无人 enforce 时创建者仍可开盘（与 SmartDeFi 的 opt-in enforce 语义一致），enforce 之后才被状态闸（`presaleStatus != 2`）永久封锁。

`launch()` 一笔内自动：`startMigration → 加池(20% 底池份额 + 全部募资 BNB, LP 死锁 0xdead) → 未售出预售份额销毁(0xdead) → 创建者购买(若注资) → finalizeMigration(税生效) → renounceOwnership`。**无需任何手动移交/迁移操作。** TokenFactory 会复用第三方提前创建的 canonical Pair；若 Pair 在首次 mint 前已被捐入资产并 `sync()`，PRESALE 会绕过 Router 的单边储备报价，直接注入两侧资产并 mint LP，避免除零阻断开盘。

> **未售出代币销毁**：对齐 SmartDeFi Bonding Curve Finalization 语义——加池时未售出的预售份额（`presaleShare - totalSubscribedTokens`）即时销毁（转 `0xdead`），无任何提取入口。前端可用公开视图 `presaleShare - totalSubscribedTokens` 自行计算展示"将销毁数量"。

> **开盘终检（openPresale 冻结条款前的最后一道闸）**：以下注定失败/违约的配置一律拒开——`price = 0`（`InvalidPrice`）、`duration = 0`（`InvalidDuration`）、`maxBuyPerWallet = 0`（`InvalidMaxBuyPerWallet`）、`maxPresaleTokens = 0 或 > presaleShare`（`InvalidMaxPresaleTokens`，超募将导致 claim 缺口）、`softCap < minLiquidityAmount`（`SoftCapTooLow`）、`minLiquidityAmount = 0`（`ZeroMinLiquidity`）、`softCap > hardcap`（hardcap > 0 时，`SoftCapExceedsHardcap`），以及 `creatorShare + poolShare + presaleShare` 不等于实际托管代币余额（`AllocationMismatch`）。平台 `setupPresale` 路径恒满足全部条件；仅创建者直调商业条款 setter 的乱序配置可能触发，被拒后在配置期修正配置重新调用即可（拒开不消耗状态）。份额与模式只能由一次性锁定的 Coordinator 配置，创建者不能直调改写。

开盘后（`presaleStatus == 3`）：

| 动作 | 调用者 | 说明 |
|---|---|---|
| `claim()` | 散户/创建者 | 按 vesting 周期领取（30% 创建者份额 + 50% 认购份额共用本函数） |
| `withdrawRemainingBNB()` | 创建者 | 提取路由器找零等残留 BNB |

### 2.3 分支：预售失败（未达 softCap / 72h 未开盘）

进入 `presaleStatus == 4`（发行失败）的四种入口：

| 入口 | 触发者 | 条件 |
|---|---|---|
| 手动 `endPresale()` | 创建者（随时） | 状态 1 且 `accumulatedBNB < softCap` |
| 到期 force-end `endPresale()` | 任何人 | 状态 1、过 `endTime` 且 `accumulatedBNB < softCap` |
| 72h 超时 `enforceLaunchDeadline()` | 任何人 | 状态 2 超 `LAUNCH_DEADLINE`（72h）未 `launch()` |
| 硬顶自动结算（极端配置） | —（同笔 subscribe） | 恰达 hardcap 且 `accumulatedBNB < softCap`（正常配置 `softCap ≤ hardcap` 下不可达） |

失败后**唯一出口**（重开新一轮）：

| 动作 | 调用者 | 说明 |
|---|---|---|
| `refund()` | 各认购者 | 精确取回本人全部缴款（按 `contributions` 账本，无截留）；**退款即作废本人代币份额**（`subscribedTokens` 清零、`accumulatedBNB` 递减），防止跨轮记账 |
| `refundTo(recipient)` | 各认购者 | 与 `refund()` 使用同一本人账本，但将 BNB 发给非零 `recipient`；拒收 BNB 的合约钱包必须使用此入口指定可接收地址 |
| `relaunchPresale()` | 创建者 | 回配置期（4→0）重开新一轮：须**全员退款完毕**（`accumulatedBNB == 0`）；条款可重设（配置期 setter 复活）或沿用旧条款直接 `openPresale()`（重新锚定 `endTime`）；`presaleRound` +1 供事件分段 |

> **失败局无代币回收出口**（`reclaimTokens` 已移除）：失败局不允许创建者取回代币直接上线，托管代币随仓锁定，唯一出路是全员退清后重开。**已知边界**：若有参与者永不退款，`relaunchPresale` 将永久阻塞（`RefundsOutstanding`）、代币随仓锁死——此时创建者的最终退路是重新 `createToken` 发新币（损失仅为该次部署费用与预留的 8888 地址）；任何人的退款通道永远开放、不受影响。前端在状态 4 下应：① 对参与者突出"请退款"引导；② 对创建者展示未退款金额（`accumulatedBNB`）并将"重开预售"按钮在该值非零时置为不可用态（悬停提示"等待全部认购者退款"）。

> **前端注意**：状态 4 下 `accumulatedBNB` / `totalSubscribedTokens` 随退款递减（退款作废份额的副作用）——历史募资额请以 `PresaleFailed(raisedBNB, softCap)` 事件快照为准；重开进度的软顶对比用"当前 `accumulatedBNB` vs `softCap`"依然是正确口径。状态 4 为纯退款/重开态：翻 FAILED 后**无降额开盘**（launch 通道永久关闭）。

### 2.4 地址规则：全平台尾号 8888（CREATE2 靓号）

> **8888-only 体系**：所有代币地址强制以 `8888` 结尾（低 16 bit == 0x8888）。`salt=0` 随机地址通道已废除——`createToken` 必须传"搜好的 8888 盐"，否则 revert（`InvalidSalt` / `InvalidVanitySuffix`）。预留功能保留，预留的同样是 8888 地址（"预先创建"）。

```
默认流程（免费）：
① 前端本地搜盐 → 找到尾号 8888 的 salt（平均 65536 次尝试，秒级）
② coordinator.createToken{value: ≥creationFee}(config, salt)   —— 未预留的盐人人免费可用

防抢跑（可选，付费 0.001 BNB 不退，随 `reservationFee` 动态读取）：
① 搜盐（同上）
② coordinator.reserveTokenAddress{value: ≥reservationFee}(salt) —— 锁定权属（他人预留的盐会被 NotReserver 拒绝）
③ coordinator.createToken(config, salt)                          —— 本人兑现
```

**前端搜盐指引（红线，务必遵守）**：
- 公式：`keccak256(0xff ‖ tokenFactory地址 ‖ salt ‖ keccak256(EIP-1167 initCode))[12:]`，initCode = `3d602d80600a3d3981f3363d3d373d3d3d363d73` + 实现合约地址（20 字节）+ `5af43d82803e903d91602b57fd5bf3`；或循环调用 `tokenFactory.predictTokenAddress(salt)` 视图
- **盐必须带随机种子派生**（如 `salt = keccak256(randomness, counter)`）：严禁从 0 或固定值递增搜索——否则所有用户趋同撞盐，后到者 `CloneFailed`
- 校验：`uint160(predicted) & 0xFFFF == 0x8888` 命中即停
- 只搜 CREATE2 盐、不涉及任何私钥生成（结构性规避 Profanity 类 vanity 工具的熵缺陷风险）
- 抢跑风险：8888 盐海量（2^256 盐空间）、抢之无利，风险可忽略；在意者走付费预留通道

---

## 3. 参数详解

### 3.1 `TokenConfig`（发币配置，9 字段）

```solidity
struct TokenConfig {
    string  name;                    // 代币名，非空
    string  symbol;                  // 符号，非空
    string  meta;                    // 元数据 URI（IPFS CID 等），可为空串
    uint16  buyTax;                  // 买税 bps，0 ≤ x ≤ 1000（即 0–10%）
    uint16  sellTax;                 // 卖税 bps，0 ≤ x ≤ 1000
    address feeRecipient;            // 唯一税金收款人（税清算 swap 成 BNB 后到账；各类失败兜底接收）
    uint256 taxDuration;             // 税持续时间（秒），开盘/领取时开始计时，到期自动 TaxFree
    uint256 antiFarmerDuration;      // 防夹持续时间（秒），必须 ≤ taxDuration，可为 0
    uint256 liqExpectedOutputAmount; // 清算方向调节参考值（BNB wei）；0 = 关闭该特性，建议前端固定传 0
}
```

注意事项：
- `buyTax`/`sellTax` 超过 1000 bps 直接 revert（`InvalidPrice` 之外的 `TokenFactory` 校验），前端滑杆限制 0–10%
- 代币固定 **18 位小数**、固定总量（读 `token.maxSupply()`，**前端严禁硬编码**；当前部署即 `1e9 ether` = 10 亿枚主网口径，以读链为准——更早的 100 万枚口径代币属于旧部署（判定见 7.8 的 `tokenExists`））
- 代币支持 ERC20Permit（`permit` 签名授权可用）

### 3.2 `PresaleConfig`（预售配置，11 字段，仅 `setupPresale` 一次性生效）

```solidity
struct PresaleConfig {
    uint256 presaleTokenPrice;    // 预售价：每 1 枚代币的 BNB 价格（wei，18 位）。
                                  //   例：1e15 = 0.001 BNB/枚。必须 > 0
    uint256 maxBuyPerWallet;      // 每钱包认购上限（代币 wei）。必须 > 0，否则 subscribe 恒 revert
    uint256 hardcap;              // 募资硬顶（BNB wei），0 = 不限
    uint256 minLiquidityAmount;   // 加池最低 BNB（也是 launch 的 InsufficientBNB 门槛）
    uint256 softCap;              // 认购成功线（BNB wei）：endPresale 时未达 → 发行失败开退款。
                                  //   必须且会被校验 ≥ minLiquidityAmount
    uint256 startTime;            // 认购开始时间戳（秒），0 = 立即
    uint256 duration;             // 认购时长（秒）：1 分钟 ~ 30 天。endTime = max(openPresale 时刻,
                                  //   startTime) + duration，认购窗口为 [startTime, endTime)
    uint256 vestingDelay;         // vesting 周期长度（秒）：testnet 分支 1 分钟 ≤ x ≤ 90 天（主网口径 7 天）
    uint256 vestingRate;          // 每周期释放百分比：5 ≤ x ≤ 20
    uint256 slippage;             // 加池滑点保护 bps，0 ≤ x ≤ 1000（0 = 用默认 5%）
    uint256 creatorBuyTokens;     // 创建者购买目标（代币 wei）；0 = quote 模式（随行就市买入，花费有上限，
                                  //   见 3.3）；上限 = 底池份额 × 5%
}
```

**硬约束速查**（前端表单校验对齐）：

| 字段 | 合法区间 | 违规错误 |
|---|---|---|
| `presaleTokenPrice` | > 0 | `InvalidPrice` |
| `maxBuyPerWallet` | > 0 | `InvalidMaxBuyPerWallet` |
| `minLiquidityAmount` | > 0 | `ZeroMinLiquidity` |
| `softCap` | ≥ `minLiquidityAmount` 且 ≤ `hardcap`（hardcap > 0 时） | `SoftCapTooLow` / `SoftCapExceedsHardcap` |
| `duration` | 1 分钟 ~ 30 天（testnet 分支标定；主网口径须收紧下限） | `InvalidDuration` |
| `vestingDelay` | 1 分钟 ~ 90 天（testnet 分支标定；主网口径 7 天） | `InvalidVestingDelay` |
| `vestingRate` | 5 ~ 20 | `InvalidVestingRate` |
| `slippage` | ≤ 1000 | `SlippageTooHigh` |
| `creatorBuyTokens` > 0 时 | 注资 msg.value > 0 | `CreatorBuyTokensWithoutFunding` |

### 3.2.1 `PresaleRoundConfig`（重开预售批量配置）

失败轮次全员退款完成并调用 `relaunchPresale()` 后，创建者可用一笔
`setPresaleConfig(config)` 原子覆盖新一轮的全部商业参数：

```solidity
struct PresaleRoundConfig {
    uint256 presaleTokenPrice;    // > 0
    uint256 maxPresaleTokens;     // 1 ~ presaleShare；可小于冻结的预售份额
    uint256 maxBuyPerWallet;      // > 0
    uint256 hardcap;              // BNB wei；0 = 不限
    uint256 minLiquidityAmount;   // BNB wei；> 0
    uint256 softCap;              // minLiquidityAmount ≤ softCap ≤ hardcap（hardcap > 0 时）
    uint256 startTime;            // 秒级时间戳；0 = 立即
    uint256 duration;             // testnet：1 分钟 ~ 30 天
    uint256 vestingDelay;         // testnet：1 分钟 ~ 90 天
    uint256 vestingRate;          // 5 ~ 20
    uint256 slippageProtection;   // 实际滑点 bps，0 ~ 1000；500 = 5%
}
```

推荐重开流程：`relaunchPresale` → `setPresaleConfig` → `openPresale`。批量入口只在
`presaleStatus == 0` 时开放，不修改已冻结的创建者/底池/预售份额、模式、Token/Pair/Router
或所有权，也不接受创建者购买注资。任一字段或交叉约束非法时整笔交易回滚，旧配置保持不变。
现有 `setPresaleTerms`、`setSoftCap`、`setVestingConfig`、`setSlippageProtection` 继续保留兼容。

注意：`PresaleConfig.slippage == 0` 在首次 `setupPresale` 中表示沿用默认 5%；而批量入口的
`slippageProtection` 是实际写入值。重开时若希望继续使用 5%，应明确传 `500`，或读取当前
`presale.slippageProtection()` 后原样传入。

**份额由管理员配置（前端动态读取，勿硬编码）**：默认 30% 创建者 / 20% 底池 / 50% 预售，平台管理员可经 `coordinator.setAllocation(creatorBps, poolBps, presaleBps)` 调整（三项均 > 0 且和 == 10000 bps，即时生效）。**比例在 `setupPresale` 时刻写入托管仓实例并冻结**——调整只影响之后创建的新币，已配置代币不受影响。前端在发币表单/详情页读 `coordinator.creatorBps()/poolBps()/presaleBps()` 获取当前比例，认购进度、定价推导（价格 = hardcap/预售份额）、破发线（= hardcap × poolBps/presaleBps）均以动态值为准；不要提供这三个比例的输入框。

### 3.3 `setupPresale` 的 msg.value 语义（创建者购买注资）

- `msg.value == 0`：不注资，`launch` 行为与无购买完全一致
- `msg.value > 0` 且 `creatorBuyTokens == 0`（quote 模式）：launch 时随行就市买入，**花费上限 = 开盘池 BNB 的 1/19**（`MAX_CREATOR_BUY_POOL_BPS = 500`，恒定乘积下恰为买走 5% 池代币的花费）——注资超出上限的部分、以及 swap 失败的全额，都会同交易退回创建者
- `msg.value > 0` 且 `creatorBuyTokens > 0`（token 模式）：精确买入目标数量，实际花费按池价计算，超额同交易退回
- 误注资可撤回：`presale.withdrawCreatorBuy()`（开盘前任意状态可用）

### 3.4 `subscribe` 的到账公式

```
认购代币量（1e18 精度）= msg.value(wei) × 1e18 / presaleTokenPrice
```

例：价 1e15（0.001 BNB/枚），付 1 BNB → 得 1,000 枚。

---

## 4. 状态机与事件

### 4.1 托管仓 `presaleStatus`（PRESALE 实例上读）

| 值 | 含义 | 允许的下一步 |
|---|---|---|
| 0 | 创建/配置期 | `setupPresale`（协调器，仅首轮）/ `setPresaleConfig`（重开批量配置）/ `claimAllTokens` / `openPresale` |
| 1 | 认购中 | `subscribe`（窗口 `[startTime, endTime)`）/ `endPresale`（创建者随时；任何人过 `endTime` 后）——恰达 hardcap 的 `subscribe` 同笔自动结算离开本状态 |
| 2 | 认购结束（达 softCap） | `launch`（72h 内）/ `enforceLaunchDeadline`（超 72h 任何人，翻 FAILED） |
| 3 | 已开盘 | `claim` / `withdrawRemainingBNB`（未售出份额已在 `launch` 时销毁，无提取入口） |
| 4 | 发行失败（未达 softCap 或 72h 未开盘） | `refund` / `refundTo`（散户）/ `relaunchPresale`（创建者，须全员退款完毕，回状态 0 重开新一轮；无代币回收出口） |

**模式判定：纯发币 vs 预售**——读 `presale.presaleEnabled()`（一次性烙印，`setupPresale` 时刻置位后终生不变，份额锁后连 owner 也改不了）：

| `presaleEnabled` | `presaleStatus` | 含义 |
|---|---|---|
| `false` | 0 | 纯发币：`claimAllTokens` 前/后用 `tokensClaimed` 区分 |
| `true` | 0 | 预售：配置期（或失败重开的新一轮，看 `presaleRound`） |
| `true` | 1 / 2 | 预售：认购中 / 待开盘 |
| `true` | 3 | 预售：成功开盘（终态） |
| `true` | 4 | 预售：失败（refund / refundTo / relaunch 窗口） |

注意纯发币领取（`claimAllTokens`）完成后 token **必然无主**（`state ≥ 2`、owner 归零、创建者全量持仓，"领取即上线"）；预售失败局则**永远停在 BondingCurve**（无回收出口，只能重开后经 `launch` 上线）——但 `presaleEnabled` 仍是最稳定的模式判据，勿用代币分布或 `token.owner()` 推断。列表页批量判定：按 `TokenPresalePairCreated` 建 token→presale 映射后批量读 `presaleEnabled`，比事件扫描更简单。

### 4.2 代币 `token.state()`（PoolState，克隆代理上读）

| 值 | 含义 | 税 |
|---|---|---|
| 0 BondingCurve | 初始态，**与池子的转账被禁止** | 无 |
| 1 Migrating | 迁移中（仅存在于编排交易内部） | 无 |
| 2 TaxEnforcedAntiFarmer | 税 + 防夹生效期 | 买卖税 + 防夹 |
| 3 TaxEnforced | 防夹期结束、税继续 | 买卖税 |
| 4 TaxFree | 税到期 | 无 |

正常流程下 0→1→2（→3→4 随时间自动）全部发生在出口交易内，前端只需把 `state ≥ 2` 理解为"已上线"，`state == 0` 理解为"未上线"。**旧版合约创建的代币可能长期停在 0**（见 7.8）。

### 4.3 所有权时间线（新代币）

```
createToken → 出口动作（claimAllTokens / launch）
owner=托管仓              owner=0x0（出口交易内自动 renounce）
```

前端判定"是否已上线/是否可信"建议组合读：`token.state() >= 2 && token.owner() == 0x0`。

### 4.4 关键事件与 topic0（WebSocket 订阅 / 索引）

| 事件 | topic0（keccak） | 用途 |
|---|---|---|
| `TokenPresalePairCreated(address,address,address,uint256)` | `0xd82d53ac9fb3ce23bd37e0b97a838b1dd1a29249c5fc8044b050d2717bfe7ac6` | 新代币上架（coordinator 上监听，全量列表增量维护） |
| `TokenCreated(address,address,address)` | `0xb5a149b73151b44553ff737ca050c61de65038e2ae67ec044215d3261cc6fa00` | TokenFactory 创建代币；第二个 indexed 参数为实际创建者（含智能钱包，不使用 tx.origin） |
| `PresaleCreated(address,address)` | `0xcfea6066a7ff70439f7cfe020aea9709cf4b7cb462225660895dfcc5c38716ae` | PresaleFactory 克隆创建；第二个 indexed 参数为实际代币创建者（非 Coordinator） |
| `AllocationUpdated(uint256,uint256,uint256)` | `0x21c55dfccedf7a8f464081b4c32abf493ebe4c9a653d37fd29365b3775a79cfd` | 分配比例变更（coordinator 上监听，变更后更新本地缓存的比例展示） |
| `PoolStateChanged(uint8,uint8)` | `0x415234d2d8252539e96fb6c66ec4b3a9fd441ef58da0de24639c3e655503ec2d` | 上线信号（token 地址上监听；0→1→2 连续两条 = 出口交易执行） |
| `AllTokensClaimed(address,uint256,uint256)` | `0x9beb1609b7ce6d449a3807626b3c2a8fdfd28db995c202b8ab5ec5c6820b950d` | 纯发币领取完成 |
| `Subscribed(address,uint256,uint256)` | `0xf94991dcbea6e8ac439cbc93bd9c62a4d39f04e0ad656df9a703f13552c2787f` | 认购流水（恰达 hardcap 的同笔交易内会紧跟 `PresaleEnded` 或 `PresaleFailed`） |
| `PresaleEnded()` | `0x1eb1561f8507eb9bc6988331f66f369e75710f2b4b678ad5b4a52454b6636f5f` | 认购达标结束（达 softCap 进状态 2；可由恰达 hardcap 的 subscribe 同笔触发） |
| `PresaleFailed(uint256,uint256)` | `0xd0ded4316a63c0a62ce3e3bcc0c0feac58db8ad9c7a81ee1c347a0ec94bea5cc` | 发行失败信号（`raisedBNB` 为判定时刻快照；此后的退款会递减链上 `accumulatedBNB` 视图） |
| `LaunchDeadlineExceeded(uint256,uint256)` | `0xf2acd1a6dd7963e4ed21f2d5e599e5d25bbed59ad4eadeab5c88d4fb81fdecbb` | 72h 未开盘翻失败（状态 2→4，`enforceLaunchDeadline` 触发） |
| `PresaleRelaunched(uint256)` | `0x7599261cb5ce6b399b18d692fab9bac6b32b0847309d1e2bb09000bbb7e2261f` | 失败重开新一轮（4→0；`round` 计数，两轮同名事件以 `round` 分段去重） |
| `LaunchFinalized(uint256,uint256,uint256)` | `0x263b23d9b2cab56070be836744ca814236a9e4ea7a3843341ec410490c2940c2` | 预售开盘完成 |
| `UnsoldTokensBurned(uint256,uint256)` | `0xced35ff772e9afd2c1a34f79c598da2231e0efa7c39d83b54e45096ac5d23bd1` | 加池时未售出预售份额销毁（`launch` 同笔交易内，紧跟 `LiquidityAdded`） |
| `Refunded(address,uint256)` | `0xd7dee2702d63ad89917b6a4da9981c90c4d24f8c2bdfd64c604ecae57d8d0651` | 失败退款 |
| `RefundedTo(address,address,uint256)` | `0xcf84785db5050a9d990e6ca94985ff958ffcde79393f6437fa3270991ff9d8a6` | 指定地址退款；同时仍发出兼容的 `Refunded` |
| `VestingClaimed(address,uint256,uint256)` | `0x4a94c2c356e29a6583071e731bdacf2ca56565ba5efebcff6936eb7923b51721` | vesting 领取 |
| Pancake `Sync(uint112,uint112)` | `0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1` | 池储备变化 → 实时价格推送 |

---

## 5. 价格方案

### 5.1 预售阶段（`presaleStatus 0/1/2`，池子无流动性）

价格 = 固定认购价，直接读托管仓：

```js
const price = await presale.presaleTokenPrice()   // wei，每枚代币的 BNB 价格
```

无需刷新，配置后不变。

### 5.2 上线后（池子有流动性，`presaleStatus == 3` 或纯发币领取完成）

从 Pancake pair 读储备比值：

```js
const pair = await presale.lpAddress()   // 或 PancakeFactory.getPair(token, WBNB)
const [t0, r0, r1] = await Promise.all([
  pair.token0(), pair.getReserves()      // 返回 [reserve0, reserve1, timestamp]
])
const isToken0 = t0.toLowerCase() === token.toLowerCase()
const tokenReserve = isToken0 ? r0 : r1
const bnbReserve   = isToken0 ? r1 : r0
const priceInBNB = bnbReserve / tokenReserve   // 代币与 WBNB 均 18 位小数，直接相除
```

**实时推送**：WebSocket 订阅 pair 的 `Sync` 事件（topic0 见 4.4），每次交易触发储备变化即推送；备选 3–5 秒轮询 `getReserves()`。

**USD 换算**：`priceInBNB × BNB/USD`。BNB/USD 用同链 `router.getAmountsOut(1e18, [WBNB, USDT])` 或币安公共 API（`/api/v3/ticker/price?symbol=BNBUSDT`）。

### 5.3 展示价 vs 执行价

- 储备比值 = 中间价，用于展示
- "买入 X 枚实际花费" 用 `router.getAmountsOut(...)`（含 0.25% 路由费 + 滑点），两者语义不同
- FoT 提示：买家实收 = 报价输出 × (1 − buyTax/10000)

### 5.4 无流动性的兜底展示

`tokenReserve == 0`（纯发币已领取但用户尚未加池）→ 显示"未开盘/无流动性"，不要展示 0 价格。

### 5.5 市值（Market Cap / FDV）

本平台代币**总量恒定**（无增发、无销毁），MCap = FDV，按行业惯例直接用全量计算：

```
市值(USD) = 价格(USD) × totalSupply
```

| 阶段 | 价格来源 | 说明 |
|---|---|---|
| 预售中 | `presaleTokenPrice()`（固定认购价） | 预售估值的展示口径 |
| 已上线 | pair 储备比（5.2 节） | 随 `Sync` 订阅实时更新 |
| 未开盘/无流动性 | — | 显示"—"，勿显示 0 |

实现要点：

```js
const totalSupply = await token.totalSupply()   // 只读一次并缓存（恒定；勿硬编码，以读链为准）
const priceBNB  = Number(bnbReserve) / Number(tokenReserve)
const mcapUSD   = priceBNB * bnbUsd * Number(totalSupply) / 1e18
```

- **BNB/USD**：测试网用币安公共 API（`/api/v3/ticker/price?symbol=BNBUSDT`，测试网 BNB 无真实价，按惯例用主网价展示）；主网可切链上 `router.getAmountsOut(1e18, [WBNB, USDT])` 免外部依赖
- 市值更新与价格共用同一 `Sync` 订阅，无额外请求
- 若产品要做更严的"流通盘"口径（剔除托管仓/创建者持仓）需自建账本——对 meme 发射平台不建议，固定总量代币 MCap=FDV 是扫描器与竞品的通行展示

### 5.6 买卖交易（dapp 内置 Swap 面板）

代币是标准 PancakeSwap V2 `token/WBNB` 交易对上的 ERC20，dapp 买卖 = 直接调路由合约，**无需任何平台合约中转**。

**前置闸门（交易入口显隐判断）**：

```js
const [state, reserves] = await Promise.all([
  client.readContract({ address: token, abi: tokenAbi, functionName: "state" }),
  client.readContract({ address: pair, abi: pairAbi, functionName: "getReserves" }),
]);
const tradable = state >= 2 && (reserves[0] > 0n && reserves[1] > 0n); // 已上线 且 池子双侧有储备
```

`state == 0`（BondingCurve）下对池转账被代币合约硬性拒绝（"Transfers to/from pools are restricted"），买卖入口必须隐藏而非仅置灰——此时交易必然失败。

**买入（支付 BNB → 得代币）**：`swapExactETHForTokensSupportingFeeOnTransferTokens`，一笔交易：

```js
// 报价（不含买入税）：getAmountsOut 为纯储备数学
const quoted = await client.readContract({
  address: ROUTER, abi: routerAbi, functionName: "getAmountsOut",
  args: [bnbIn, [WBNB, token]],
});
// 实收 = 报价 × (1 − buyTax/10000)；amountOutMin 再留滑点余量
const buyTax = await client.readContract({ address: token, abi: tokenAbi, functionName: "buyTaxRate" });
const minOut = quoted[1] * (10000n - buyTax) / 10000n * (10000n - slippageBps) / 10000n;

await wallet.writeContract({
  address: ROUTER, abi: routerAbi, account,
  functionName: "swapExactETHForTokensSupportingFeeOnTransferTokens",
  args: [minOut, [WBNB, token], account, BigInt(Math.floor(Date.now() / 1000)) + 600],
  value: bnbIn,
});
```

**卖出（支付代币 → 得 BNB）**：approve + swap 两笔。**必须用 Supporting 变体**——卖税在"卖方 → 池"的转账中被扣走，池子实际到账少于名义数量，标准 swap 变体的 K 值校验必然 revert：

```js
// ① 授权（建议按实际卖出量授权，或用户确认后无限授权）
await wallet.writeContract({
  address: token, abi: tokenAbi, account,
  functionName: "approve", args: [ROUTER, sellAmount],
});

// ② 卖出
const [quoted, sellTax] = await Promise.all([
  client.readContract({ address: ROUTER, abi: routerAbi, functionName: "getAmountsOut",
    args: [sellAmount, [token, WBNB]] }),
  client.readContract({ address: token, abi: tokenAbi, functionName: "sellTaxRate" }),
]);
const minOut = quoted[1] * (10000n - sellTax) / 10000n * (10000n - slippageBps) / 10000n;

await wallet.writeContract({
  address: ROUTER, abi: routerAbi, account,
  functionName: "swapExactTokensForETHSupportingFeeOnTransferTokens",
  args: [sellAmount, minOut, [token, WBNB], account, BigInt(Math.floor(Date.now() / 1000)) + 600],
});
```

买入侧两个 swap 变体技术上均可用（买入税在"池 → 买方"输出端扣，池子流出量足额），统一用 Supporting 变体最省心。

**税率是动态的，随时间归零**：`taxDuration`（发币配置）到期后代币自动进入 TaxFree（税率归零），前端每次报价都实时读 `buyTaxRate()/sellTaxRate()`，勿缓存——税过期后公式自然算出全额，无需特判。

**体验与 gas 注意**：
- 卖向主池的转账会触发税仓清算检查：累计税款达到清算阈值（`liquidationThreshold()`，动态调整）时，该笔卖出同交易附带"税代币 swap 成 BNB → feeRecipient"——gas 明显上浮、且清算本身向同池卖出带来轻微额外价格影响。偶发、预期内，钱包端 gas 估算需容忍
- 报价页的扣税展示口径见 7.3 节（买入实收/卖出到池），此处不重复
- anti-farmer 防夹窗口内买卖税率与常规一致（防的是夹子机器人的换汇路径，不额外惩罚普通买卖）

---

## 6. 错误对照表

> 全部为 custom error（无参数），revert data 前 4 字节即 selector。
> 前端捕获 `error.data`，截取前 10 字符匹配下表映射友好文案。

### 6.1 CoordinatorFactory（发币入口）

| selector | 错误 | 触发场景 | 建议文案 |
|---|---|---|---|
| `0x432acbfd` | FactoryDisabled | 平台暂停服务 | 平台维护中，暂不可发币 |
| `0x535b7470` | InsufficientCreationFee | msg.value < creationFee | 发币费不足 |
| `0xe2592aed` | EmptyTokenName | name 为空 | 请填写代币名 |
| `0x19c7070a` | EmptyTokenSymbol | symbol 为空 | 请填写符号 |
| `0x259ba1ad` | TokenNotRegistered | setupPresale 的 token 非本平台创建 | 代币不存在 |
| `0x57deb26a` | NotTokenCreator | 非创建者调 setupPresale | 仅创建者可操作 |
| `0x11b61b6a` | AlreadyConfigured | 重复 setupPresale | 预售条款一次性配置，不可修改 |
| `0x1a16b58e` | InvalidMaxBuyPerWallet | maxBuyPerWallet = 0 | 单钱包上限必须大于 0 |
| `0xff3bfcc7` | ZeroMinLiquidity | setupPresale 传 minLiquidityAmount = 0 | 加池下限必须大于 0 |
| `0xc6614516` | CreatorBuyTokensWithoutFunding | creatorBuyTokens>0 但未注资 | 请附购买注资 |
| `0x81e69d9b` | InvalidSalt | reserveTokenAddress salt=0；**createToken salt=0（随机通道已废除）** | 盐值非法 |
| `0x01511986` | InvalidVanitySuffix | 预言地址尾号非 8888（createToken / reserveTokenAddress 双路径） | 盐对应地址尾号不是 8888 |
| `0x3f5aba5f` | InsufficientReservationFee | 预留费不足 | 预留费不足 |
| `0x5e72c18e` | AddressAlreadyReserved | 地址已被预留 | 该地址已被他人锁定 |
| `0xd64bf586` | AddressAlreadyDeployed | 预言地址已有代码 | 地址已被占用 |
| `0x106874c5` | NotReserver | 兑现他人预留的盐 | 该靓号已被他人预留 |
| `0x0baf7432` | InvalidAllocation | setAllocation 比例含 0 项或三项之和 ≠ 10000 bps | 分配比例配置非法 |

### 6.2 PRESALE（托管仓）

| selector | 错误 | 触发场景 | 建议文案 |
|---|---|---|---|
| `0xe87ff4be` | PresaleDisabled | 纯发币模式下调了预售函数 | 该代币未开启预售 |
| `0xee64016a` | PresaleEnabled | 预售模式下调用 `claimAllTokens` | 已开启预售，不能领取全部托管代币 |
| `0x00bfc921` | InvalidPrice | 预售价为 0（setPresaleTerms / setPresaleConfig / openPresale 终检） | 价格非法 |
| `0x755f0ed3` | InvalidVestingDelay | vestingDelay 超出 1 分钟 ~ 90 天（testnet 分支标定） | 领取周期须在 1 分钟 ~ 90 天之间 |
| `0x416c61ed` | InvalidVestingRate | vestingRate 超出 5 ~ 20 | 每期释放比例须在 5%~20% |
| `0xf525e320` | InvalidStatus | 状态不对（各类状态守卫兜底） | 当前状态不可执行该操作 |
| `0x7963e2b5` | PresaleNotOpen | 认购未开放 | 预售未开放 |
| `0x4e16195c` | PresaleNotStarted | 早于 startTime | 预售尚未开始 |
| `0x312c6e32` | PresaleExpired | 过 endTime 后 subscribe | 预售已到期 |
| `0x3deb266e` | PresaleNotExpired | 非 owner 在到期前调 endPresale | 预售尚未到期，仅创建者可提前结束 |
| `0x76166401` | InvalidDuration | duration 超出 1 分钟 ~ 30 天（testnet 分支标定）；openPresale 遇 duration = 0 | 认购时长须在 1 分钟 ~ 30 天之间 |
| `0x742e3c2b` | LaunchDeadlineNotReached | 状态 2 未满 72h 就调 enforceLaunchDeadline | 尚在开盘窗口期内 |
| `0x0d3e2916` | RefundsOutstanding | 退款未清零就调 relaunchPresale | 须等待全部认购者退款完毕 |
| `0x174a9bcf` | EscrowDrained | 纵深防御（**当前不可达**）：relaunchPresale 前置的仓非空检查——回收出口移除后 FAILED 态托管仓恒非空，正常调用永不触发 | 理论防御位，见到即异常配置 |
| `0x7a1cb75d` | SharesLocked | 首次配置后再次调 configureLaunch（含 relaunch 后的配置期） | 份额一次性写入：分配比例全生命周期仅管理员经 setupPresale 配置，创建者不可改 |
| `0x7c946ed7` | ZeroValue | subscribe 附 0 BNB | 请输入金额 |
| `0xc2f5625a` | AmountTooSmall | 换算代币数为 0 | 金额过小 |
| `0xd4556c36` | PresaleSoldOut | 超出预售份额（maxPresaleTokens） | 已售罄 |
| `0x746f4607` | WalletLimitExceeded | 超单钱包上限 | 超出单钱包限购 |
| `0x5be90159` | HardcapReached | 超募资硬顶 | 已达硬顶 |
| `0xbf64110f` | InsufficientBNB | launch 时募资 < minLiquidity | 流动性门槛未达 |
| `0xe4b16145` | SoftCapTooLow | softCap < minLiquidity | 软顶须不小于加池下限 |
| `0xc0e1152e` | SoftCapExceedsHardcap | softCap > hardcap（hardcap > 0 时；setSoftCap / setPresaleConfig / openPresale 终检） | 软顶不可超过硬顶 |
| `0x5668bc6c` | InvalidMaxPresaleTokens | setPresaleConfig/openPresale 遇 maxPresaleTokens = 0 或 > presaleShare | 认购上限须为 1 ~ 预售份额 |
| `0x1a16b58e` | InvalidMaxBuyPerWallet | setPresaleTerms/setPresaleConfig/openPresale 遇 maxBuyPerWallet = 0 | 单钱包上限必须大于 0 |
| `0xff3bfcc7` | ZeroMinLiquidity | setPresaleTerms/setPresaleConfig/openPresale 遇 minLiquidityAmount = 0 | 加池下限必须大于 0 |
| `0x535f6940` | ZeroAllocationShare | 创建者/底池/预售任一份额为 0 | 分配比例非法 |
| `0x6d501ff8` | AllocationMismatch | 三类份额之和不等于托管仓实际代币余额 | 托管资产与应付份额不守恒 |
| `0x4211fd84` | NotConfigurator | 非锁定的 Coordinator 调用份额或模式配置 | 无配置权限 |
| `0x4111be05` | NotOwnerOrConfigurator | 非创建者且非 Coordinator 调用商业配置/注资 | 无操作权限 |
| `0x1dc882d9` | InvalidConfigurator | configurator 为零地址 | 配置方地址非法 |
| `0x58dcc471` | ConfiguratorAlreadySet | 重复设置 configurator | 配置方已锁定 |
| `0x19d08ad9` | InvalidRefundRecipient | refundTo 收款人为零地址 | 退款地址非法 |
| `0xda3d3821` | PairAlreadyInitialized | launch 前 Pair 已存在 LP 供应量 | 交易对状态异常，请联系平台 |
| `0xa4f81929` | TokensAlreadyClaimed | 重复领取/领取后再开预售 | 已领取，不可重复 |
| `0x969bf728` | NothingToClaim | 可领额度为 0（未到周期/已领完） | 暂无可领取份额 |
| `0x0f3f8610` | NoTokensToClaim | `claimAllTokens` 时托管仓余额为 0；`withdrawCreatorBuy` 时无注资 | 无代币/注资可领 |
| `0x8dda39df` | NotLaunched | 未开盘就 claim | 尚未开盘 |
| `0xa153fa9e` | NoShare | 无任何份额 | 无可领份额 |
| `0xd7ce20a0` | MigrationStateMismatch | 迁移前置状态异常（防御性，正常流程不可达） | 状态异常，请联系平台 |
| `0x452a0e78` | CreatorBuyTooLarge | 创建者购买超上限 | 超出购买上限 |
| `0x655df0b2` | ZeroCreatorBuyValue | 注资 0 | 注资额必须大于 0 |
| `0xbf72d580` | CreatorBuyLocked | 开盘后操作注资 | 开盘后不可操作注资 |
| `0x7e4625d6` | NoBNBToWithdraw | 无残留 BNB | 无可提取余额 |
| `0xa2e5181c` | NotAfterLaunch | 开盘前调 withdraw 类函数 | 尚未开盘 |

OZ 标准错误：`Ownable: caller is not the owner`（string revert，非 4 字节）→ "仅所有者可操作"。

---

## 7. 注意事项与坑位清单

### 7.1 旧流程遗留认知清除（重要）

- **`launch` 前不需要再调 `token.transferOwnership(presale)`** —— 所有权在 createToken 时已自动交托管仓。旧版用户手册/代码若有此步骤，全部删除
- **纯发币领取后不需要任何"状态迁移"操作** —— `claimAllTokens` 已内嵌。前端文案不要再出现"手动迁移/解锁"引导
- 判定代币是否上线：`token.state() >= 2`；判定可信终态：再加 `token.owner() == 0x0`

### 7.2 费用与退款

- `createToken` / `reserveTokenAddress` 均为"多退少不补"：**传多了同交易退回**，前端无需精确凑数，但建议发送前读 `creationFee()` 预填
- 预留费**不退款、不过期**，确认文案要讲清楚

### 7.3 税的可见影响（FoT 代币特性）

- 买入：买家实收 = 池子输出 × (1 − buyTax/10000)。报价页要标注"含 X% 买入税"
- 卖出/向池转账：到池 97%（卖税 3% 时），税款进代币税仓，攒到清算阈值后自动 swap 成 BNB 转入 `feeRecipient`
- 加池：用户自行在 Pancake 加池时，入池代币按卖向计税（到池 = 95%/97%/…按卖税率）——这是 FoT 固有行为，属预期内

### 7.4 LP 信任差异（买家侧风险展示，必做）

| 路径 | LP 归属 | 前端展示建议 |
|---|---|---|
| 预售 `launch` | **死锁 0xdead，永不可撤池** | 徽标："LP 已锁死 ✅" |
| 纯发币用户自行加池 | **创建者钱包自持，可随时撤池** | 徽标："LP 未锁定 ⚠️ 存在撤池风险" |

判定方式：预售开盘代币直接标 ✅；纯发币代币读 `presale.liquidityAdded()`（false = 用户自加池）。

### 7.5 时间相关参数用秒

`taxDuration` / `antiFarmerDuration` / `vestingDelay` / `startTime` / `duration` 全部为**秒级时间戳/时长**，前端用 `ethers.toUtf8`/`BigInt` 传整秒，勿传毫秒。`duration` 是**时长**（非绝对时间戳）：`endTime` 在 `openPresale()` 那笔交易内由合约锚定，前端无法也无需预填。

### 7.6 金额单位

全链统一 **wei（18 位）**：BNB 与代币同精度。价格、份额、上限均以 1e18 计。展示层再做 `/1e18` 格式化。

### 7.7 gas 预算参考（实测 @0.1 gwei，BSC 测试网常见价位）

| 操作 | gas | ≈BNB @0.1gwei |
|---|---|---|
| createToken | ~4,430,000 | 0.00044 |
| claimAllTokens | ~124,000 | 0.000012 |
| setupPresale | ~170,000 | 0.000017 |
| subscribe | ~70,000（普通）/ ~130,000（含硬顶自动结算） | 0.000007 |
| endPresale | ~28,000 | 0.000003 |
| enforceLaunchDeadline | ~26,000 | 0.0000026 |
| relaunchPresale | ~24,000（不含重设条款） | 0.0000024 |
| launch | ~500,000 | 0.00005 |

钱包至少留 0.01 BNB 余量；gas 价波动时前端读 `ethers.getFeeData()` 估算。

### 7.8 新旧代币区分（存量兼容）

- 列表页以 `coordinator.getAllTokenPresalePairs(0, N)` 为准（只含本协调器注册的代币）
- **存量代币判定（唯一判据）**：`coordinator.tokenExists(token) == false` 即旧代币。此类代币可能长期停留在 `state == 0`、`owner != 0`——没有"领取即上线"能力，用户领币后**无法自行加池**（路由层报 `TransferHelper: TRANSFER_FROM_FAILED`，内层原因是 `Transfers to/from pools are restricted in BondingCurve state`，**与滑点无关**，勿用滑点引导用户）
- 存量代币如需展示，维护静态 allowlist 并对其单独做状态判定（`state < 2` 显示"未上线"）

存量代币救援（创建者用 token owner 钱包执行两笔即可恢复加池能力）：`startMigration()` → `finalizeMigration()`（顺序勿反；可选第三笔 `renounceOwnership()` 对齐新终态）。

### 7.9 其他细节

- `setupPresale` 是**一次性**的：条款配置后不可修改（`AlreadyConfigured`），前端提交前给确认弹窗。PresaleFactory 在移交 owner 前一次性锁定 Coordinator；只有它能执行 `configureLaunch` / `setCustodyMode`，创建者无法抢先写份额或切换模式。**重开新一轮**（`relaunchPresale`）不经过 coordinator：创建者优先调用 `setPresaleConfig` 一笔原子重设价格/限额/窗口/vesting/滑点；旧商业 setter 仍可兼容使用，也可沿用旧条款直接 `openPresale()`。创建者买入注资继续由 `fundCreatorBuy` 独立处理。分配份额与模式终生不变，`openPresale` 还会复核三类份额之和等于实际托管余额。
- `subscribe` 的硬顶/限购/售罄在**同笔交易内原子校验**，无需前端预检（但预读做按钮置灰体验更好）；恰达硬顶的那笔交易会**同笔结束预售**（事件序列 `Subscribed` → `PresaleEnded`），前端订阅 `PresaleEnded` 即可刷新状态，无需轮询
- vesting 领取公式：`已释放 = min(份额 × vestingRate × 已过周期数 / 100, 份额)`——**累计释放封顶 100% 份额**（如 10%×11 周期只按 100% 计，不会到 110%），实际可领 = 已释放 − 已领；周期 = `(now - vestingStart) / vestingDelay`；开盘后下一个周期边界前可领为 0（正常，显示"下期释放时间"用 `getUserVestingStatus` 的 `nextVestingTime`）
- `claim` / `refund` / `refundTo` 对散户**免 owner 校验**（各领各的；`refundTo` 仅能处置调用者自己的退款账本）；`claimAllTokens` / `launch` / `relaunchPresale` 仅创建者；`endPresale` / `enforceLaunchDeadline` 为受控公开（见 2.2/2.3 触发权表）
- 代币克隆实例地址即 ERC20 合约地址，`name/symbol/decimals/balanceOf/permit` 全套标准接口可用

---

## 8. 视图函数清单

### 8.1 CoordinatorFactory（入口，只读）

| 函数 | 返回 | 用途 |
|---|---|---|
| `tokenPresales(token)` | address | 代币 → 托管仓地址 |
| `presaleTokens(presale)` | address | 反查 |
| `tokenCreators(token)` | address | 代币 → 创建者 |
| `tokenConfigured(token)` | bool | 是否已配预售 |
| `tokenPairDetails(token)` | `(token, presale, creator, createdAt, name, symbol, totalSupply)` | 详情页一次拉齐 |
| `getTokenPresalePairsByCreator(creator, offset, limit)` | 结构体数组 | "我的代币"分页 |
| `getAllTokenPresalePairs(offset, limit)` | 结构体数组 | 全量列表分页 |
| `getCreatorTokenCount(creator)` / `getTotalTokenCount()` | uint256 | 分页总数 |
| `tokenExists(token)` | bool | 合法性校验 |
| `creationFee()` / `reservationFee()` | uint256 | 费用预填 |
| `creatorBps()` / `poolBps()` / `presaleBps()` | uint256 | 当前分配比例（bps，发币表单与详情页动态读取，勿硬编码 30/20/50） |
| `factoryEnabled()` | bool | 平台开关 |
| `tokenAddressReserver(predicted)` | address | 靓号预留权属查询 |
| `tokenFactory.predictTokenAddress(salt)` | address | CREATE2 预言地址（纯视图，链下搜盐） |

### 8.2 PRESALE（托管仓实例）

| 函数 | 用途 |
|---|---|
| `getLaunchStatus()` | `(enabled, status, bnbAccumulated, tokensSubscribed, lpAdded, tokensClaimed)` 一次拉齐 |
| `presaleEnabled()` / `presaleStatus()` | **模式判定**（纯发币 vs 预售，见 4.1 判定表）+ 生命周期状态 |
| `getContractBalances()` | `(tokenBalance, bnbBalance)` |
| `getVestedAmount(user)` | 当前可领 vesting 数量 |
| `getUserVestingStatus(user)` | `(share, claimable, claimed, nextVestingTime)` |
| `presaleTokenPrice()` / `softCap()` / `hardcap()` / `maxBuyPerWallet()` / `startTime()` | 条款展示 |
| `presaleDuration()` / `endTime()` | 认购窗口（倒计时：`endTime - now`；进度百分比建议以 `min(now, endTime) - startTime` 计算） |
| `endedAt()` / `LAUNCH_DEADLINE()` | 状态 2 的 72h 开盘窗口倒计时（`endedAt + LAUNCH_DEADLINE - now`） |
| `presaleRound()` | 当前轮次（0 = 首轮；重开 +1，跨轮事件分段去重锚点） |
| `accumulatedBNB()` / `totalSubscribedTokens()` | 进度条（配合 softCap/maxPresaleTokens）；**状态 4 下随退款递减**（历史快照看 `PresaleFailed` 事件） |
| `creatorShare()` / `poolShare()` / `presaleShare()` | 本托管仓实例的冻结份额展示（setupPresale 时刻锁定，不随工厂比例调整变化） |
| `vestingDelay()` / `vestingRate()` / `vestingStart()` | vesting 说明 |
| `subscribedTokens(user)` / `contributions(user)` / `claimedTokens(user)` | 个人持仓页 |
| `lpAddress()` | pair 地址（价格查询用） |
| `liquidityAdded()` | LP 状态（7.4 风险徽标） |
| `creatorBuyBnb()` / `creatorBuyTokens()` | 创建者购买注资状态 |

### 8.3 代币（克隆实例）

| 函数 | 用途 |
|---|---|
| `state()` | 上线判定（见 4.2） |
| `owner()` | 终态判定（0x0 = 已放弃） |
| `maxSupply()` / `totalSupply()` | 总量（**读链，勿硬编码**） |
| `poolState()` | 打包读取（state/buyTax/sellTax/threshold/…），详情页一次拉 |
| 标准 ERC20 + `permit()` | 转账/授权/签名授权 |

---

## 9. viem 快速上手

```ts
import { createPublicClient, createWalletClient, custom, http, webSocket, parseAbi, formatUnits } from "viem";
import { bscTestnet } from "viem/chains";

const RPC  = "https://bsc-testnet-rpc.publicnode.com";
const WSRPC = "wss://bsc-testnet-rpc.publicnode.com";
const COORDINATOR = "0x4d2B161095f6B2A88832eae8FA07aeF8C1E1Be7c";

const client   = createPublicClient({ chain: bscTestnet, transport: http(RPC) });
const wsClient = createPublicClient({ chain: bscTestnet, transport: webSocket(WSRPC) });
const wallet   = createWalletClient({ chain: bscTestnet, transport: custom(window.ethereum) });

// ---------- ABI（parseAbi 人类可读形式，按需声明用到的条目即可） ----------
const coordinatorAbi = parseAbi([
  "function createToken((string name, string symbol, string meta, uint16 buyTax, uint16 sellTax, address feeRecipient, uint256 taxDuration, uint256 antiFarmerDuration, uint256 liqExpectedOutputAmount) tokenConfig, bytes32 salt) payable returns (address token, address presale)",
  "function creationFee() view returns (uint256)",
  "function tokenPresales(address) view returns (address)",
  "event TokenPresalePairCreated(address indexed token, address indexed presale, address indexed creator, uint256 totalSupply)",
  // 声明了 error，viem 会自动解码 revert
  "error InsufficientCreationFee()", "error FactoryDisabled()",
]);
const presaleAbi = parseAbi([
  "function claimAllTokens()", "function subscribe() payable",
  "function setPresaleConfig((uint256 presaleTokenPrice, uint256 maxPresaleTokens, uint256 maxBuyPerWallet, uint256 hardcap, uint256 minLiquidityAmount, uint256 softCap, uint256 startTime, uint256 duration, uint256 vestingDelay, uint256 vestingRate, uint256 slippageProtection) config)",
  "function lpAddress() view returns (address)",
  "function presaleTokenPrice() view returns (uint256)",
  "function presaleEnabled() view returns (bool)",
  "function presaleStatus() view returns (uint256)",
  "function getLaunchStatus() view returns (bool, uint256, uint256, uint256, bool, bool)",
  "error PresaleNotOpen()", "error WalletLimitExceeded()",
]);
const pairAbi = parseAbi([
  "function token0() view returns (address)",
  "function getReserves() view returns (uint112, uint112, uint32)",
  "event Sync(uint112 reserve0, uint112 reserve1)",
]);
const tokenAbi = parseAbi(["function totalSupply() view returns (uint256)"]);

// ---------- ① 发币（纯发币模式） ----------
// 8888-only 体系：salt 必须是"搜好的尾号 8888 盐"（零盐/非 8888 盐直接 revert，
// 见 2.4）。最小可行搜盐示例（生产建议 Web Worker 内跑并带随机种子派生）：
const TOKEN_FACTORY = "0x9AF920a4556419b544cFEb41F71672174827290F";
const IMPL = "0xf6F1Ca2741AC526d74696dDbD8ADba4cc9064329"; // tokenFactory.flapImplementation()
const INIT_CODE = "0x3d602d80600a3d3981f3363d3d373d3d3d363d73"
  + IMPL.toLowerCase().slice(2) + "5af43d82803e903d91602b57fd5bf3";
function predict(salt: bigint) {                       // EIP-1014 / EIP-1167
  return keccak256(concat(["0xff", TOKEN_FACTORY, pad(toHex(salt, 32)), keccak256(INIT_CODE)]));
}
function searchSalt(seed: bigint) {                    // 平均 65536 次，秒级
  for (let i = 0n; ; i++) {
    const salt = keccak256(concat([toHex(seed, 32), toHex(i, 32)]));  // 随机种子派生，严禁从 0 递增
    if (predict(salt).endsWith("8888")) return salt;
  }
}
const salt = searchSalt(Date.now());  // 一次性搜好，可先 reserveTokenAddress 锁定（见 2.4）

const fee = await client.readContract({ address: COORDINATOR, abi: coordinatorAbi, functionName: "creationFee" });
const hash = await wallet.writeContract({
  address: COORDINATOR, abi: coordinatorAbi, functionName: "createToken", account,
  args: [{
    name: "MyToken", symbol: "MTK", meta: "ipfs://Qm...",
    buyTax: 200, sellTax: 300, feeRecipient: account,
    taxDuration: 365n * 86400n, antiFarmerDuration: 86400n, liqExpectedOutputAmount: 0n,
  }, salt],
  value: fee,   // 多退少不补
});
const rc = await client.waitForTransactionReceipt({ hash });
const created = rc.logs.find(l => l.topic0 === "0xd82d53ac9fb3ce23bd37e0b97a838b1dd1a29249c5fc8044b050d2717bfe7ac6");
// 解码 created.args 拿 token / presale 地址

// ---------- ② 一键领取（领取即上线） ----------
const presaleAddr = await client.readContract({ address: COORDINATOR, abi: coordinatorAbi, functionName: "tokenPresales", args: [tokenAddr] });
await wallet.writeContract({ address: presaleAddr, abi: presaleAbi, functionName: "claimAllTokens", account });
// 之后 token.state() == 2、owner == 0x0，用户自行去 Pancake 加池/交易

// ---------- ③ 预售认购（散户） ----------
await wallet.writeContract({ address: presaleAddr, abi: presaleAbi, functionName: "subscribe", account, value: parseEther("1") });

// ---------- ④ 价格 + 市值（Sync 实时推送，见 5.2/5.5） ----------
async function pricing(tokenAddr: `0x${string}`) {
  const pair = await client.readContract({ address: presaleAddr, abi: presaleAbi, functionName: "lpAddress" });
  const [t0, [r0, r1]] = await Promise.all([
    client.readContract({ address: pair, abi: pairAbi, functionName: "token0" }),
    client.readContract({ address: pair, abi: pairAbi, functionName: "getReserves" }),
  ]);
  const isT0 = t0.toLowerCase() === tokenAddr.toLowerCase();
  const tokenReserve = isT0 ? r0 : r1, bnbReserve = isT0 ? r1 : r0;
  const totalSupply = await client.readContract({ address: tokenAddr, abi: tokenAbi, functionName: "totalSupply" }); // 读一次缓存
  return calc({ tokenReserve, bnbReserve, totalSupply });   // 见 5.5 公式
}
const unwatch = wsClient.watchContractEvent({
  address: pair, abi: pairAbi, eventName: "Sync",
  onLogs: ([{ args }]) => calc({ tokenReserve: ..., bnbReserve: ..., totalSupply: cached }),
});

// ---------- ⑤ 错误处理 ----------
// viem：abi 里声明了 error 即自动解码
try { ... } catch (e) {
  const name = e?.name;   // e.g. "ContractFunctionExecutionError"，e.errorName === "PresaleNotOpen"
  toast(ERROR_MAP[e?.errorName] ?? "交易失败，请稍后重试");   // ERROR_MAP 见第 6 章
}
```

---

## 附录 A：部署核验记录（当前部署）

**部署交易**：`forge script script/Deploy.s.sol --rpc-url bsc-testnet --broadcast --verify --private-key <deployer>`（broadcast 产物 `broadcast/Deploy.s.sol/97/run-latest.json`），部署者 `0x463c...21D3`，7 笔交易全部上链成功（5 笔 CREATE + 2 笔角色授权），BscScan 源码验证 5/5 `Pass - Verified`：

| 合约 | 部署交易 | 地址 | BscScan 验证 |
|---|---|---|---|
| FlapTaxTokenV3 impl | `0xd6e59705feb802dd8bcb96e2381e67984422f79f6ed5c523f6107be0ed61ec77` | `0xf6F1Ca2741AC526d74696dDbD8ADba4cc9064329` | ✅ Pass |
| TokenFactory | `0xffe95b0a55b5abf441e0cb72c2875ff4009726f2805bb17a64287ee91b95c3bc` | `0x9AF920a4556419b544cFEb41F71672174827290F` | ✅ Pass |
| PRESALE template | `0x151626fa8a3dfed5fae17d37ae2bbb871ec3bb85dd5077dd6939d3d74e94dca6` | `0xA961A6C6131a4E00267dAc75880364762E886B9A` | ✅ Pass |
| PresaleFactory | `0xb33ba181f9a4fb2d28f5c70012afbedb5bf530d98c4eae8ef6c82b9b056df5bb` | `0x23095009C1C912615d3707d5BE9a28f0220d8684` | ✅ Pass |
| CoordinatorFactory | `0x3116eceffa3f9f3e710d3d941ddbff69df1c357329097b860ea66d1ca44a50d0` | `0x4d2B161095f6B2A88832eae8FA07aeF8C1E1Be7c` | ✅ Pass |
| TokenFactory 授权 | `0x527234ded669d704cf46860863df837f489c5726e54618cd3805ff26270fdc9e` | — | — |
| PresaleFactory 授权 | `0x8fd16f799e8530e28b512c651a61a4df5266c534a2bb76314bb133cc98705a88` | — | — |

**接线核验（全通过）**：
- 5 合约源码验证 5/5 `Pass - Verified`（Etherscan V2 API，chain 97）
- 两工厂 `hasRole(COORDINATOR_ROLE, coordinator) == true`
- `tokenFactory.flapImplementation == 0xf6F1...6329`、`presaleFactory.presaleImplementation == 0xA961...6B9A`
- **PRESALE 模板初始化锁生效：模板 owner == 0x1（占位初始化，任何人无法再 initialize 实现合约）**
- `coordinator.routerAddress == 0xD99D...50D1`、`creationFee == 0.005 BNB`、**`reservationFee == 0.001 BNB`（新费率已上链）**、`factoryEnabled == true`

**冒烟测试（当前部署全场景端到端，全部通过）**——角色：创建者（张三 `0x027D...B421`）、散户（李四 `0xf999...f25Be`）、路人（部署者钱包 `0x463c...21D3`，非 owner 非参与者）。所有测试币地址尾号 8888（CREATE2 靓号体系验证）：

| # | 场景 | 关键交易 | 验证点（全部符合预期） |
|---|---|---|---|
| 1 | **完整成功链路**（SMK1b `0xa030...18888`，软顶 0.02；第一轮零认购失败→relaunch 重设条款走通） | createToken `0xd841...4357` → setup → open → 零认购 end 判 FAILED → relaunch（round 1）→ **重设条款 setPresaleTerms/setSoftCap 成功（配置期复活）** → open → subscribe 0.02 `0x3a94...`（恰达软顶）→ end → launch | 状态 0→1→2→3 全通；relaunch 前置（退款清零）与配置期复活实证；**代币对账守恒：10 亿 = dead 未售销毁 499,980,000 + 池 200,000,000 + 托管 vesting 300,020,000（creator 3 亿 + 李四 2000 万）**；pair 储备 2 亿 + 0.02 BNB（募资全额入池）；token state=2、owner=0x0；retail share=2000 万枚、claimable=0（周期未到）、nextVestingTime=+7d |
| 2 | **硬顶恰达同笔自动结算**（SMK2 `0x12D4...18888`，硬顶 0.06） | subscribe 0.03（状态保持 1）→ 恰达 0.03（**同笔翻 2、endedAt 记录**）→ 结算后 subscribe 拒 `PresaleNotOpen(0x7963e2b5)` → launch | 0.03 时状态保持 1；恰达即闭市；结算后封认购；launch 后池储备 2 亿枚 + 0.06 BNB（全额入池） |
| 3 | **force-end 触发权三段 + 72h 门禁**（SMK3 `0xC1A9...8888`，窗口 120s，软顶 0.01 恰达） | subscribe 0.01 → **路人提前 endPresale revert `PresaleNotExpired(0x3deb266e)`** → 到期后路人 endPresale 成功进 2 → **立即 enforceLaunchDeadline revert `LaunchDeadlineNotReached(0x742e3c2b)`** → launch | 触发权三段验证：路人提前拒、路人到期可；72h 内 enforce 拒（状态保持 2）；launch 正常进 3（超 72h 但未 enforce 不阻塞开盘，opt-in 语义） |
| 4 | **失败单出口（reclaimTokens 已移除）**（SMK1 `0x514d...58888`，软顶 0.15 未达，认购 0.10） | 到期路人 force-end 判 FAILED → **reclaimTokens 调用整笔回滚（函数不存在）** → relaunch 拒 `RefundsOutstanding(0x0d3e2916)` → retail refund 全额 0.10 → relaunch 成功（round 1） | **单出口语义实证**：无代币回收通道，10 亿代币原样锁仓（token state 保持 0 BondingCurve）；未退款阻塞重开；退款精确全额（净额=缴款-gas）；退清后重开回配置期 |
| 5 | **预留费 0.001 + 多退少不补**（预留地址 `0x1193...88888`） | reserveTokenAddress 付 0.001（实扣 0.001+gas）→ 再预留付 0.005（实扣仍 0.001+gas） | **新费率 0.001 BNB 链上生效**；8888 预测地址精确落位；权属登记 deployer；多付 0.004 同交易自动退回 |

**已知残留边界**（与单测/fuzz 覆盖一致）：72h 后 enforce 翻 FAILED 的正路径由 forge 单测覆盖（真实链等待 72h 不具操作性）；场景 4 的 relaunch 二轮认购-上线全链路由场景 1 的 relaunch 路径覆盖。
