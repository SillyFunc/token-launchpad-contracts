# SillyFunc Launchpad Keeper

Cloudflare Workers 免费层上的 BSC 税费清算与自动回购执行器。完整的资金流、威胁模型、部署顺序和验收清单见 [`docs/keeper-cloudflare.md`](../docs/keeper-cloudflare.md)。

## 安全边界

- Keeper 仅持有 `KEEPER_ROLE` 与少量 Gas，不得持有 Admin 权限。
- 私钥只通过 `wrangler secret put KEEPER_PRIVATE_KEY` 录入。
- 主网交易必须使用独立的 MEV 保护 `SEND_RPC_URL`。
- HTTP 管理接口不能提交任意交易；Signer 会重新核对 D1 注册表和链上状态。

## 本地验证

```text
pnpm install
pnpm check
pnpm test
```

复制 `.dev.vars.example` 为 `.dev.vars` 后，使用测试专用私钥运行本地 Worker。`.dev.vars` 已被 Git 忽略。

## Cloudflare 资源

- Cron：每分钟触发一次。
- Workflow：发现、采样、规划、执行和可恢复重试。
- D1：资产注册表、历史储备、运行记录、交易和告警。
- SQLite Durable Object：单钱包 nonce 串行化和幂等签名广播。

`wrangler.jsonc` 中的 D1 `database_id` 是占位值；创建 D1 后必须替换再部署。

主网上线时修改 `wrangler.mainnet.jsonc` 中的生产 Keeper 与 D1 占位值，再用 Cloudflare Secrets 录入生产私钥。测试网和主网配置、数据库及私钥不得复用。
