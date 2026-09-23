# BSC 测试网四通道税收与 Keeper 冒烟测试需求

> 历史说明：本文对应 2026-09-22 固定金额 Vault 部署，最终结果为 FAIL。仓库现已实现动态安全执行额，但新地址尚未部署；复验时必须使用新广播地址和四参数 `executeBuyback` ABI，不得复用下表旧地址。

> 交接日期：2026-09-22  
> 网络：BNB Smart Chain Testnet，chainId `97`  
> 目标：由接手 Agent 独立完成测试、取证和报告；除无法解锁部署 keystore 外，不要求用户执行命令。

## 1. 当前已完成状态

- `Deploy.s.sol` 已完成 15 笔广播，`15/15` 回执成功。
- 十个部署合约均存在链上代码，并已在 BscScan 完成源码验证。
- Keeper Worker 已重新部署：`https://sillyfunc-launchpad-keeper-testnet.wildfunc.workers.dev`。
- `/health` 已返回 `ok: true`。
- 切换新 Coordinator 后最近 5 次 Cron 均为 `complete`、`error = null`，未解决告警为 0。
- D1 当前保留 1 个旧版测试资产。不得删除；本次测试必须按新验收 Token 地址过滤证据。

当前部署地址以 `script/deployments/97.json` 为准：

| 合约 | 地址 |
|---|---|
| CoordinatorFactory | `0x599146E6c5cCC44f54D27473B1FfD49a3A11634F` |
| FlapTaxTokenV3 implementation | `0x625f636aC8570F33a1E7a16ddD03c48aa2a44cBD` |
| TokenFactory | `0xA5C0f01F5426fA2369e5EceF8173Ee97F4A4a782` |
| PRESALE implementation | `0xe2cd0001E5a1f16466c14BEb02f355cc89f501ab` |
| PresaleFactory | `0xe59f95da410a9F4EF681F5D427e7C44745611405` |
| TaxProcessor implementation | `0x3A0c1f58838f07bC5Ecf2Fc40C9F174E61ff548e` |
| Dividend implementation | `0x68Cd5cb9E43893a87a60785027904267A12D9AbC` |
| TaxInfrastructureFactory | `0xDaABC64bb04c64fD60d076e1B540439b8fD068ED` |
| BuybackVault implementation | `0x40A5Dbe57c140a7dC36751A6E4db13e8084C6C8F` |
| BuybackVaultFactory | `0x83EA50F92c9f6fE9e2e245704364af37b6096254` |
| Keeper EOA | `0x9f87b1973361b23387D7F1b536484543a5ea1eFB` |

## 2. 测试原则与边界

1. 只允许在 chainId `97` 执行，不得触碰主网。
2. 不修改或重新部署业务合约；发现失败先定位根因并保留证据。
3. 不输出、提交或在聊天中粘贴私钥、keystore 密码、`ADMIN_TOKEN`、API key。
4. 不清理 D1、Durable Object、旧资产或广播记录；任何破坏性操作必须由用户另行授权。
5. 不把 `forge test`、Mock 或 fork 结果当作本次真链冒烟测试的替代品。
6. 若唯一阻塞是 keystore 交互式密码，只记录这一项人工动作；不要要求用户手工执行其余检查。

## 3. 预检（全部只读）

接手 Agent 应自行执行并记录结果：

```bash
forge test
pnpm --dir keeper check
pnpm --dir keeper test
curl -sS https://sillyfunc-launchpad-keeper-testnet.wildfunc.workers.dev/health
```

必须确认：

- `broadcast/Deploy.s.sol/97/run-latest.json` 为 15 笔交易、15 个成功回执。
- 十个地址 `eth_getCode != 0x`。
- Coordinator 保存的 `taxInfrastructureFactory`、`buybackVaultFactory` 与部署文件一致。
- 四个工厂均向当前 Coordinator 授予 `COORDINATOR_ROLE`。
- 当前 Keeper 拥有 Coordinator 的 `KEEPER_ROLE`，但没有 `DEFAULT_ADMIN_ROLE`。
- Router 为 `0xD99D1c33F9fC3444f8101754aBC46c52416550D1`。
- `TAX_DURATION == 3153600000`，`MAX_ANTI_FARMER_DURATION == 31536000`。
- Keeper EOA 的 tBNB 余额足以支付后续自动交易 Gas。

若本机能安全取得 `ADMIN_TOKEN`，额外验证：

```bash
curl -sS \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://sillyfunc-launchpad-keeper-testnet.wildfunc.workers.dev/admin/status
```

期望 `chainId = 97`、Coordinator 和 Keeper 地址与上表一致。拿不到本地管理令牌时，不得尝试读取 Cloudflare Secret 明文；把该项单独标为“需要用户持有的 token”，但不得阻塞其余冒烟测试。

## 4. 创建真链验收资产

使用 `script/KeeperAcceptance.s.sol`。脚本会在同一批广播内完成：

1. 创建 13 字段四通道代币和预售克隆；
2. 创建 TaxProcessor、Dividend、BuybackVault 克隆；
3. 纯发币领取并上线；
4. 添加 Pancake V2 流动性；
5. 连续两笔应税卖出，使税代币超过动态清算阈值。

执行前先读取广播账户余额。默认脚本需要约 `0.205 tBNB + Gas`；余额不足时，不要盲目执行。可将 LP 金额降至 `0.05 tBNB`，但保留默认 `300,000,000` LP Token、两轮各 `100,000,000` Token 卖出，以确保产生足量税费：

```bash
export ACCEPTANCE_LP_BNB=50000000000000000
export ACCEPTANCE_SALT_TAG="keeper-four-channel-$(date +%s)"

forge script script/KeeperAcceptance.s.sol:KeeperAcceptance \
  --sig "create()" \
  --rpc-url bsc-testnet \
  --account launchpad-testnet-deployer \
  --legacy \
  --broadcast \
  --slow

unset ACCEPTANCE_LP_BNB ACCEPTANCE_SALT_TAG
```

严禁复用已经使用过的 `ACCEPTANCE_SALT_TAG`。广播成功后，以
`script/deployments/97-keeper-acceptance.json` 记录的 Token、Presale、Vault、Pair 为本次测试唯一资产集合。

## 5. 即时验收（创建交易确认后）

必须验证并记录：

- Token 地址尾号为 `8888`。
- Token、Presale、TaxProcessor、Dividend、Vault、Pair 均有链上代码。
- `antiFarmerDuration=0` 时 `poolState == 3`（TaxEnforced），Pair 储备非零。
- `taxProcessor()`、`dividendContract()`、`tokenVaults(token)` 均非零且互相接线一致。
- 买税为 500 bps、卖税为 1000 bps；`taxExpirationTime` 约为创建时间加 100 年。
- Token 合约或 TaxProcessor 中存在待处理税资产，且两笔卖出均成功。
- 四通道配置为：市场 4000、直接销毁 1000、LP 2000、分红 3000 bps，总和为 10000。
- Vault 模式、触发模式、单次 `0.001 tBNB` 回购上限正确；同时核对 `previewBuyback()` 的实际安全输入与 readiness。
- 用户交易没有在卖出路径中内联执行税费兑换。

只读状态命令：

```bash
forge script script/KeeperAcceptance.s.sol:KeeperAcceptance \
  --sig "status()" \
  --rpc-url bsc-testnet
```

## 6. Keeper 异步验收

### 6.1 税费清算与四通道分配

等待至少 8 分钟，使每分钟 Cron 建立满足 5 分钟最小年龄的价格锚点。期间不得再次交易或操纵 Pair。

必须看到：

- D1 发现新 Token，`assets` 中出现对应 Token/TaxProcessor/Vault/Pair。
- `keeper_runs` 持续为 `complete`，不存在该 Token 的未解决告警。
- `transactions` 出现该 Token 的 `tax` 提交并最终上链成功。
- TaxProcessor 的 `pendingTaxTokens` 下降。
- 直接销毁通道增加 `0x000000000000000000000000000000000000dEaD` 的 Token 余额。
- 市场通道的 quote 进入 Vault。
- LP 通道账本产生 Token/quote，并由 Keeper 执行加池；LP 接收者必须是 `0xdead`。
- Dividend 获得 WBNB；无有效份额或存款失败时，资产必须留在可重试待处理账本，不得丢失。
- 四通道资产变化按实际 swap 输出守恒；不得按名义输入错误记账。

### 6.2 自动回购

默认 `firstExecuteAt` 为创建后约 10 分钟，因此完整验收应等待 12–15 分钟，而不是只等待 8 分钟。

必须看到：

- `transactions` 出现该 Token 的 `buyback` 提交并成功上链。
- Vault 的 `buybackCount` 增加。
- Vault 的 `totalBuybackBNB` 增加，实际花费不超过单次配置。
- calldata 中的 `expectedBnbIn` 等于报价时 `previewBuyback()` 返回值；若储备变化则安全回滚并由下一轮重新报价。
- `totalBurnedToken` 增加，且与 `0xdead` 的 Token 增量相符。
- 回购执行使用 keeper 权限、有效 deadline 和非零最低输出。

## 7. D1 取证命令

所有查询必须按验收 Token 地址过滤，避免把旧版资产误算进结果：

```bash
pnpm --dir keeper exec wrangler d1 execute DB --remote --json --command \
  "SELECT * FROM assets WHERE token=lower('<TOKEN>')"

pnpm --dir keeper exec wrangler d1 execute DB --remote --json --command \
  "SELECT id,status,discovered_count,inspected_count,planned_count,submitted_count,error FROM keeper_runs ORDER BY started_at DESC LIMIT 20"

pnpm --dir keeper exec wrangler d1 execute DB --remote --json --command \
  "SELECT job_id,kind,status,tx_hash,nonce,detail FROM transactions WHERE token=lower('<TOKEN>') ORDER BY updated_at"

pnpm --dir keeper exec wrangler d1 execute DB --remote --json --command \
  "SELECT severity,code,message FROM alerts WHERE resolved_at IS NULL"

pnpm --dir keeper exec wrangler d1 execute DB --remote --json --command \
  "SELECT block_number,sampled_at,reserve_token,reserve_wbnb FROM price_samples WHERE token=lower('<TOKEN>') ORDER BY sampled_at"
```

## 8. 失败判定

以下任一项属于冒烟测试失败，必须停止宣布上线成功并报告根因：

- 新 Token 未被 Keeper 发现，或 Cron/Workflow 持续失败。
- 税费资产无法闭环、永久滞留或账本与实际余额不一致。
- 四通道比例或最终收款方错误。
- 公开调用可绕过 Keeper/Coordinator 权限。
- 清算或回购 `minOut = 0`、deadline 失效，或出现明显 MEV/价格边界缺失。
- LP 未铸给 `0xdead`，Dividend/Vault 收到错误资产。
- D1 重试导致同一 job 重复发送、nonce 冲突或重复记账。
- Keeper 处理了错误 Token、错误 TaxProcessor 或错误 Vault。

## 9. 最终交付物

接手 Agent 必须输出一份简洁报告，至少包含：

1. PASS/FAIL 总结和执行时间（UTC 与 UTC+8）。
2. 验收 Token、Presale、TaxProcessor、Dividend、Vault、Pair 地址。
3. 创建、两笔卖出、税费清算、LP、回购交易哈希及回执状态。
4. 四通道处理前后余额、待处理账本和销毁量对照。
5. D1 对应资产、运行、交易、价格样本和告警证据。
6. 所有失败、重试和未完成项；不得把“暂无触发条件”写成 PASS。
7. 是否可以让 DApp 面向测试用户开放四通道创建功能的明确结论。

若测试全部通过，同步更新 `docs/keeper-cloudflare.md` 的真链证据；若失败，只记录事实和根因，不擅自改变合约业务语义或重新部署。
