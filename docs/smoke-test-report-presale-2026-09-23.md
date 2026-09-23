# BSC 测试网预售模式端到端冒烟 + 托管仓分红泄漏复现

> 网络：BSC Testnet，chainId 97
> Coordinator：`0x266f95143B983E0aF7368d82eB60354713eCC47B`
> 状态：**PASS（功能）+ 问题复现确认（分红泄漏）**（2026-09-23）。本报告验证预售模式全生命周期（发币→认购→开盘→税收四通道→金库回购），并按预定方案复现了"托管仓未被排除在分红之外导致 vesting 期分红漏给创建者"的设计问题。不代表 BSC 主网已验收。

## 验收资产与配置

| 对象 | 地址 |
|---|---|
| Token (PAT) | `0x4862FB35af64Ec746EEc67429e0F36edd7108888` |
| Presale（托管仓） | `0xbab0F4bdCA8EE0614eB457dBc6721CE7FD3649cc` |
| Vault（TokenBurn） | `0x53B88c35649a4ce6e49060a5e9d96714DAd8f2A7` |
| Pair | `0x294b15f17Eb1c016DdE080707C7d21F75bbADB3b` |
| TaxProcessor | `0xD8D0448e70eF1435a70eeF682080597C71cf483B` |
| Dividend | `0x5123c7626127c104258c39aD6A89E59C3F0Dc8bd` |

- 代币：买税 500 / 卖税 1000 bps；四通道 market 4000 / deflation 1000 / lp 2000 / **dividend 3000**；minimumShareBalance = 10,000 枚。
- 金库：TokenBurn、Time 触发、间隔 60s、单次上限 0.001 BNB。
- 预售：1 gwei/枚；softCap = minLiquidity = 0.05 BNB，hardcap 0.08 BNB；vesting 30min/期 × 20%；创建者购买注资 0.0035 BNB（token 模式顶格 1,000 万枚）。
- 执行脚本：`script/PresaleAcceptance.s.sol`（本次新增）。

## 执行时间线与交易

| 步骤 | 交易哈希 | 结果 |
|---|---|---|
| createTokenWithVault | `0x890d9c874122604d5038d3cb6ef83bc94d906690f2c16cea7520254e82d26c43` | `0x1` |
| setupPresale（含创建者购买注资） | `0x55544f7330941a12ffadc70ba56cc85bd0f0ce2ab332db659bdbb3a19cbc7796` | `0x1` |
| openPresale | `0x4d9ccc680225d1ecdf88a7c1c65dac28b9201da52c77bc2a605800f1526b6d41` | `0x1` |
| 散户 A/B 各认购 0.03 tBNB（合计 0.06，6,000 万枚） | 用户钱包直发，链上 `Subscribed` 事件可证 | `0x1` |
| endPresale（提前达标结算） | `0x872ece619a2a664258598ed03b1699559a9e5ee4795be2b754a9010dfd11fe6a` | `0x1` |
| **launch**（迁移+0.06 BNB/2 亿枚加池+LP 死锁+未售 4.4 亿枚销毁+创建者购买 1,000 万枚） | `0xf94c4ddd9e4e667e25abeb27c9a9c8d6d5a089dde616d4a01dbbbb8f13f0d512` | `0x1` |
| approve | `0x0ee0368bfbaf12c5bc3ef97079388416f11b957d6e088cd89493991d17e96777` | `0x1` |
| ~~首轮卖出~~（OOG，见运维发现 1） | `0x711879332c9da8b37cf0cefca6c3c889b17d1cadb4127cc82b6b3c9b1a1205d3` | `0x0` 回滚 |
| 补卖 1,000 万枚 | `0x15f84f4250a6b25544b5315c99183450ecf495e4db5a61704811d2efdcba0ff8` | `0x1` |
| 归属 40% 领取（1.2 亿枚） | `0xdc8f57f8dff99cb7a8885a749acaf389b669b818799482cdb3a2411e4f160d6c` | `0x1` |
| 卖出 1.1 亿枚 | `0x4cbd3015de42a0011a9a3b708facddfdacc0a17cf6ecf2c805c134a955bbbc66` | `0x1` |
| 归集卖出 500 万枚（触发税仓归集 1,200 万枚） | `0xc289dad29b31d33efa0c1e57278ec0af10a010dd4edd84e0593dcffb518ca976` | `0x1` |
| **proveLeak ①：withdrawDividendsFor(presale)** | `0xb6bd270021c5c3704b863916094effd785e78a49d1929abcad3a1b9b113981fe` | `0x1` |
| **proveLeak ②：withdrawRemainingBNB（创建者扫走）** | `0xb73cd2ef9d646b8188eaff2084ba8d5144f81e0623d3f94cf4a995a7ef60b8c6` | `0x1` |

Keeper 在其后自动执行了全部税收清算批（每批 ≤ 池储备 0.3%）与 2 笔金库回购，均回执 `0x1`。

## 核心发现：托管仓分红泄漏（已复现）

**机制**：Dividend 排除名单只含 pair 与 TaxProcessor，托管仓（PRESALE）未被排除。开盘后托管仓持有创建者未领份额 + 散户 vesting 中份额（本案例 2.4 亿枚），按份额吃走分红；散户在分红账本中不存在。泄漏额唯一出口是创建者的 `withdrawRemainingBNB()`。

**证据 A（proveLeak 前，17:22 快照）**：

| 指标 | 数值 | 占比 |
|---|---:|---:|
| Dividend 累计入账（`totalDividendTokenSent`） | 127,825,302,804,627 wei | 100% |
| 托管仓可领（`withdrawableDividends(presale)`） | 125,216,623,155,552 wei | **97.96%** |
| 创建者可领（其流通持仓 500 万枚） | 2,608,679,649,074 wei | 2.04% |
| 散户可领 | 0 | 0%（`totalShares` 2.45 亿 = 托管仓 2.4 亿 + 创建者 0.05 亿，会计恒等） |

**证据 B（闭环）**：proveLeak 两笔交易执行后，`withdrawnDividends(presale) = 218,731,944,111,071 wei ≈ 0.0002187 BNB` 经托管仓转入创建者钱包；托管仓原生 BNB 余额归零。**泄漏持续发生**：快照时托管仓可领又已回升至 62,326,969,548,121 wei（托管仓仍持有 2.4 亿枚份额）。

**影响边界**：仅 `dividendBps > 0` 的预售模式代币；纯发币模式不受影响（claimAllTokens 在任何成交前清空托管仓）；已 claim 持仓的分红不受影响。

**修复建议**（已与需求方确认方向）：`_createTokenBody` 中将 `createPresale` 提前到 `createInfrastructure` 之前，创建时把 presale 地址加入 Dividend 排除名单；排除后无合格持币人时 `deposit()` 返回 false，TaxProcessor 已有 deferred 兜底。

## 税收四通道与金库（预售模式）验收

快照（区块时间 ~17:42，keeper 清算进行中）：

| 指标 | 数值 |
|---|---:|
| 市场通道累计入金库（`totalQuoteSentToReceiver`） | 297,718,479,484,528 wei（含 12 wei 费通道尘埃） |
| 金库回购次数 / 花费 | 2 / 297,718,479,484,528 wei（**入金=花费，逐 wei 相等**） |
| 金库回购销毁（`totalBurnedToken`） | 2,183,592.10 枚 |
| 金库当前余额 / readiness | 42,462,634,864,500 wei / InsufficientBalance（继续积累） |
| deflation 累计销毁 | 821,991.49 枚 |
| LP 通道加池累计 | 574,712.34 枚 + 74,143,713,323,143 wei WBNB |
| 分红通道累计入账 | 223,288,859,613,386 wei |
| 待清算税 | 3,780,085.10 枚（keeper 持续清算中） |
| Token `0xdead` 持仓 | 443,005,583.59 枚 = 未售 440,000,000 + deflation 821,991.49 + 金库 2,183,592.10（**逐 wei 闭合**） |
| Pair `0xdead` LP 持仓 | 3,470,627,096,261,113,583,656（开盘 LP 3.464e21 + 税收 LP 通道） |

预售模式金库结论：**launch 保证主池开盘即有死锁流动性，金库自开盘起即可工作，不存在纯发币的"主池无水"窗口**；认购期（BondingCurve）零税收、金库零收入，符合设计。

## 运维发现

1. **开盘后首笔应税卖出的 gas 低估风险**：首笔卖出附带 anti-farmer 期满的一次性状态迁移（TaxEnforcedAntiFarmer→TaxEnforced）与分红份额冷写，实测需要 ~261,816 gas，forge 默认 130% 估算余量给出 242,773 导致 OOG 回滚（tx `0x71187933…`）。前端/keeper 按当前状态实时估算即可覆盖；验收脚本已统一加 `--gas-estimate-multiplier 200`。
2. **清算触发延迟是设计行为**：税累计突破阈值后，归集发生在下一笔指向主池的转账（本案例用一笔 500 万枚卖出显式触发），不是同一笔。
3. **开盘前 keeper 出现 `InvalidPoolReserves` 等待属预期**：Pair 在发币时创建、launch 才注入流动性；launch 后 readiness 自动恢复。
4. 测试网公共 RPC 当日下午多次 TLS 抖动，广播曾一次未发出（模拟成功但发送失败），换备用端点即成；主网发送端按文档使用私有 MEV RPC 无此问题。

## 遗留项

- 税队列仍有 ~378 万枚待清算，keeper 会按节奏处理完毕，不要求本次清空。
- 散户全程未 claim（按测试设计保留托管份额）；归属全部到期后散户可正常 claim，其 claim 后持仓参与后续分红——泄漏只发生在"份额锁在托管仓"的窗口期。
- 泄漏修复（presale 加入分红排除名单）排期后，建议用本脚本同参数复测一轮，预期 `withdrawableDividends(presale)` 恒为 0。
