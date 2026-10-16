# SillyFunc Launchpad Keeper

Cloudflare Workers 免费层上的 BSC 四通道税费、自动加池与自动回购执行器。它规划三类任务：`tax`（市场/销毁/LP/分红拆分）、`liquidity`（双边加池并销毁 LP）和 `buyback`。四通道资金流的设计与威胁模型见主仓库 [`docs/four-channel-tax-design.md`](https://github.com/SillyFunc/token-launchpad-contracts/blob/main/docs/four-channel-tax-design.md)。keeper 的独立部署与验收文档已移除,部署前请以源码和 `wrangler.jsonc` 为准。

## 安全边界

- Keeper 仅持有 `KEEPER_ROLE` 与少量 Gas，不得持有 Admin 权限。
- 私钥只通过 `wrangler secret put KEEPER_PRIVATE_KEY` 录入。
- 主网交易必须使用独立的 MEV 保护 `SEND_RPC_URL`。
- HTTP 管理接口不能提交任意交易；Signer 会重新核对 D1 注册表和链上状态。

## Gas 优化设计与威胁模型

以下 Keeper 策略与示例配置尚未部署到 Worker；现有定时任务不会因本次本地修改自动改变。Gas 策略本身不改变链上资金接收方和税率；本轮新版合约与 Reader 的设计及发布边界见 [`docs/maintenance-design.md`](../docs/maintenance-design.md)，新接口均为 pending deployment。

税代币仍由 token / TaxProcessor 托管，LP 双边资产仍由处理器按原账本托管，市场收入仍归固定接收方或金库；经济等待不发送交易、不转移或挪用这些资产。处理器的卖出与加池仍可能产生二次卖税，等待合批只减少执行频次，不提供免税或提款路径。金库回购仍须满足合约的时间、余额及池储备门槛。

Signer 在重新读取链上状态、验证历史价格锚并估算交易后，要求 Gas 成本不超过本批经济价值的配置比例。`tax` 按整批代币在现价与已校验历史锚中的较低 BNB 价值估值，包含纯销毁批次；`liquidity` 只计较低的 WBNB 单边价值，不将两侧重复计价；`buyback` 按实际 BNB 输入计价。估值为 0 不得绕过成本检查。现有储备上限、滑点、历史偏差与短 deadline 继续约束执行，不能为通过经济门槛而放宽。

税处理与加池各自合批，并受单币与全局 Gas 窗口预算约束。Signer 将已签名交易的预算保留到 receipt 到达；pending 交易不能靠重试或窗口滚动逃逸预算，同 nonce 的 replacement 不重复开启冷却。receipt 按实际 Gas 费用结算，链上 revert 同样计费。经济等待使用 `deferred`，由后续检查在冷却结束、余额累计、Gas 降低或窗口预算恢复后重算；它不代表链上故障。

预算预留采用签名的 Gas 上限乘以最终 Gas 价格，包含估算余量。同 nonce 的候选交易全局只预留最高额度；确定赢家后，其他候选不再占费。缺少 receipt 费用字段或 nonce 已前进但 RPC 找不到任何候选回执时，按签名最高费用保守结算，可能在预算窗口内高估支出；不会按零成本释放。旧 Signer 的 pending 会从已保存的原始签名恢复预留，无法恢复时停止签名并报错。

### 旧签名交易的重播守卫

prepared 恢复发送与 submitted 重播共用同一个检查入口。顺序为:先完成收据与 nonce 对账(已有收据直接结算,不广播);nonce 已消费但收据缺失时沿用同 nonce 保守计费。仍待发送时,Signer 解码原 `raw_tx`,核对 hash、chainId、nonce、目标地址与签名者为 Keeper,并用原 from/to/data/value/gas/gasPrice 对 `latest` 状态执行 `eth_call`。模拟通过且 deadline 仍有效后,才发送完全相同的原始交易,不重新规划、不改报价或 calldata、不延长 deadline、不重新签名。

合约回滚、RPC 异常或原交易数据异常时本次不发送,`detail` 记录原因;交易不标记为取消,不删除记录,不释放 nonce 或 Gas 预留,后续仍观察回执并按原规则结算。检查时间保存在 Durable Object KV(`replay-check:<job_id>`),不写入 SQL,不改变 `submitted_at`,并沿用 `PENDING_RETRY_SECONDS` 限频。限频只阻挡模拟与重播,不阻挡收据查询、nonce 对账,或 deadline 过期后既有的同 nonce 替换流程。

注意:重复广播本身不会重复扣链上 Gas,同一笔交易只会被打包一次。模拟通过与打包之间仍可能发生状态变化,已广播交易不会因此自动撤销。守卫只减少明显会失败的广播,不替代合约内的执行条件。

`deferred` 的明细会记录 `gas-ratio`、`cooldown`、`token-gas-budget` 或 `global-gas-budget`。冷却从首次签名与预算成功持久化时开始，失败交易同样受间隔限制；普通检查、经济等待和同 raw 重播不重置计时。已有旧交易尚在 pending 时，新计划被经济门槛拒绝也不会删除旧交易跟踪。Signer 的状态(当前窗口已计费用、未结算预留与全局预算上限)目前仅作为内部 Durable Object 方法存在,Worker 不再暴露管理接口。

现有 LP 算法在 WBNB 不足时按卖税反推名义代币输入；10% 卖税与 WBNB 限额的回归验证了税后实际配比，因此本次保留该算法。此前链上约 19% 尾数递减和 30 秒调度尚未对应到这个本地实现；本次回归不能证明另一个线上进程已修复。发布前必须核实实际运行程序与唯一调度实例，避免旧实例继续耗 Gas。

攻击者可能制造小额税、捐赠、操纵即时储备或诱发失败来消耗 Keeper 余额。最小经济比例、执行间隔和持久化预算限制此类消耗；历史储备锚、受保护发送端、交易模拟、链上最低输出与权限检查共同约束价格和回调风险。历史锚与 RPC 属于既有链外信任边界，不是链上预言机；未确认交易始终保留 nonce 和费用归属，失败不应清空待处理资产账本。

### 非密钥策略参数

| 环境变量 | 默认值 | 含义 |
|---|---:|---|
| `MAX_GAS_COST_BPS` | `1000` | Gas 成本最多为本批保守经济价值的 10%；范围 1–10000 |
| `TAX_EXECUTION_INTERVAL_SECONDS` | `900` | 同币税处理首次签名之间至少间隔 15 分钟 |
| `LIQUIDITY_EXECUTION_INTERVAL_SECONDS` | `900` | 同币加池首次签名之间至少间隔 15 分钟 |
| `GAS_BUDGET_WINDOW_SECONDS` | `3600` | Gas 预算统计窗口，默认 1 小时 |
| `MAX_TOKEN_GAS_PER_WINDOW_WEI` | `1000000000000000` | 每币每窗口最多 0.001 BNB Gas |
| `MAX_TOTAL_GAS_PER_WINDOW_WEI` | `10000000000000000` | 全局每窗口最多 0.01 BNB Gas |

三个时间参数均为 60–86400 秒；两个预算必须为正 wei，单币预算不得大于全局预算。未设置环境变量时源码采用上述默认值。示例配置新增同名非密钥参数；只有部署包含新 Signer 逻辑的 Worker 后才生效，发布前须完成测试与目标环境配置核对。Cron 检查频率与交易执行间隔是两个独立参数。

## 共享读取与串行维护

`src/reader.ts` 导出 `getTokenSnapshot(config, token)` 与 `TokenSnapshot`，原样返回 Reader 命名 struct（`contracts/controls/pool/tax/liquidity/buyback`）供 DApp 与 Keeper 复用；`src/health.ts` 的 `assertReaderBinding` 可独立核对固定 Coordinator。Keeper 内部将同一对象适配为 Planner、Signer 和 `maintainToken` 使用的 `AssetSnapshot`。可选 `READER_ADDRESS` 明确选择新版 `Reader` 模式：每次快照只发一个 `getTokenSnapshot(token)` 的 `eth_call`，使用返回区块与时间，验证 schema、注册合约地址和控制位。Reader 的回滚、RPC/解码失败或地址不符会停止该资产的执行，不会降级成旧模式放行。

`READER_ADDRESS` 初始不配置；未配置时保留旧部署的 getter 适配，不读取不存在的 `executionFlags()`。旧模式没有新版暂停开关，应继续以原有权限和条件运维。只有新 Coordinator 与绑定 Reader 完成部署核验后才能配置 Reader，不得把新 ABI 绑定旧地址。金库原因 `Paused=6` 属于正常等待，旧固定金额金库的本地诊断改为 `LegacyFixedAmountExceedsReserveCap=7`，二者不混用。

`maintainToken` 按 `tax → liquidity → buyback` 串行检查；暂停动作直接跳过报价和广播，LP 暂停也阻止 LP 模式回购进入 fallback。本轮未执行资金动作时复用一次快照，不为三个 no-op 重复读取；就绪诊断每币每轮只记录一次。Signer 在真正签名前仍重取最新状态、重新报价，并沿用持久化幂等、Gas 经济性、冷却与窗口预算。一旦结果为 `submitted`、`already-submitted` 或钱包 `busy`，本币立即停止后续动作，留给下一轮确认后重读，不阻塞等待链上，也不一次预制并广播三笔。Workflow 重试使用稳定的 `runId:kind:token` 任务 ID，交易记账失败继续向上抛出以重试。

## 本地验证

```text
pnpm install
pnpm check
pnpm test
```

复制 `.dev.vars.example` 为 `.dev.vars` 后,填入测试专用私钥即可运行本地 Worker。`.dev.vars` 只放密钥,非密钥参数统一来自 `wrangler.jsonc` 的 `vars`。`.dev.vars` 已被 Git 忽略。

## Cloudflare 资源

- Cron：每分钟触发一次。
- Workflow：发现、采样、规划、执行和可恢复重试。
- D1：资产注册表、历史储备、运行记录、交易和告警。
- SQLite Durable Object：单钱包 nonce 串行化和幂等签名广播。

`wrangler.jsonc` 中的 D1 `database_id` 是占位值；创建 D1 后必须替换再部署。

主网上线时修改 `wrangler.mainnet.jsonc` 中的生产 Keeper 与 D1 占位值，再用 Cloudflare Secrets 录入生产私钥。测试网和主网配置、数据库及私钥不得复用。
