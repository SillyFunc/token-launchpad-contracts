# 自动回购 Keeper：Cloudflare Workers 免费层落地手册

本手册对应 `keeper/` 中的实现。目标是让平台自动完成税费清算与回购，发币用户不需要在创建代币后持续操作。Cloudflare 托管服务本身保持在 Workers 免费层内；Keeper 钱包仅承担 BSC 交易 Gas。

## 1. 当前环境约定

| 项目 | BSC 测试网 | BSC 主网 |
|---|---|---|
| chainId | `97` | `56` |
| Keeper | `0x9f87b1973361b23387D7F1b536484543a5ea1eFB` | 必须另建生产专用钱包，不复用测试网私钥 |
| Pancake V2 Router | `0xD99D1c33F9fC3444f8101754aBC46c52416550D1` | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| 读取 RPC | BNB Chain 测试网公共 RPC | 独立公共/免费 RPC |
| 发送 RPC | 测试阶段可与读取 RPC 相同 | 必须是与读取 RPC 不同的 MEV 保护私有 RPC |

`Deploy.s.sol` 通过 `KEEPER_ADDRESS` 授予 `CoordinatorFactory.KEEPER_ROLE()`，通过 `ROUTER_ADDRESS` 选择环境对应的 Pancake V2 Router。部署脚本不再把主网 Router 写死到测试网部署中。

### 1.1 时间与时区不变量

Worker 运行时的本地时区是 **UTC**，不是部署者机器或浏览器的时区。因此：

- Keeper 全程只使用 **Unix 秒**（`Math.floor(Date.now()/1000)`）存储与比较；D1 的 `started_at`、`created_at`、`next_check_at` 都是 epoch 整数，与展示时区无关。唯一的格式化输出是 `/health` 的 `new Date().toISOString()`，带 `Z` 显式表示 UTC。
- 产品规定前端**固定显示 UTC+8、不跟随浏览器时区**，该规则只属于展示层：前端必须显式指定时区（`timeZone: "Asia/Shanghai"`，或 `"…+08:00"` 字面量，见 `docs/frontend-integration.md`），不得依赖 `toLocaleString()` 的默认行为。
- **禁止在 Worker 内使用本地时间 API**（`getHours()`、`getDate()`、`toLocaleString()` 等）：在 Worker 里它们返回 UTC，会比 UTC+8 早 8 小时。
- 手动运维时，`cast`、`forge` 把 `"2026-09-21 16:00"` 这类字面量按 **UTC** 解析；要么写 `+08:00` 偏移，要么直接给 Unix 秒。
- Cron 表达式（当前 `* * * * *`）由 Cloudflare 按 UTC 解释：间隔型调度与时区无关，将来若要「UTC+8 的整点」，需自行换算（UTC+8 00:00 = `0 16 * * *`）。

## 2. 组件与职责

1. **Cron Worker**：每分钟创建一次 Workflow，不持有业务状态。
2. **Workflow**：校验链、合约和 Keeper 权限；分页发现代币；检查到期任务；记录每次运行结果；失败步骤由 Cloudflare 持久化并重试。
3. **D1**：保存代币、TaxProcessor、金库和 Pair 注册表，保存跨时间储备样本、任务记录、交易记录和告警。
4. **Signer Durable Object**：同一链和 Keeper 钱包只有一个实例，串行签名和发送交易，处理 nonce、重复任务、广播不确定性与过期交易替换。
5. **Cloudflare Secrets**：保存 Keeper 私钥和管理令牌。测试网公共 RPC 与 Coordinator 是公开配置；若主网 RPC URL 含供应商 API key，则主网仍通过 Secret 保存。私钥不会写进仓库、配置文件、日志或 D1。

## 3. 资金流与威胁模型

### 3.1 资产生命周期

- 交易税先留在代币合约；达到代币模板动态阈值时，由代币转入该币独立的 `TaxProcessor`。
- Keeper 调用 `processPendingTax`，TaxProcessor 把一小批税代币换成 WBNB，再解包成 BNB 打给固定 `feeReceiver`。
- 普通代币的固定收款人是创建时配置的税费接收方；带金库代币的固定收款人是对应 `BuybackVault`。
- 金库达到创建时锁定的时间/余额条件后，Keeper 调用 `executeBuyback`。Token 模式买入后发送到 `0xdead`；LP 模式买入并铸造 LP 到 `0xdead`，LP 路径失败时同一交易回退为 Token 买毁。
- Keeper 不接收税金、回购资产或奖励，只支付 Gas。金库不存在创建者提款入口。

### 3.2 失败、暂停与恢复

- 兑换、最低输出、储备上限或 deadline 任一检查失败时，链上交易整体回滚，原始资产仍在 TaxProcessor 或金库。
- Worker 不会通过 `try/catch` 把链上失败伪装成成功；失败交易写入 D1 告警，下一次运行重新报价。
- Durable Object 在任何时间最多保留一个活动 nonce。广播结果不确定时重发同一签名交易；交易 deadline 过期且 nonce 未消费时，使用更高 Gas 价的新鲜任务替换，而不是跳过 nonce。
- D1 或 Cloudflare 免费额度暂时不可用时，链上资金不动，恢复后继续扫描。
- 管理端可撤销 Coordinator 的 `KEEPER_ROLE` 立即停止 Keeper；无需逐个修改金库。
- 暂停开关的实测结论（测试网，2026-09-20）：**改动 `wrangler.jsonc` 的 cron 会生效，但有约 4 分钟传播延迟**。把 `* * * * *` 改成 `0 0 1 1 *` 后，部署输出立即显示新表达式，而每分钟的运行又持续了约 3.75 分钟才停止；把整个 `triggers` 块删掉或置 `"crons": []` 则在观察窗口内始终未停（说明这两种写法不能删除已注册的计划）。因此：①**应急停摆用撤销 `KEEPER_ROLE`**（合约层立即拒绝，不依赖 Cloudflare 传播）；②改完 cron 必须观察至少 5 分钟再判断是否生效；③要彻底删除触发器请到控制台操作并确认。

### 3.3 调用权限和攻击面

- `/admin/run` 与 `/admin/status` 需要高熵 Bearer token；HTTP 接口不能提交任意目标地址、calldata、金额或 nonce。
- Durable Object 在签名前重新从 D1 读取目标，并重新从链上读取 Pair、税率、待处理余额与金库条件。任务目标必须与注册表匹配。
- Keeper 私钥对应的地址只能获得 `KEEPER_ROLE`，绝不授予 `DEFAULT_ADMIN_ROLE`，也不复用部署者或协议金库私钥。
- 合约端再次验证 Keeper 角色、执行条件、单笔金库储备上限、最低输出和不超过 10 分钟的 deadline。

### 3.4 价格、滑点与 MEV

- D1 每分钟记录 Token/WBNB Pair 储备；交易只使用至少 5 分钟以前、1 小时以内的至少 3 个样本作为历史锚点。
- 即时价格与历史中位报价偏离超过 `3%` 时不执行。
- `amountOutMin` 同时取“即时报价减 1%”和“历史锚点报价减 1%”中的较高值。
- 锚点样本会剔除储备为 0 的记录：代币先创建、后加池时每分钟都会写入零储备样本，它们不含价格信息，计入中位数会把锚点拉到 0，让 Keeper 在已有足够有效样本时仍然不成交（表现是静默不成交、不是报错）。
- 实际生效的价格门槛比 `3%` 更紧：`amountOutMin` 取“锚点价 −1%”，而单次清算卖出池内 `0.3%` Token 会按恒定乘积把价格压低约 `0.54%`。所以 Keeper 是**间歇式清算**——成功一笔后要等锚点中位数（窗口内最近 15 个样本）跟上，才会清算下一笔，实测约 8~10 分钟一笔。测试网实测：`pendingTax` 从 `4.73e25` 清到 `5.0e24` 用了约 1.5 小时，全程无告警、无资金滞留风险（税一直在 TaxProcessor）。要提高吞吐可调 `SLIPPAGE_BPS`（100→300，接受更差成交价）或降低 `TAX_MAX_RESERVE_BPS`（30→10，单笔价格冲击更小、清算更频繁但 gas 更多）。
- 税费清算按当前卖税折算 Pair 实际到账量；回购按当前买税折算金库实际到账量，避免把名义输入误当成真实成交输入。
- 单次税费清算最多使用池内 Token 储备的 `0.3%`。金库合约自身还限制单笔回购不超过 WBNB 储备的 `1%`。
- BSC 主网配置强制要求 `SEND_RPC_URL != READ_RPC_URL`；发送端使用 BNB Chain 文档列出的免费私有 RPC，避免把签名交易先暴露到公共 mempool。

这套约束不能保证任意 Meme 币拥有“真实外部公允价”；任意新币通常没有 Chainlink 等独立预言机。历史采样的目标是阻断同交易闪电操纵和明显短时拉盘，不是替代完整预言机。偏离时选择不成交，资金继续留在原合约。

### 3.5 长期不变量

- Cloudflare 中的私钥派生地址必须严格等于配置的 `KEEPER_ADDRESS`。
- RPC 的 `eth_chainId` 必须等于配置的 BSC 环境。
- Coordinator 必须有代码，且 `hasRole(KEEPER_ROLE, keeper) == true`。
- Pair 两侧必须恰好是注册 Token 与 TaxProcessor 返回的 WBNB。
- D1 注册的 TaxProcessor 必须声明同一 Token；签名目标必须等于 D1 注册目标。
- 同一 Keeper 在任意时刻最多有一个未确认 nonce。
- 所有资金交易必须先 `eth_call` 模拟，再估算 Gas、检查 Keeper 余额、签名并通过指定发送 RPC 广播。

## 4. 测试网上线顺序

### 阶段 A：准备 Keeper 钱包

- 已完成公开地址登记：`0x9f87b1973361b23387D7F1b536484543a5ea1eFB`。
- 助记词和私钥仅由负责人离线保存；不得发给协作者或放入 `.env`、聊天记录、截图、Git。
- 从 [BNB Chain 官方测试网水龙头](https://www.bnbchain.org/zh-TW/testnet-faucet) 领取 tBNB。测试阶段建议 Keeper 保留至少 `0.05 tBNB`。

### 阶段 B：部署测试网合约

先把测试网部署钱包导入 Foundry 的本地加密 keystore。私钥只在交互式提示中输入，不写入 `.env` 或命令历史：

```text
cast wallet import launchpad-testnet-deployer --interactive
```

部署时只设置公开参数：

```text
KEEPER_ADDRESS=0x9f87b1973361b23387D7F1b536484543a5ea1eFB
ROUTER_ADDRESS=0xD99D1c33F9fC3444f8101754aBC46c52416550D1
```

先省略 `--broadcast` 做模拟；确认 11 笔交易、Keeper 授权和 Gas 预算正确后，再执行真实广播：

```text
forge script script/Deploy.s.sol:Deploy --rpc-url <BSC testnet RPC> --sender <deployer address> --account launchpad-testnet-deployer --legacy --broadcast --slow
```

命令会在本机询问 keystore 密码。不要把密码写入仓库、环境变量或聊天记录。

执行部署后，必须从 `broadcast/Deploy.s.sol/97/run-latest.json` 取得并链上核验新 `CoordinatorFactory` 地址。禁止把当前旧部署地址绑定到新 ABI。

不带 `--broadcast` 的 `forge script` 仅做模拟，不会生成 `script/deployments/97.json`；部署地址文件只允许由真实广播运行产生。

BscScan 源码发布需要一个免费的 API key。当前机器未配置 `BSCSCAN_API_KEY`，因此这一步不能由仓库自行完成，也不得把 key 提交到 Git。配置后应按广播产物逐个执行 `forge verify-contract --chain 97 --guess-constructor-args --watch <address> <source:contract>`；七个地址全部显示 Verified 后，再更新 `docs/frontend-integration.md` 的发布状态。

### 阶段 C：创建 Cloudflare 免费项目

在 `keeper/` 目录执行：

```text
pnpm install
pnpm wrangler login
pnpm wrangler d1 create sillyfunc-launchpad-keeper-testnet
```

把 D1 命令返回的 `database_id` 写入 `keeper/wrangler.jsonc`，替换全零占位值，然后执行：

```text
pnpm db:migrate:remote
```

### 阶段 D：录入 Secrets

测试网的公开 `READ_RPC_URL`、`SEND_RPC_URL` 与 `COORDINATOR_ADDRESS` 已写入 `keeper/wrangler.jsonc`。以下两个敏感值仍必须通过本机终端录入，不会写入 Git：

```text
pnpm wrangler secret put KEEPER_PRIVATE_KEY
pnpm wrangler secret put ADMIN_TOKEN
```

`ADMIN_TOKEN` 应使用密码管理器生成至少 32 字节随机值。主网使用的 RPC 若包含账户级 API key，也应通过 `wrangler secret put` 录入而非提交到配置文件。

### 阶段 E：部署并验收

```text
pnpm check
pnpm test
pnpm run deploy
```

`pnpm deploy` 会被 pnpm 内置的 `deploy` 命令拦截并报 `ERR_PNPM_CANNOT_DEPLOY`，必须写成 `pnpm run deploy`（等价于 `pnpm run deploy:testnet`）。

测试网 Worker 地址：`https://sillyfunc-launchpad-keeper-testnet.wildfunc.workers.dev`。

部署后依次验证：

1. `/health` 返回 `ok: true`；
2. 携带管理令牌请求 `/admin/status`，链、Coordinator、Keeper 地址和余额正确（缺少 `ADMIN_TOKEN` 时管理接口恒返回 401，必须先完成阶段 D 的第二个 Secret）；
3. 创建带金库测试币、完成开盘并制造应税交易；
4. 确认 TaxProcessor 先累积税代币，而不是在用户卖出交易里内联兑换；
5. 等待至少 8 分钟形成历史样本；
6. 确认 Keeper 自动提交税费清算，BNB 进入金库；
7. 满足金库条件后确认自动回购与销毁/LP 销毁；
8. 检查 D1 任务、交易和告警记录，并核对链上事件。

第 3~7 步由 `script/KeeperAcceptance.s.sol` 提供可复现的验收路径，私钥只在本机 keystore 中：

```text
forge script script/KeeperAcceptance.s.sol:KeeperAcceptance --sig "create()" \
  --rpc-url <BSC testnet RPC> --account launchpad-testnet-deployer --legacy --broadcast --slow

forge script script/KeeperAcceptance.s.sol:KeeperAcceptance --sig "status()" --rpc-url <BSC testnet RPC>
```

`create()` 在**同一笔广播**内完成：带金库发币 → `claimAllTokens()` 领取即上线 → 加 Pancake V2 底池 → 两笔卖出把税推过动态清算阈值。建池与卖出必须同批：Keeper 的历史锚点窗口是 5~60 分钟，若先建池、隔几分钟再卖出，锚点里会混入卖出前价格，偏差超 `3%` 时 Keeper 会（按设计）拒绝执行。

验收脚本硬性限制 `chainId=97`，不能在 BSC 主网执行。主网上线只能使用正式部署流程，不得复用该测试币制造脚本。

不带 `--broadcast` 的同一命令只做模拟，不写 `script/deployments/97-keeper-acceptance.json`，也不产生链上状态；模拟输出会打印预估 gas、Pair 储备与 `pendingTaxTokens`，可先据此确认经济参数。重跑 `create()` 需要换 `ACCEPTANCE_SALT_TAG`，否则尾号 8888 的盐会撞上已部署地址。

D1 侧证据（无需管理令牌）：

```text
cd keeper
pnpm wrangler d1 execute DB --remote --json --command "SELECT id,status,discovered_count,inspected_count,planned_count,submitted_count,error FROM keeper_runs ORDER BY started_at DESC LIMIT 10"
pnpm wrangler d1 execute DB --remote --json --command "SELECT job_id,kind,status,tx_hash,nonce,detail FROM transactions ORDER BY updated_at DESC LIMIT 20"
pnpm wrangler d1 execute DB --remote --json --command "SELECT severity,code,message FROM alerts WHERE resolved_at IS NULL"
pnpm wrangler d1 execute DB --remote --json --command "SELECT block_number,sampled_at,reserve_token,reserve_wbnb FROM price_samples ORDER BY sampled_at DESC LIMIT 10"
```

## 5. 主网上线门槛

- 新建生产 Keeper 钱包，不复用测试网钱包或部署者钱包。
- 替换 `keeper/wrangler.mainnet.jsonc` 中的生产 Keeper 和生产 D1 占位值；文件只包含公开配置，生产私钥仍必须通过 Cloudflare Secret 单独录入。
- 生产钱包只存放约 1–2 周 Keeper Gas，先从小额开始；设置余额告警。
- 选择 BNB Chain 官方列出的免费 MEV 保护私有 RPC，例如 PancakeSwap、48Club 或 Merkle；上线前实测 `eth_sendRawTransaction`、回执可见性和丢包恢复。
- 将 `CHAIN_ID` 改为 `56`，替换生产 Keeper、Coordinator、D1 和 Secrets；不要复用测试环境 D1。
- 在 BSC fork 和测试网上完成税费代币、买税/卖税、LP fallback、价格偏离、RPC 失败、D1 失败、低余额、重复 Cron、nonce 卡住与权限撤销测试。
- 以新广播产物和 BscScan 核验结果同步 SDK、部署地址及前端文档后才能开放 UI。

## 6. 故障验证矩阵

状态说明：`已验证（本地）` 只证明纯逻辑、编译或数据库行为；涉及 RPC、Cloudflare 持久化和链上资金的项目必须在测试网重新验证，不能用本地结果替代。

| 场景 | 预期结果 | 当前证据 |
|---|---|---|
| 即时价格偏离历史锚点 > 3% | 不签名、不发送，资金原地保留 | 已验证（本地单元测试 + BSC fork 集成：基线计划正常构建，真实卖出池内 2% Token 后偏离达 3.49%，计划返回 `null`、Keeper nonce 未变、未发送任何交易） |
| 买税/卖税存在 | 最低输出按实际到账而非名义输入计算 | 已验证（本地单元测试 + Solidity 回归；BSC fork 实池清算实际到账高于最低输出） |
| 税费待处理量过大 | 单次最多清算 Pair Token 储备的 0.3% | 已验证（本地执行计划测试；BSC fork 实测 amountIn = 储备的 0.3%） |
| Keeper 端到端执行（清算 → 入金库 → 回购销毁） | 报价、最低输出、模拟、签名、广播全部成功，回购代币销毁到 `0xdead` | 已验证（BSC fork 实池：清算 1.36e24 税代币、金库 +3.2e14 wei、回购 0.001 BNB 销毁 3.599e24 代币，交易均 `0x1`） |
| LP 回购 | 普通买入与 LP 半仓兑换分别设置最低输出 | 已验证（本地执行计划测试 + BSC fork 实池：Keeper 规划出的 LP 侧最低输出 `1.097e24` 被满足，LP `2.06e19` 铸给 `0xdead`，`totalLpBurned` 与 `0xdead` 持仓一致）；测试网实池复验建议并入主网上线前演练 |
| RPC batch 乱序 | 按 JSON-RPC id 恢复正确顺序 | 已验证（本地单元测试） |
| RPC 返回错误或 HTTP 503 | 显式失败，不把错误当作结果 | 已验证（本地单元测试） |
| 管理令牌缺失或错误 | 管理接口安全失败并返回 401，健康检查仍可用 | 已验证（已部署 Worker：缺失令牌与格式合法但值错误的令牌均返回 401、`/health` 返回 `ok:true`；携带有效令牌返回链 97、Coordinator `0x9a75…bC47`、Keeper `0x9f87…1eFB`、余额与运行/交易/告警记录，均与配置和 D1 一致） |
| 部署与 Cron 连续性 | 每分钟触发一次 Workflow，环境校验通过，运行记录无失败 | 已验证（**截至 2026-09-20 07:52Z / 本地 15:52 快照**：D1 共 249 条运行记录、0 失败、0 未解决告警；记录数持续增长，最新值请查 D1） |
| 私钥与 Keeper 地址不匹配 | 拒绝签名 | 已验证（本地单元测试） |
| BSC Legacy 交易签名 | 可恢复出配置的 Keeper 地址 | 已验证（本地单元测试） |
| D1 首次建库 | 11 条 schema 命令全部成功 | 已验证（Wrangler 本地 D1） |
| 测试网/主网 Worker bundle | 两套配置均成功打包，约 58 KiB gzip | 已验证（Wrangler dry-run） |
| 重复 Cron / Workflow 重试 | 同一 job id 不重复发送 | 已验证（每轮仅一个 Workflow step，job id 固定为“运行 ID + Token + 类型”；Signer 持久化去重，D1 重试不降级已提交状态且不重复累计跳过告警；测试网 nonce 严格连续）。真链故障注入仍待做 |
| 广播已接收但响应丢失 | 重发相同 raw tx，不产生第二个 nonce | 已验证（本地单元测试：`already known` 视为成功且只保留一笔签名交易；未知错误保留同一 raw tx 并标记不确定）；真链故障注入仍待做 |
| 交易长时间 pending | deadline 内重播；过期后由新鲜报价同 nonce 替换 | 已验证（本地单元测试：deadline 内重播、过期且 nonce 未消费时同 nonce 提价替换、nonce 已消费时标记 `consumed`）；真链故障注入仍待做 |
| Keeper 余额不足 | 不签名，D1 生成 critical 告警 | 已验证（本地单元测试：不签名且 `keeper-balance-low` critical 告警落库）；测试网真链验证仍待做 |
| gas 价格超上限 | 不签名，D1 生成 warning 告警 | 已验证（本地单元测试：`gas-price-high` warning 告警落库） |
| 清算停摆的可观测性 | 连续跳过达到阈值写入去重 warning，成交后自动解除 | 已验证（本地单元测试：阈值 5 次、同码去重、成交后清零并解除、`busy`/`already-submitted` 不计数） |
| 撤销 `KEEPER_ROLE` | 环境检查失败，不再执行交易 | 已验证（单元测试 + BSC fork 集成 + **测试网真链**：撤销后 Worker 的 `verify-chain-and-role` 步骤精确报错 `Keeper 0x9f87… does not have KEEPER_ROLE`，最后成功步骤停在 `start-run-1`（发现/采样/签名/广播全未执行），Keeper nonce 保持 48 不变；恢复角色后新运行立即 `complete`，旧实例按退避重试后自愈，全程 0 failed、0 告警）。**注意：失败步骤按指数退避重试（10s→20s→41s→80s…），运行会长时间停在 `running` 而不是立刻 `failed`** |
| D1/Workflow 暂停后恢复 | 链上资产不动，恢复后继续扫描 | 已验证（测试网：cron 改为年周期后运行在约 3.75 分钟后停止，停摆 16.7 分钟内 Keeper nonce、金库 `buybackCount`、`0xdead` 余额完全未变；恢复 `* * * * *` 后约 3.5 分钟运行恢复为 `complete`。**cron 变更传播延迟约 4 分钟**，应急停摆仍应使用撤销 `KEEPER_ROLE`） |
| LP 路径失败 | 合约同交易回退 Token 买毁 | 已验证（Solidity 测试 + BSC fork 实池：把 LP 侧最低输出抬到不可能满足后，LP 子调用回滚、同一交易回退 Token 买毁，`totalBurnedToken` 增加而 `totalLpBurned` 不变）；测试网实池复验建议并入主网上线前演练 |
| 私有 RPC 丢包或不可用 | 无公开 RPC fallback；任务保留并重试 | 待主网上线前演练 |
| 端到端：税费清算 → BNB 入金库 | Keeper 自动提交 `processPendingTax`，BNB 进入固定收款人 | 已验证（**截至 2026-09-20 07:52Z / 本地 15:52 快照**：37 笔 tax 交易；`amountIn` 恒为池储备 0.3%，链上 `out` 均高于 `minQuoteOut`，快照时 `pendingTaxTokens=0`。计数随 Keeper 运行持续增长，最新值请查 D1） |
| 端到端：自动回购与销毁 | 金库条件满足后 Keeper 调 `executeBuyback`，代币销毁到 `0xdead` | 已验证（**截至 2026-09-20 07:52Z / 本地 15:52 快照**：11 次回购，`totalBuybackBNB=1.1e16`、`totalBurnedToken=4.0071579898118416592106661e25`，与 `0xdead` 余额完全一致） |
| Keeper 自身执行造成的价格漂移 | 单次清算压低价格约 0.54%，锚点滞后期间不成交、资金原地保留 | 已验证（测试网：连续 6 轮 `INSUFFICIENT_OUTPUT_AMOUNT` 跳过，约 8 分钟后随锚点翻转自动恢复） |

## 7. 免费层容量

### 7.1 两条必须长期成立的边界

当前设计每分钟一个 Cron、每轮最多检查 8 个资产，并使用批量 JSON-RPC。免费层真正紧的是下面两条，**都不是重试**：

1. **每轮只保留一个 `step.do`**：免费层自 2026-08-10 起每天仅含 3,000 个 Workflow steps，每分钟一轮即 1,440 steps/day（约 48%），其余额度留给手动运行。若按旧实现把健康检查、发现、每个资产和每笔交易拆成独立步骤，会稳定超额并停止执行——免费层超限不收费，只会让后续操作报错直到额度重置。
2. **单步 active CPU 必须留在 10 ms 内**（付费层为 30 秒）：单步要完成发现、最多 8 个资产的检查与规划、以及资金动作记账。链上签名与 ABI 重活都在 Signer Durable Object 内（30 秒预算），这一步只剩 JSON-RPC 收发与轻量编解码；测试网连续 260+ 轮无 CPU 超限失败。扩容时应先减少每轮资产数，**不要**为了分摊 CPU 把工作拆成多步——那会先撞 step 额度。

### 7.2 失败与重试：不占 step 额度，但限制单步生命周期

官方 pricing 明确 **retries 与 rollback handler 不计入 step 额度**，因此 3,000 steps/day 不会被失败重试吃掉。限制重试是为了另外两件事：

- 平台默认 `retries.limit=5`（指数退避约 10s/20s/40s/80s/160s）会让一次失败拖到约 5 分钟才落定，期间后续 Cron 轮次已并发开跑，重复做同样的发现与检查；
- 失败落定越晚，`keeper_runs.status='failed'` 出现越晚，告警发现越迟。

因此 `keeper/src/workflow.ts` 显式传入 `{ retries: { limit: 2, delay: "10 seconds", backoff: "exponential" } }`：最坏退避约 30 秒（3 次尝试 + 10s/20s 退避，另加各次尝试的网络等待），单轮通常在下一次 Cron 之前结束，失败能在 1 分钟内写进 D1。整步重试不会二次签名——job id 固定为 `${runId}:${kind}:${token}`，Signer 以该 id 去重，重试拿到的是 `already-submitted`，D1 仍记为已提交。

### 7.3 代币规模上限：采样退化

锚点策略要求同一交易对在 5~60 分钟窗口内至少有 3 个有效样本（`MIN_ANCHOR_SAMPLES=3`、`ANCHOR_MIN_AGE_SECONDS=300`、`ANCHOR_MAX_AGE_SECONDS=3600`）。每轮只检查 8 个资产，且按 `next_check_at ASC` 公平轮转，所以每个资产的采样间隔约为 `N/8` 分钟、每小时样本数约 `480/N`：

| 代币数 N | 每资产采样间隔 | 每小时样本 | 锚点 |
|---|---|---|---|
| ≤ 40 | ≤ 5 分钟 | ≥ 12 | 可持续 |
| 80 | 10 分钟 | 6 | 可持续 |
| **160** | **20 分钟** | **3** | **理论临界** |
| ≥ 320 | ≥ 40 分钟 | ≤ 1.5 | **不足：清算静默停滞** |

超过约 160 个代币后，部分资产的样本凑不满 3 个，锚点永远不成立：**资金安全（不成交、不清算），但税费会一直留在代币合约里不被处理，而且不会产生告警**——"样本不足"是策略的正常跳过结果，不是错误。扩容顺序应为：提高 `MAX_ASSETS_PER_RUN`（同时复核单步 CPU 与每轮 subrequest 数）→ 把 Cron 调快（需要付费层的 step 额度）→ 最后才是接受更长的清算周期。上线后应把「活跃代币数」与「每资产每小时样本数」纳入监控。

`price_samples` 会随运行持续增长，但同样被每轮 8 个资产封顶：约 11,500 行/天、1.7 MB/天，5 GB 免费存储约可用 8 年；长期运行或扩容前需要给该表加保留期清理。

Cloudflare 免费层超限时不会自动收费，而是让后续操作失败，直至额度重置。**额度紧张时**应先降低每轮资产数或把 Cron 调慢；**代币数增长导致采样不足时**方向相反，需要提高每轮资产数或轮询频率，但必须先把 step 额度与单步 CPU 算清楚，必要时才升级付费套餐，不得在额度不足时静默继续。官方口径以 [Workflows pricing](https://developers.cloudflare.com/workflows/reference/pricing/)、[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)、[Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) 和 [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/) 为准。

已核对的免费层口径与实际用量：

| 项目 | 免费层限额 | 当前用量 |
|---|---|---|
| Workflow 执行次数 | 100,000/天（与 Workers 日请求限额共享） | 1,440/天（每分钟一次 Cron） |
| Workflow steps | 3,000/天（**重试与回滚不计入**） | 1,440/天（每轮固定一个 step，约占 48%） |
| Workflow 实例并发 | 100/账号 | 每轮运行数秒内结束，实际并发 1~2 |
| 单步 active CPU | 10 ms/步 | 单步内最多 8 个资产的 JSON-RPC 与轻量编解码；测试网 260+ 轮无 CPU 超限失败 |
| Durable Object CPU | 30 秒/请求 | 签名路径本机基准 ~3.3 ms，ABI 编解码 ~0.03 ms |
| D1 存储 | 5 GB | 2026-09-20 08:10Z 远端快照约 184 kB（约 1.7 MB/天增长，见 §7.3） |

签名与编解码的开销用 `keeper/test` 下的临时基准测得（Node/V8，非 workerd），量级上远低于 DO 的 30 秒 CPU 限额；首次真实签名是否触发限额，以测试网税费清算交易的 D1 记录为准。

参考：

- [Cloudflare Workflows 免费层限制](https://developers.cloudflare.com/workflows/reference/limits/)
- [Cloudflare D1 定价与免费额度](https://developers.cloudflare.com/d1/platform/pricing/)
- [Cloudflare Durable Objects 定价与免费额度](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- [BNB Chain 私有 RPC / MEV 保护指南](https://docs.bnbchain.org/bnb-smart-chain/validator/mev/user-guide/)
- [PancakeSwap V2 0.25% 交易费](https://docs.pancakeswap.finance/trade/pancakeswap-exchange/trade)
