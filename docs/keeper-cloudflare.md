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

### 3.3 调用权限和攻击面

- `/admin/run` 与 `/admin/status` 需要高熵 Bearer token；HTTP 接口不能提交任意目标地址、calldata、金额或 nonce。
- Durable Object 在签名前重新从 D1 读取目标，并重新从链上读取 Pair、税率、待处理余额与金库条件。任务目标必须与注册表匹配。
- Keeper 私钥对应的地址只能获得 `KEEPER_ROLE`，绝不授予 `DEFAULT_ADMIN_ROLE`，也不复用部署者或协议金库私钥。
- 合约端再次验证 Keeper 角色、执行条件、单笔金库储备上限、最低输出和不超过 10 分钟的 deadline。

### 3.4 价格、滑点与 MEV

- D1 每分钟记录 Token/WBNB Pair 储备；交易只使用至少 5 分钟以前、1 小时以内的至少 3 个样本作为历史锚点。
- 即时价格与历史中位报价偏离超过 `3%` 时不执行。
- `amountOutMin` 同时取“即时报价减 1%”和“历史锚点报价减 1%”中的较高值。
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
pnpm deploy
```

部署后依次验证：

1. `/health` 返回 `ok: true`；
2. 携带管理令牌请求 `/admin/status`，链、Coordinator、Keeper 地址和余额正确；
3. 创建一个带金库测试币并完成开盘；
4. 制造少量应税交易，确认 TaxProcessor 先累积税代币；
5. 等待至少 8 分钟形成历史样本；
6. 确认 Keeper 自动提交税费清算，BNB 进入金库；
7. 满足金库条件后确认自动回购与销毁/LP 销毁；
8. 检查 D1 任务、交易和告警记录，并核对链上事件。

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
| 即时价格偏离历史锚点 > 3% | 不签名、不发送，资金原地保留 | 已验证（本地单元测试） |
| 买税/卖税存在 | 最低输出按实际到账而非名义输入计算 | 已验证（本地单元测试 + Solidity 回归） |
| 税费待处理量过大 | 单次最多清算 Pair Token 储备的 0.3% | 已验证（本地执行计划测试） |
| LP 回购 | 普通买入与 LP 半仓兑换分别设置最低输出 | 已验证（本地执行计划测试）；待测试网实池验证 |
| RPC batch 乱序 | 按 JSON-RPC id 恢复正确顺序 | 已验证（本地单元测试） |
| RPC 返回错误或 HTTP 503 | 显式失败，不把错误当作结果 | 已验证（本地单元测试） |
| 管理令牌缺失或错误 | 管理接口安全失败并返回 401，健康检查仍可用 | 已验证（Wrangler 本地运行时） |
| 私钥与 Keeper 地址不匹配 | 拒绝签名 | 已验证（本地单元测试） |
| BSC Legacy 交易签名 | 可恢复出配置的 Keeper 地址 | 已验证（本地单元测试） |
| D1 首次建库 | 11 条 schema 命令全部成功 | 已验证（Wrangler 本地 D1） |
| 测试网/主网 Worker bundle | 两套配置均成功打包，约 58 KiB gzip | 已验证（Wrangler dry-run） |
| 重复 Cron / Workflow 重试 | 同一 job id 不重复发送 | 待测试网验证 |
| 广播已接收但响应丢失 | 重发相同 raw tx，不产生第二个 nonce | 待测试网故障注入 |
| 交易长时间 pending | deadline 内重播；过期后由新鲜报价同 nonce 替换 | 待测试网故障注入 |
| Keeper 余额不足 | 不签名，D1 生成 critical 告警 | 待测试网验证 |
| 撤销 `KEEPER_ROLE` | 环境检查失败，不再执行交易 | 待测试网验证 |
| D1/Workflow 暂停后恢复 | 链上资产不动，恢复后继续扫描 | 待 Cloudflare 测试网验证 |
| LP 路径失败 | 合约同交易回退 Token 买毁 | 已验证（Solidity 测试）；待测试网实池验证 |
| 私有 RPC 丢包或不可用 | 无公开 RPC fallback；任务保留并重试 | 待主网上线前演练 |

## 7. 免费层容量

当前设计每分钟一个 Cron、每轮最多检查 8 个资产，并使用批量 JSON-RPC。对早期平台规模远低于 Workers、Workflows、D1 与 Durable Objects 免费额度。若代币规模增长，应先增加分页轮转时间，不应静默绕过限额或自动升级付费套餐。

参考：

- [Cloudflare Workflows 免费层限制](https://developers.cloudflare.com/workflows/reference/limits/)
- [Cloudflare D1 定价与免费额度](https://developers.cloudflare.com/d1/platform/pricing/)
- [Cloudflare Durable Objects 定价与免费额度](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- [BNB Chain 私有 RPC / MEV 保护指南](https://docs.bnbchain.org/bnb-smart-chain/validator/mev/user-guide/)
- [PancakeSwap V2 0.25% 交易费](https://docs.pancakeswap.finance/trade/pancakeswap-exchange/trade)
