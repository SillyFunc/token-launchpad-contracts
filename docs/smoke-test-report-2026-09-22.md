# BSC 测试网四通道税收与 Keeper 冒烟测试报告

> 网络：BNB Smart Chain Testnet（chainId `97`）  
> 执行时间：2026-09-22 05:43:10–08:58:11 UTC / 13:43:10–16:58:11 UTC+8  
> 最终结论：**FAIL——禁止据此开放四通道发币入口**
> 后续状态：仓库源码已实现动态安全执行额并通过本地与 BSC 测试网 fork；本报告对应的旧 Vault Clone 不可升级，失败事实和上线结论保持不变，直至新部署完成真链复验。

## 1. 结论摘要

税费归集、直接销毁、市场通道入金、分红入账、待加池记账与自动加池均已在 BSC 测试网真链成功执行，Keeper 的价格保护、权限限制、失败跳过与后续恢复也符合预期。

自动回购未通过验收。最终快照中：

- 最终复核时 BuybackVault 实际余额为 `0.001064414572104008 BNB`，已经高于配置的单次回购额 `0.001 BNB`；
- Pair 的 WBNB 储备仅为 `0.028163569580058530 WBNB`；
- Vault 限制单次回购不得超过 WBNB 储备的 `1%`，当前允许上限仅为 `0.000281635695800585 BNB`；
- 配置的 `0.001 BNB` 约占当前储备的 `3.55%`，因此 `_reserveLimitOk()` 返回 `false`，`canExecuteBuyback()` 为 `false`；
- 链上 `buybackCount = 0`，D1 中无 `buyback` 任务或交易。

回购并非因余额不足、时间未到、Keeper 未运行或价格保护暂时跳过。以当前参数，只有外部市场把 Pair 的 WBNB 储备提高到至少 `0.1 WBNB` 才能解锁；Vault 没有下调 `buybackAmount`、退款或救援入口，协议无法保证恢复。因此这批 BNB 处于依赖外部市场条件的不可控锁定状态，属于当前上线阻塞项。

## 2. 验收资产

| 资产 | 地址 |
|---|---|
| Token | `0x226761d49e8a8bD80DdeAcd4d0b23A604aB88888` |
| Presale | `0xDdB043519635d7d0F1372CCEaB41F6a48d1B2305` |
| TaxProcessor | `0xFECbb527CD97fC7d7003b7830Ed1e65195030710` |
| Dividend | `0x2892ee297E26fe8bDe625F23534bf5cA28fb4e90` |
| BuybackVault | `0xb151060cE075F9988984ff7F7eC28725D4baa413` |
| Pancake V2 Pair | `0x5FBb17e5b9F4B7f99D001b1b1C0A265762D8D1fB` |

地址来自 `script/deployments/97-keeper-acceptance.json`。六个地址均存在链上代码；Coordinator 保存的 Presale、TaxProcessor、Dividend 和 Vault 与上表一致。

## 3. 预检结果

- `forge test`：全部通过。
- `pnpm --dir keeper check`：通过。
- `pnpm --dir keeper test`：9 个测试文件、45 个测试全部通过。
- 当前部署广播：15 笔交易、15 个成功回执。
- 当前部署的 10 个合约地址均存在链上代码，工厂、Router 与 Coordinator 权限连线一致。
- Worker `/health`：正常。
- Keeper `0x9f87b1973361b23387D7F1b536484543a5ea1eFB` 拥有 `KEEPER_ROLE`，不拥有 `DEFAULT_ADMIN_ROLE`。
- Keeper 测试开始前余额约为 `0.0987967 tBNB`。
- `TAX_DURATION = 3153600000`（100 年），`MAX_ANTI_FARMER_DURATION = 31536000`。

未读取 Cloudflare Secret；管理令牌不是本次链上资金流验收的必要条件。

## 4. 创建与触发交易

| 操作 | 交易哈希 | 区块 | 状态 |
|---|---|---:|---|
| 创建 Token/Presale/四通道基础设施/Vault | `0x980d1aebe813980d54ed39596dc3a7927a205a8d556875e6a93ea0d0c1cf18b3` | 132464150 | `0x1` |
| 纯发币领取 | `0x54bf64b1eea0060bab65160941a6f6174eed67dc7ddf3377e78c5ad6002971c1` | 132464162 | `0x1` |
| Token 授权 Router | `0x561fcc67f71750d405ffec6478d1b694492a041fd43af2231ecd570a27ebd9ac` | 132464169 | `0x1` |
| 添加 `0.05 tBNB + 300,000,000 Token` 流动性 | `0x65e0e1936421aab5f3d7ed4329b27dd4bad6fd0b9b89ceb8dcd2ab09f3e504f4` | 132464178 | `0x1` |
| 卖出授权 | `0x97c27a14ff4f711a2c188c6dda3c762e8e3df0c609d3cdd29d112cb439845bac` | 132464182 | `0x1` |
| 第 1 笔应税卖出 | `0xc6ff7f17e902ff8c87bd325a6cf07d26d1ba2b225be2065044d887b29d6538dd` | 132464186 | `0x1` |
| 第 2 笔应税卖出 | `0x2bfad7bd95b27cde054f28e7ed0665245bbcc76a16bcbcd08d02ae21b8f6287a` | 132464255 | `0x1` |

创建广播共 7 笔、7 个成功回执。两笔卖出完成后：

- Pair 储备：`450,000,000 Token / 0.030027018311076307 WBNB`；
- TaxProcessor `pendingTaxTokens`：`40,000,000 Token`；
- Token 合约税仓余额：`10,000,000 Token`；
- 卖出交易没有内联调用 TaxProcessor，符合异步清算设计。

## 5. 参数核对

- 买税：500 bps；卖税：1000 bps。
- 税收结束时间：`4943655795`，相对创建时间约 100 年。
- 动态清算阈值：`10,000,000 Token`。
- 四通道：市场 4000、直接销毁 1000、LP 2000、分红 3000 bps，总和 10000。
- Vault：TokenBurn 模式、Time 触发、间隔 60 秒、单次回购 `0.001 BNB`、首次允许执行时间 `1790056289`。
- `antiFarmerDuration = 0`，因此最后一笔创建批次交易确认时状态已经惰性切换为 `TaxEnforced`（3），而不是旧验收文档预期的 `TaxEnforcedAntiFarmer`（2）。永久税状态正确，旧文档的静态状态断言应修正。

## 6. Keeper 真链执行证据

### 6.1 代表性成功交易

| 类型 | 交易哈希 | Keeper nonce | 区块 | 回执 |
|---|---|---:|---:|---|
| 首笔 tax | `0x31b6259e6a96845d5eb0cb4d373282cff1b553dd8b9c68760f37224828f64874` | 48 | 132465486 | `0x1` |
| 首笔 liquidity | `0x6571a9c7e54990032da6580835f9ece9ae034f31d7360fff79bf42248d773bda` | 51 | 132465902 | `0x1` |
| 后期 tax | `0xf19c22205bd8764fcad90cd1816806b79e282585ea076f628188a5e27e79d0c5` | 96 | 132487924 | `0x1` |
| 后期 liquidity | `0x2360fa5c324896cb369e0890b5470fd78c45181170068fe9898ea6bcc130dcef` | 97 | 132488155 | `0x1` |
| 最后 tax | `0x231964d4f6879b6d3aba1631a5a1fea4f70006890e1f431eadca5c38048af2d7` | 98 | 132488434 | `0x1` |
| 最后 liquidity | `0x769cb63d2da7960b87384964faed34c30e34ee0343936b85228e9d6ec7dbed2d` | 99 | 132488594 | `0x1` |

首笔 `TaxProcessed`：

- `amountIn = 1,350,000 Token`；
- 实际获得 `64,589,408,736,196 wei WBNB`；
- 直接销毁 `135,000 Token`；
- 为 LP 保留 `135,000 Token`；
- calldata 中 `minQuoteOut = 63,911,547,695,849 wei`、`deadline = 1790056690`，均为有效非零边界。

首笔 `addPendingLiquidity` calldata：

- `tokenAmount = 405,875.429856 Token`；
- `minQuoteAmount = 23,820,638,070,151 wei`；
- `maxQuoteAmount = 24,301,863,081,671 wei`；
- `minLiquidity = 2,933,686,098,073,588,464`；
- `deadline = 1790056877`。

两条路径都使用了有限 deadline 和链上价格边界。

### 6.2 最终四通道会计快照

快照区块约为 `132488495`，时间为 2026-09-22 08:45:45 UTC。

| 指标 | 最终值 |
|---|---:|
| Pair Token 储备 | 487,518,023.748498759150603847 Token |
| Pair WBNB 储备 | 0.028216679140861835 WBNB |
| TaxProcessor `pendingTaxTokens` | 3,681,452.162347210925180476 Token |
| 累计直接销毁 Token | 4,631,854.783765278907481940 Token |
| `0xdead` Token 余额 | 4,631,854.783765278907481940 Token |
| 累计市场通道 WBNB | 0.001034066926471505 WBNB |
| Vault 实际 BNB 余额 | 0.001034066926471558 BNB |
| 累计分红 WBNB | 0.000775550194853630 WBNB |
| Dividend 实际 WBNB 余额 | 0.000775550194853630 WBNB |
| 累计用于自动加池的 Token | 4,037,358.524175005752754560 Token |
| 累计用于自动加池的 WBNB | 0.000250194647446286 WBNB |
| `0xdead` LP 余额 | 32.763707894878898797 LP |
| TaxProcessor LP Token 待处理余额 | 0 |
| TaxProcessor LP WBNB 尾差 | 0.000000722048889284 WBNB |
| 市场通道待发送 WBNB | 0 |
| 分红通道待发送 WBNB | 0 |
| Keeper 最终余额 | 0.096720846560395976 tBNB |

累计直接销毁量与 `0xdead` Token 余额完全一致；累计分红量与 Dividend 的 WBNB 余额完全一致；市场通道累计值与 Vault BNB 余额仅相差 53 wei；待加池 Token 已全部处理，LP 全部铸给 `0xdead`。四通道的最终收款人与会计闭环均得到真链验证。

`pendingTaxTokens` 因 TaxProcessor 向 Pair 转账时再次触发卖税而可能回流，并非严格单调下降。验收同时核对了 Token 实际余额、通道累计值和最终收款方，而没有把单个 pending 数值误作完整会计结果。

### 6.3 D1 与价格保护

截至 2026-09-22 08:58:11 UTC 的最终复核，D1 对本 Token 记录：

- `tax submitted`：34 条；
- `liquidity submitted`：20 条；
- `tax skipped`：103 条，原因均为模拟阶段的 `PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT`，没有广播、没有消耗 nonce；
- `liquidity busy`：14 条，与同一轮 tax 任务并发互斥一致；
- `buyback`：0 条；
- 价格样本：135 条，覆盖区块 `132464150–132488590`；
- 最近 5 次运行均为 `complete`、`error = null`；
- 未解决告警：0。

清算过程中曾触发连续跳过告警，但在锚点价格更新、下一笔 tax 成功后均自动填写 `resolved_at`。这证明价格保护会拒绝不满足最低输出的交易，且在条件恢复后继续执行，没有形成 nonce 冲突或重复广播。

## 7. 权限负向验证

从非 Keeper 地址对三条执行路径进行只读模拟：

- `processPendingTax`：以 `UnauthorizedTaxKeeper()`（`0xe53e8015`）回退；
- `addPendingLiquidity`：以 `UnauthorizedTaxKeeper()`（`0xe53e8015`）回退；
- `executeBuyback`：以 `UnauthorizedKeeper()`（`0x77b14347`）回退。

同一区块读取合法 Keeper 的 `KEEPER_ROLE` 为 `true`。未发现公开调用绕过 Keeper 权限的路径。

## 8. 自动回购失败分析

最终链上复核区块为 `132490043`。

| 检查项 | 结果 |
|---|---:|
| Vault BNB 余额 | 0.001064414572104008 BNB |
| 配置的单次回购额 | 0.001 BNB |
| 时间条件 | 已满足 |
| Pair WBNB 储备 | 0.028163569580058530 WBNB |
| `MAX_BUYBACK_RESERVE_BPS` | 100（1%） |
| 当前安全上限 | 0.000281635695800585 BNB |
| 配置额占储备比例 | 约 355 bps（3.55%） |
| `canExecuteBuyback()` | `false` |
| `buybackCount` | 0 |
| `totalBuybackBNB` | 0 |
| `totalBurnedToken` | 0 |
| D1 buyback 记录 | 0 |

根因是创建参数允许 `0.001 BNB` 的固定回购额与 `0.05 BNB` 的初始底池组合，但 Vault 执行时又强制固定回购额不得超过当前 WBNB 储备的 `1%`。初始配置在经济上要求储备至少达到 `0.1 WBNB`，与验收底池及卖出后的实际储备不兼容。

该失败路径不会广播失败交易，所以 Worker 和 Cron 仍显示健康；仅依赖 `/health`、运行状态或未解决告警无法发现这类永久不满足计划条件的资产。

## 9. 风险与修复建议

严重度：**高，上线阻塞**。市场税已经持续进入 Vault，但协议无法确定性消费或退回，资金生命周期不闭环。

修复应选择一种明确语义，并增加低流动性真链/状态化回归测试：

1. 在创建或激活池时校验 `buybackAmount <= 当前 WBNB 储备 × 1%`，不兼容时拒绝上线；同时前端按 LP 参数限制可选回购额。
2. 把 `buybackAmount` 定义为上限，实际执行 `min(配置额, Vault 余额, 储备安全上限)`；需额外定义最小执行额、尘埃、事件与 UI 展示语义。
3. 增加只能向下调整的回购额治理入口，并配置严格权限、冷却期和事件；这能救援既有 Vault，但引入管理员信任边界。

无论选择哪种方案，都应新增以下回归：`0.05 BNB` 初始底池、`0.001 BNB` 回购配置、金库余额达到阈值后必须能执行或在创建阶段被明确拒绝。还应为 D1 增加“余额已满足但 `canExecuteBuyback` 长期为 false”的可观测告警。

## 10. 最终判定

**FAIL。**

- 四通道税收分配与异步清算：通过；
- 自动加池与 LP 销毁：通过；
- Keeper 权限、价格保护、跳过与恢复：通过；
- 自动回购与 Token 销毁：失败；
- 资金生命周期闭环：失败。

在修复回购参数兼容性并重新完成同等级真链冒烟测试前，不应向 DApp 用户开放四通道创建功能。本次测试资产保留在 BSC 测试网作为失败证据，未执行清理、资金搬移或人为补流动性来掩盖失败。
