# 主网 Keeper 上线前验收

目标：在 BSC 主网上让 tax、liquidity、buyback 三条执行路径各成功 2–3 次，结果可在 BscScan 上核验，然后立即停止。验收比的是**路径覆盖**，不是执行频率；路径全部通过后继续运行不会产生新信息，只会消耗 Gas。

成本控制靠三样东西，而不是单批门槛：

1. **D1 暂停开关**：keeper 只处理 `assets.status = 'active'` 的资产；发现流程不会覆盖手动设置的状态。
2. **Gas 预算硬上限**：`env.test` 中单币 0.001 BNB/小时、全局 0.003 BNB/小时。
3. **验证完就停**：每条路径达标后把资产设为 `paused`。

## 0. 准备

| 项目 | 说明 |
|---|---|
| 部署账户 | 持有 Coordinator `DEFAULT_ADMIN_ROLE`，测试结束后用它调用 `temporaryRecoverAll` |
| Keeper 账户 | 独立地址，只授予 `KEEPER_ROLE`，余额 ≥ 0.005 BNB |
| 验收账户 | 发币、加池、卖出用，需要 LP 所需 BNB + 少量 Gas |
| PancakeSwap V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E`（与 `broadcast/Deploy.s.sol/56` 一致） |
| Keeper 发送 RPC | 主网必须使用带 MEV 保护的 `SEND_RPC_URL`，部署前替换 `env.test` 中的公共节点 |

## 1. 部署验收合约

验收使用带 `[TEMP-RECOVERY]` 的版本，测试结束后可回收金库与 TaxProcessor 中的剩余资产。为了让第一笔税更快进入 TaxProcessor，可把初始清算阈值调低（整枚数，默认 MIN=50000、START=400000）：

```bash
LIQ_THRESHOLD_START_TOKENS=100000 KEEPER_ADDRESS=<keeper> ROUTER_ADDRESS=0x10ED43C718714eb63d5aA57B78B54704E256024E forge script script/Deploy.s.sol:Deploy --rpc-url bsc --account <deployer-keystore> --broadcast --slow
```

- 只用命令行临时设置 `LIQ_THRESHOLD_*`，**不要写进 `.env`**；`forge test` 的 `DeployThresholdTest` 会在 `.env` 带有覆盖值时失败，可作为防呆检查。
- 部署会覆盖 `script/deployments/56.json`。把它另存为 `script/deployments/56-mainnet-test.json` 后执行 `git checkout script/deployments/56.json`；前端文档与 SDK **不得**同步到验收地址。后续脚本通过 `COORDINATOR_ADDRESS` 指定验收 Coordinator。
- 核对日志中的 `START_LIQ_THRESHOLD (tokens)` 与预期一致。

## 2. 部署 keeper 验收环境

在 `keeper/` 目录：

1. 在 `env.test.vars` 中填入验收 Coordinator 与 Keeper 地址；`SEND_RPC_URL` 已预设为 48 Club（`https://rpc-bsc.48.club`）。
2. 部署：`pnpm deploy:test`。D1 不需要手动创建，首次部署会按 `database_name` 自动创建 `token-launchpad-keeper-mainnet-test`。
3. 立即建表：`pnpm db:migrate:remote:test`。
4. 录入私钥：Keeper 私钥以 Foundry keystore 为唯一来源，解密后直接经管道写入 Cloudflare Secret，不在屏幕或 shell 历史中出现（Git Bash，keystore 密码在提示中输入）：

   ```bash
   cast wallet decrypt-keystore <keeper-keystore> | grep -oE '0x[0-9a-fA-F]{64}' | npx wrangler secret put KEEPER_PRIVATE_KEY --env test
   ```

   在第 3、4 步完成前，每分钟的 Cron 会因缺表或缺私钥报错，但不会发出交易。
5. 若正式 Worker 也在运行且使用同一 Keeper 私钥，先停掉其中一个，避免 nonce 冲突。

`env.test` 与正式配置的差异：

| 参数 | 正式 | 验收 | 原因 |
|---|---|---|---|
| `MAX_GAS_COST_BPS` | 1000 | 10000 | 浅池单批价值小；只拒绝 Gas 高于处理价值的批次 |
| `TAX_MAX_RESERVE_BPS` | 30 | 100 | 单批最多卖出池中 1% 代币 |
| 执行间隔 | 900 秒 | 120 秒 | 条件满足后尽快执行 |
| `GAS_PRICE_MULTIPLIER_BPS` | 12000 | 10000 | 不溢价出价 |
| 全局 Gas 预算 | 0.01 BNB/小时 | 0.003 BNB/小时 | 验收花费硬上限 |
| `MIN_KEEPER_BALANCE_WEI` | 0.01 BNB | 0.003 BNB | 降低 Keeper 备用金 |

## 3. 创建验收代币

`KeeperAcceptance.create()` 在一次广播内完成：发币（带回购金库）→ `claimAllTokens` 上线 → 加池 → 两笔卖出把税推过清算阈值。建池与卖出必须同批，否则 keeper 的历史价格锚包含卖出前价格，会按设计拒绝执行。LP 归验收账户所有，测试结束可撤池取回。

在仓库根目录：

```bash
ACCEPTANCE_ALLOW_MAINNET=true COORDINATOR_ADDRESS=<test-coordinator> ACCEPTANCE_LP_BNB=50000000000000000 ACCEPTANCE_SALT_TAG=mainnet-test-1 forge script script/KeeperAcceptance.s.sol:KeeperAcceptance --sig "create()" --rpc-url bsc --account <acceptance-keystore> --broadcast --slow
```

- 默认配置：四通道 40% 市场（进金库）/ 10% 销毁 / 20% LP / 30% 分红，卖税 10%，回购按时间触发、间隔 60 秒、单次上限 0.001 BNB，首次回购在创建 10 分钟后。可用 `ACCEPTANCE_*` 环境变量覆盖，见脚本。
- `ACCEPTANCE_LP_BNB` 示例为 0.05 BNB；池子越浅，单批处理价值越小，但验收配置允许。
- 重跑需更换 `ACCEPTANCE_SALT_TAG`，否则会撞已部署地址。
- 只读核对：`--sig "status()"`（同样需要 `ACCEPTANCE_ALLOW_MAINNET=true`，不带 `--broadcast`）。
- 追加应税成交：`--sig "trade()"`。成交使价格偏离历史锚超过 3% 时，keeper 会跳过规划（不产生交易记录），需等新价格的样本老化到锚窗口内（至少 5 分钟）后才恢复执行。

## 4. 限定处理范围（D1）

以下命令在 `keeper/` 目录执行，`<DB>` 为 `token-launchpad-keeper-mainnet-test`，地址一律小写。

只处理验收代币（新代币被发现时默认 `active`，有其他代币出现时需重跑）：

```bash
npx wrangler d1 execute <DB> --remote --env test --command "UPDATE assets SET status='paused' WHERE token <> '<test-token-lowercase>'"
```

查看资产状态：

```bash
npx wrangler d1 execute <DB> --remote --env test --command "SELECT token, status, last_error, datetime(last_checked_at,'unixepoch') AS checked FROM assets"
```

恢复某个代币：

```bash
npx wrangler d1 execute <DB> --remote --env test --command "UPDATE assets SET status='active' WHERE token='<token-lowercase>'"
```

全部暂停（验收结束）：

```bash
npx wrangler d1 execute <DB> --remote --env test --command "UPDATE assets SET status='paused'"
```

最近的执行记录与暂缓原因：

```bash
npx wrangler d1 execute <DB> --remote --env test --command "SELECT kind, status, tx_hash, substr(detail,1,80) AS detail, datetime(created_at,'unixepoch') AS at FROM transactions ORDER BY created_at DESC LIMIT 20"
```

## 5. 验收矩阵

创建后先等至少 8 分钟（价格锚需要 ≥5 分钟、≥3 个样本）。每条路径达到“通过次数”即视为完成。

| 路径 | 触发条件 | 链上可见结果 | D1 记录 | 通过次数 |
|---|---|---|---|---|
| tax | `status()` 中 `pendingTaxTokens > 0` | TaxProcessor `TaxProcessed`；市场份额进金库（`RevenueReceived`）；分红 `DividendDeposited`；销毁份额转入 `0xdead` | `kind='tax'`、`status='submitted'` 且有 `tx_hash` | 2 |
| liquidity | tax 之后 `lpTokenBalance > 0` 且 `lpQuoteBalance > 0` | `LiquidityAdded`；LP 铸给 `0xdead` | `kind='liquidity'` | 2 |
| buyback | 到达首次执行时间且金库有余额 | 金库 `TokenBuybackExecuted`；`buybackCount` 增加；代币转入 `0xdead` | `kind='buyback'` | 2 |
| 暂停开关 | 把验收代币设为 `paused` | 之后无新交易 | 无新增记录 | 1 |

- D1 `transactions` 只记录提交结果；确认状态保存在 Signer Durable Object 中，不回写 D1。是否成功以 `tx_hash` 的链上回执为准（`cast receipt <hash> status`）。
- 同一轮里多个任务共用一个 nonce 时，后到的任务记为 `busy`，下一轮再执行，属正常现象。
- keeper 自己的卖出批次会压低价格。若下一批的报价低于历史锚减去 `SLIPPAGE_BPS`，模拟会以 `INSUFFICIENT_OUTPUT_AMOUNT` 失败并记为 `skipped`，不花 Gas；价格回升（如回购）或历史锚追上新价格后自动继续。

可选的负向检查（会消耗少量额外 Gas 或成交）：

- **价格保护**：在 keeper 执行前用 `trade()` 做一笔大额卖出，keeper 应跳过该资产（`transactions` 无新增），直到历史锚追上新价格。
- **预算上限**：临时把 `MAX_TOKEN_GAS_PER_WINDOW_WEI` 调到很小，应出现 `token-gas-budget` 暂缓。

想加快回购验证，可直接向金库地址转入少量 BNB（`receive()` 接受任何转账）。

## 6. 结束与回收

1. 全部暂停（第 4 节 SQL），确认不再产生新交易。
2. 用部署账户回收剩余资产（`to` 不能是代币、WBNB、Pair、`0xdead` 等地址）：

   ```bash
   cast send <tax-processor> "temporaryRecoverAll(address)" <team-address> --rpc-url bsc --account <deployer-keystore>
   ```

   ```bash
   cast send <vault> "temporaryRecoverAll(address)" <team-address> --rpc-url bsc --account <deployer-keystore>
   ```

3. 验收账户撤出 LP：BNB 侧可取回，代币侧可能被扣买税。
4. 删除验收环境（在 `keeper/` 目录，删除不可恢复）。如需保留执行记录作为证据，先导出 D1：

   ```bash
   npx wrangler d1 export token-launchpad-keeper-mainnet-test --remote --output keeper-mainnet-test.sql
   ```

   然后依次删除 Worker、Workflow 与 D1：

   ```bash
   npx wrangler delete --env test
   ```

   ```bash
   npx wrangler workflows delete token-launchpad-keeper-mainnet-test
   ```

   ```bash
   npx wrangler d1 delete token-launchpad-keeper-mainnet-test
   ```

   最后在 Cloudflare 控制台确认三项资源都已消失；验收 Keeper 钱包的剩余 BNB 自行转回。
5. 按 `docs/pre-launch-cleanup.md` 完成清理后再做正式部署。

## 7. 成本估算

| 项目 | 估算 |
|---|---|
| Keeper 执行（约 15–20 笔） | 不到 0.001 BNB；硬上限 0.003 BNB/小时 |
| 合约部署 | 视当时 Gas 价格，一次性 |
| 发币、加池、卖出 | 创建费 0.0001 BNB + 若干笔普通交易 Gas |
| 不可回收部分 | LP 手续费、销毁与回购烧掉的代币价值、回购花费的 BNB |
| 可回收部分 | LP 中的 BNB、金库与 TaxProcessor 剩余资产 |
