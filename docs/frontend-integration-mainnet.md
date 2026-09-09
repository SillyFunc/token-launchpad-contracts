# 前端对接文档 — Token Launchpad（BSC 主网）

> 本文只适用于 BSC 主网（chainId `56`）的新部署。测试网地址、测试网时间参数和广播产物请使用 [测试网文档](frontend-integration.md)，不得混用。
>
> **部署地址尚未发布。** TokenFactory、PresaleFactory、CoordinatorFactory、PRESALE 模板和 FlapTaxTokenV3 模板地址只能在部署后，从 `broadcast/Deploy.s.sol/56/run-latest.json` 与链上浏览器核验结果填入；在此之前一律保持 `TBD`。

---

## 1. 网络与地址

| 项目 | 值 |
|---|---|
| 网络 | BNB Smart Chain Mainnet |
| chainId | `56` |
| TokenFactory | `TBD — 以已核验 broadcast 产物为准` |
| PresaleFactory | `TBD — 以已核验 broadcast 产物为准` |
| CoordinatorFactory | `TBD — 以已核验 broadcast 产物为准` |
| PRESALE 模板 | `TBD — 以已核验 broadcast 产物为准` |
| FlapTaxTokenV3 模板 | `TBD — 以已核验 broadcast 产物为准` |

Pancake Router 与 WBNB 不应由前端硬编码：读取已部署
`CoordinatorFactory.routerAddress()`，再读取该 Router 的 `WETH()`。部署前必须链上确认两项调用均成功，且 `factory()` 返回非零地址。

## 2. 主网时间规则

所有时间参数均为秒。前端可展示为小时/天，但写入合约时必须传秒数。

| 参数 | 合法范围 | 说明 |
|---|---:|---|
| `duration` | `1 hours ~ 90 hours`（`3600 ~ 324000`） | 单轮预售持续时间；边界值均允许 |
| `vestingDelay` | `7 days ~ 30 days` | 每期解锁间隔；边界值均允许 |
| `vestingRate` | `5 ~ 20` | 每期释放百分比 |
| `LAUNCH_DEADLINE` | `72 hours` | 预售达标结束后，任何人可触发失败退款的窗口 |

`duration = 300`（5 分钟）和 `vestingDelay < 7 days` 在主网版本都会以
`InvalidDuration` 或 `InvalidVestingDelay` 回退。

## 3. 初始预售与重开预售

首轮由创建者经 `CoordinatorFactory.setupPresale(token, config)` 配置。失败轮次全部退款后，创建者调用
`relaunchPresale()` 回到配置期；推荐以一笔 `setPresaleConfig(config)` 重设下一轮商业条款，再调用
`openPresale()`。

```solidity
struct PresaleRoundConfig {
    uint256 presaleTokenPrice;    // > 0
    uint256 maxPresaleTokens;     // 1 ~ 已冻结的 presaleShare
    uint256 maxBuyPerWallet;      // > 0
    uint256 hardcap;              // BNB wei；0 = 不限
    uint256 minLiquidityAmount;   // BNB wei；> 0
    uint256 softCap;              // minLiquidityAmount ≤ softCap；有 hardcap 时 ≤ hardcap
    uint256 startTime;            // 秒级时间戳；0 = 开售后立即开始
    uint256 duration;             // 1 hours ~ 90 hours
    uint256 vestingDelay;         // 7 days ~ 30 days
    uint256 vestingRate;          // 5 ~ 20
    uint256 slippageProtection;   // 0 ~ 1000 bps；500 = 5%
}
```

`setPresaleConfig` 只可由 Owner 或 Configurator 在 `presaleStatus == 0` 调用。它先校验完整候选配置，
任一字段或交叉约束非法时整笔回滚，不会留下半配置状态。

该入口不能修改下列终身冻结或资金相关状态：

- `creatorShare`、`poolShare`、`presaleShare`
- 预售模式、Token/Pair/Router、Owner 或 Configurator
- 创建者购买注资；创建者购买继续单独通过 `fundCreatorBuy` 管理

现有 `setPresaleTerms`、`setSoftCap`、`setVestingConfig` 和 `setSlippageProtection` 保留兼容；前端新流程应优先使用批量入口。

## 4. 前端 ABI 片段

```ts
const presaleAbi = parseAbi([
  "function relaunchPresale()",
  "function openPresale()",
  "function setPresaleConfig((uint256 presaleTokenPrice, uint256 maxPresaleTokens, uint256 maxBuyPerWallet, uint256 hardcap, uint256 minLiquidityAmount, uint256 softCap, uint256 startTime, uint256 duration, uint256 vestingDelay, uint256 vestingRate, uint256 slippageProtection) config)",
  "function LAUNCH_DEADLINE() view returns (uint256)",
]);
```

`routerAddress()` 属于 `CoordinatorFactory`，不是 PRESALE 实例。对每个代币，使用
`coordinator.tokenPresales(token)` 获得 PRESALE 地址；在提交交易前读取链上状态和当前份额，不能依赖缓存或历史事件。

## 5. 部署发布前核对

1. 从 `.env.example` 创建本地 `.env`，设置受保护的 `PRIVATE_KEY`、`BSCSCAN_API_KEY` 和可信的
   `BSC_RPC_URL`；执行 `forge script script/Deploy.s.sol:Deploy --rpc-url bsc --broadcast --verify`，保存
   `broadcast/Deploy.s.sol/56/run-latest.json`。私钥文件不得提交。
2. 核验所有部署合约源码与 constructor 参数；将核验后的地址填入本文第 1 节。
3. 读取 `coordinator.routerAddress()`，确认 Router 的 `WETH()` 与 `factory()` 调用成功。
4. 读取 PRESALE 模板的 `LAUNCH_DEADLINE()`，确认值为 `259200`（72 小时）。
5. 在链上用最小金额走完整冒烟流程：创建、配置、认购、结算、开盘、领取；重开流程另行验证。

共享的事件、错误码和交易交互说明可参考测试网文档，但当两者存在差异时，本文的主网时间规则与主网部署地址具有最高优先级。
