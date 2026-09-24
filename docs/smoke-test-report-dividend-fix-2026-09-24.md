# BSC 测试网预售分红泄漏修复回归验证

> 网络：BSC Testnet，chainId 97
> 新 Coordinator：`0x63e325d9782DD42915a41673dA2Cc29F8e9B8424`（修复后全量重新部署）
> 状态：**PASS —— 泄漏修复生效**（2026-09-24）。本报告是《smoke-test-report-presale-2026-09-23.md》所复现问题的修复回归：相同代币参数、相同预售参数、同一验证脚本，验证托管仓在分红持续流入期间可领恒为 0，分红全部流向真实持有人。

## 修复与新部署核验

- 修复提交 `5da0c75`（`codex/fix-presale-dividend-leak`，已合并 main）：`_createTokenBody` 先建托管仓，`createInfrastructure` 新增 presale 参数并在创建时 `excludeAddress(presale)`。全量测试 219/219 通过。
- 新部署 15/15 回执 `0x1`；十个地址均有链上代码；四个工厂均向新 Coordinator 授予 `COORDINATOR_ROLE`；两个基础设施工厂 `keeperRegistry` 指向新 Coordinator；keeper（`0x9f87b197…`）持有 `KEEPER_ROLE`。
- keeper Worker 已切换 `COORDINATOR_ADDRESS` 并重新发布，`/health` 返回 ok；D1 旧资产继续由旧 Coordinator 服务（keeper 角色保留），未做清理。

## 验证资产（与泄漏复现轮同参数）

| 对象 | 地址 |
|---|---|
| Token (PFA) | `0x048dCC772865Af37eD88230AED5Ddc163E4c8888` |
| Presale（托管仓） | `0x592567F37cE2270A8E217f4963148560377E8028` |
| Vault（TokenBurn） | `0x0901a8413c6f5Ae2e9b2641163D4c19dd9aeBf09` |
| Pair | `0xaCA71D7C53923DD8B2E4aACfCf419Ca63FCCc411` |
| TaxProcessor | `0x138103308A6E76080674B88672251AAe66e6a21A` |
| Dividend | `0x81C79E7c14C5EF77367dBf6Bdf2AeaC80b7CECFC` |

买税 500 / 卖税 1000 bps；四通道 4000/1000/2000/**3000**；vesting 30min×20%；2 散户各认购 0.03 tBNB；创建者购买 1,000 万枚。

## 修复生效证据

**① 创建时（链上即时验证）**：`excludedFromDividends(presale) = true`（pair、TaxProcessor 同为 true）——托管仓从第一秒起被排除。

**② 清算期间（keeper 自动执行约 1.5 小时）**：

| 指标 | 泄漏复现轮（2026-09-23，未修复） | 本回归轮（已修复） |
|---|---:|---:|
| 分红累计入账（清算至快照点） | 127,825,302,804,627 wei | 282,735,266,155,673 wei |
| **托管仓可领 `withdrawableDividends(presale)`** | **125,216,623,155,552 wei（97.96%）** | **0（全程恒为 0）** ✅ |
| 托管仓被扫走金额 `withdrawnDividends(presale)` | 218,731,944,111,071 wei | **0** ✅ |
| 真实持有人可领 | 2.04% | 282,735,266,155,672 wei（≈100%，仅 1 wei 舍入差） |

- 回归期间托管仓始终锁着两名散户的 6,000 万枚（未 claim 的 vesting 份额）——正是昨天泄漏 97.96% 的同一持仓结构；修复后该持仓不再产生任何分红权益。
- 创建者分批 claim 至 3 亿枚（流通持仓 1.8 亿，`totalShares = 1.8e26`），作为唯一流通持有人拿走全部分红（MasterChef 按存款时点份额结算，逐笔一致）。
- 注：本回归未触发"无合格股东时 deposit 返回 false 并 deferred"分支（创建者开盘即持股）；该分支已由单元测试 `test_PresaleEscrowCannotReceiveVestingPeriodDividends` 覆盖。

## 全链路回归（税收四通道 + 金库）

新 Coordinator 上完整跑通：发币 → 预售 → 开盘 → 税收归集 1,250 万枚 → keeper 自动清算 → 四通道分配 → 金库积累 → 自动回购。快照：

| 指标 | 数值 |
|---|---:|
| 市场通道累计入金库 | 335,228,642,910,819 wei（含 13 wei 费尘埃） |
| 金库回购次数 / 花费 / 销毁 | 1 / 293,386,927,616,943 wei / 2,216,244.89 枚 |
| 金库余额 / readiness | 83,593,427,257,306 wei / InsufficientBalance（继续积累） |
| deflation 累计销毁 | 834,269.71 枚 |
| LP 通道加池累计 | 583,306.88 枚 + 73,154,817,991,538 wei WBNB |
| Token `0xdead` 持仓 | 443,050,514.60 = 未售 440,000,000 + deflation 834,269.71 + 金库 2,216,244.89（**逐 wei 闭合**） |
| Pair `0xdead` LP 持仓 | 3,470,631,649,446,797,801,664 |
| 待清算税 | 4,157,302.89 枚（keeper 持续清算中） |

主要交易：createTokenWithVault `0x3fda52aa…`、setupPresale `0x187632ce…`、openPresale `0x7427d8d1…`、endPresale `0xd8c01f6c…`、launch `0x5eec64f4…`、首轮卖出 `0xfba2ac7c…`、大额卖出 `0x0b97e3ff…`、归集卖出 `0xdd12a49c…`，全部 `0x1`（另有两笔 claim：创建者份额领取 `0xc2759ee7…`、`0x5dfb3d5a…`）。

## 运维备注

- 本轮曾因测试终端残留昨日的 `ACCEPTANCE_SELL_TOKENS` 环境变量导致一笔卖出量不及预期（0xc2759ee7/0x6b1eb96e，多卖量改为 500 万枚），属测试操作事故、与合约无关；后续以显式变量重跑完成。
- 首轮卖出携带 `--gas-estimate-multiplier 200`，未再出现昨日的首卖 OOG（前报告运维发现 1 的规避措施有效）。
- 散户全程未 claim（测试设计保留托管份额）；散户此后任意时刻 claim 即可正常登记为分红股东，修复不影响其 claim 后权益。

## 结论与后续

- **托管仓分红泄漏已修复并通过测试网实网回归**：泄漏轮与回归轮在同一参数下的对照为 97.96% → 0%。修复可以进入主网发布流程。
- 主网上线前仍需：生产全量部署与接线核验、生产 keeper 钱包与私有 RPC、BscScan 源码验证、D1 按文档策略初始化；LpBurn 失败回退实网演练仍建议并入主网上线前演练。
