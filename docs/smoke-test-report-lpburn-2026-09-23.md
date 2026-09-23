# BSC 测试网 LpBurn 模式自动回购冒烟测试

> 网络：BSC Testnet，chainId 97
> Coordinator：`0x266f95143B983E0aF7368d82eB60354713eCC47B`
> 当前状态：PASS（BSC 测试网，2026-09-23）。本报告验证 BuybackMode.LpBurn（买本币加 LP 死锁）路径的测试网端到端执行；与 2026-09-23 TokenBurn 冒烟互补，覆盖此前未上链的 LP 回购路径。不代表 BSC 主网已验收。

## 与 TokenBurn 冒烟的关系

《smoke-test-report-2026-09-23.md》覆盖了 TokenBurn 模式；其结论中明确"LP 买回模式（BuybackMode.LpBurn）未由本次 TokenBurn 配置的测试代币覆盖"。本冒烟使用同一 Coordinator、同一 keeper（`0x9f87b1973361b23387D7F1b536484543a5ea1eFB`）、同一验收脚本（`script/KeeperAcceptance.s.sol`，`ACCEPTANCE_BUYBACK_MODE=1`），仅金库模式不同。

## 验收资产与配置

| 对象 | 地址 |
|---|---|
| Token (KLP) | `0xe1cB3215a81dFcCC41dDde78721d7D95573c8888` |
| Presale（托管仓） | `0x26573c543f76087A0C56aDC40A844fE529B6e1df` |
| Vault（LpBurn） | `0x5B926036582c7BE17da78E9ec49C77Ed5a926a31` |
| Pair | `0xBaaD0BF176Cc5eA13dA650B0951f7282eC213205` |
| TaxProcessor | `0x2c5e0Ca66B2a3Bd9357E9E9BDa8dbc6a01776EA5` |
| Dividend | `0x7E3E6e18d985BAeCF848624B668180212d159873` |

- 代币配置：买税 500 bps / 卖税 1000 bps；四通道 market 4000 / deflation 1000 / lp 2000 / dividend 3000；分红最小持币 10,000 枚；antiFarmerDuration = 0。
- 金库配置（链上已核验）：`mode = 1 (LpBurn)`、`trigger = 0 (Time)`、`firstExecuteAt = 创建 + 600s`、`intervalSeconds = 60`、`buybackAmount 上限 = 0.001 BNB`；vault 的 `token`/`pair` 与上表一致，Coordinator `tokenVaults` 登记一致。
- 底池：300,000,000 KLP + 0.05 tBNB；随后同批两笔各 100,000,000 枚应税卖出。

## 建链交易

| 步骤 | 交易哈希 | 结果 |
|---|---|---|
| 带金库发币（`createTokenWithVault`，金库 Initialized(mode=1, trigger=0)，区块 132639561） | `0xae34f85a09c955796a9c592dd10ae50668b52651e319e40b583eeabc7bcaa2a7` | `0x1` |
| 领取即上线 / 授权 / 0.05 tBNB 加池 / 两笔卖出（同一广播后续 6 笔） | 由用户终端广播发出，回执均 `0x1`；终态已链上核验（广播产物目录未落回工作区，哈希未逐一收录） | `0x1` |

广播前已通过 dry-run 完整模拟（7 笔、约 696 万 gas）；实际部署者成本 = 0.005 创建费 + 0.05 底池 + gas。

## Keeper 自动执行结果

建池卖出后约 8 分钟 keeper 开始分批清算税收，约 30 分钟时触发首次 LpBurn 回购。税收清算交易（含费通道尘埃与市场通道两笔 `RevenueReceived` 配对入账）：

| 类型 | 交易哈希 | 区块 |
|---|---|---|
| Tax | `0xabbd56255258fe89949a3de2bd5986cf46a2effdd228d9d52bf9120f328e6226` | 132640573 |
| Tax | `0x205fe55a2552ae4d3945092b10730d31b5bc3d948f0f5fae5773df82ebd871bc` | 132640816 |
| Tax | `0x9213bf6fd8ad09ed96aa8c4c69e0e30b21255c42ad361c8d99c44d0f0b7d976c` | 132640949 |
| Tax | `0x1c2a24cb211c5797e0a6ffb92aed28895a7d72414f3123b92cf2eb4b69a0f2dc` | 132642815 |
| Tax | `0xfd255113f8fbd804e4422644d7e60d5aa0744e8b1d8ebdc6149d55d84144aa30` | 132642948 |
| Tax | `0x551a7a0774ee7bfcc0af1e7cfc6f72fc48bf8a1061f02ce2840d02228b1d270d` | 132643232 |
| **LpBurn Buyback** | **`0x6cea44434a2f4852f7d33fad6db2b9bb6b9887b9f7878d6602b0e9188b37bb4e`** | **132643616** |
| Tax | `0xde9030f3e02c3840bacc2c7578c9aedae142996c82996bd6e897649ddcb383fd` | 132643749 |

全部回执 `0x1`。

### LpBurn 回购事件（`LpBuybackExecuted`，区块 132643616，gas 427,688）

| 字段 | 数值 |
|---|---:|
| caller（keeper） | `0x9f87b1973361b23387D7F1b536484543a5ea1eFB` |
| bnbSpent | 178,588,008,269,973 wei（0.000178588 BNB） |
| tokensAdded（买得并加入 Pair 的 KLP，已含 5% 买税实收） | 1,258,605.02 KLP |
| lpBurned（铸造并死锁 0xdead 的 LP） | 10,178,281,602,187,681,019 |

- 该笔 `bnbSpent` 与金库 `totalBuybackBNB` **逐 wei 相等**；`lpBurned` 与金库 `totalLpBurned` **逐 wei 相等**。
- 同一金库事件窗口内**没有** `BuybackFallbackToToken`、**没有** `TokenBuybackExecuted`，`totalBurnedToken = 0`：LP 路径一次成功，未回退。
- 执行额受 1% 储备上限约束（池 WBNB ≈ 0.03，1% ≈ 0.0003 BNB；实际花 0.0001786 BNB，低于配置上限 0.001 BNB），LP 路径未用预算按设计留在金库。

## 链上会计快照（区块 132644115）

| 指标 | 数值 |
|---|---:|
| 金库累计入金（RevenueReceived 合计 = TaxProcessor totalQuoteSentToReceiver） | 224,947,575,963,990 wei |
| 其中：市场通道（totalQuoteSentToMarketing） | 224,947,575,963,982 wei |
| 其中：费通道整数尘埃（8 笔 1/1/2/2/2 wei，费接收人与市场接收人同为金库） | 8 wei |
| 回购花费（totalBuybackBNB） | 178,588,008,269,973 wei |
| 回购后金库余额 | 46,359,567,694,017 wei |
| 入金 − 花费 − 余额 | **0 wei（分毫不差）** |
| buybackCount / totalBurnedToken | 1 / 0（LpBurn 不直接销代币，符合预期） |
| 金库 readiness | InsufficientBalance（余额低于 0.0001 BNB 下限，继续积累） |
| Pair 0xdead LP 持仓 | 17,107,152,505,909,311,468 |
| 其中金库 LpBurn 贡献 | 10,178,281,602,187,681,019 |
| 其中税收 LP 通道贡献 | 6,928,870,457,216,430,449 |
| Token 0xdead 持仓 = totalTaxTokenBurned | 951,705.50 KLP（仅 deflation 通道直接销毁） |
| TaxProcessor 税收加池累计 | 856,534.95 KLP + 56,089,658,090,496 wei WBNB |
| TaxProcessor 分红入账累计 | 168,710,681,972,984 wei WBNB |
| lpTokenBalance / pendingDividendQuote / 待清算税 | 0 / 0 / 40,482,944.96 KLP |
| LP WBNB 零头待用（lpQuoteBalance） | 147,235,900,497 wei |
| Pair 储备 | 457,495,366.94 KLP / 0.0298118 WBNB |

## 最终验收结论

- LpBurn 模式测试网端到端验收通过：税收清算 → 四通道分配 → 金库积累 → 动态金额报价 → **买币 + 配比加池 + LP 死锁 0xdead**，一次成功无回退。
- 金库会计闭合：累计入金 = 已花 + 余额，0 wei 误差；LP 死锁持仓 = 金库 LpBurn + 税收 LP 通道之和，逐 wei 对得上。
- 与 TokenBurn 的差异行为均符合设计：`totalBurnedToken = 0`（销的是 LP 而非代币）、未用预算留库继续积累、keeper 对 LP 半仓单独报价（`minLpTokenOut`）并被链上满足。
- keeper 全程无人值守，价格锚点/最低输出/模拟-签名-广播链路未产生拒绝或告警。
- 遗留观察项：金库余款 0.0000464 BNB 低于执行下限，将随后续税收继续积累后触发下一次 LpBurn 回购；主网上线前仍建议补一轮 LpBurn 路径的失败回退（强制 `minLpTokenOut` 不可满足 → `BuybackFallbackToToken`）实网演练，该项此前仅在 BSC fork 验证过。
