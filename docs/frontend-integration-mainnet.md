# 前端对接文档 — Token Launchpad（BSC 主网）

> 本文只适用于 BSC 主网（chainId `56`）的新部署。测试网地址、测试网时间参数和广播产物请使用 [测试网文档](frontend-integration.md)，不得混用。
>
> **当前正式部署已发布，且 5 个合约均已完成 BscScan 源码验证。** 地址以
> `broadcast/Deploy.s.sol/56/run-latest.json` 和下方浏览器链接为准。后续发布新版本时，
> 必须重新核验并同步更新本文，不能沿用本次地址。

---

## 1. 网络与地址

| 项目 | 值 |
|---|---|
| 网络 | BNB Smart Chain Mainnet |
| chainId | `56` |
| TokenFactory | [`0x04556cBc53C9e994522B008B676958e715545564`](https://bscscan.com/address/0x04556cBc53C9e994522B008B676958e715545564) |
| PresaleFactory | [`0x7a6B4DA821f4B2aDb1432E06E7b7aD2F20972a1A`](https://bscscan.com/address/0x7a6B4DA821f4B2aDb1432E06E7b7aD2F20972a1A) |
| CoordinatorFactory | [`0xc7284F96716E4FbB3f794Cb407D882C29AA653B1`](https://bscscan.com/address/0xc7284F96716E4FbB3f794Cb407D882C29AA653B1) |
| PRESALE 模板 | [`0x6b51064D62018De9832590f1788078bDFB64Aca5`](https://bscscan.com/address/0x6b51064D62018De9832590f1788078bDFB64Aca5) |
| FlapTaxTokenV3 模板 | [`0xd7E12Ecd6406B993D94F0bc67a4a62681f50aA99`](https://bscscan.com/address/0xd7E12Ecd6406B993D94F0bc67a4a62681f50aA99) |

Pancake Router 与 WBNB 不应由前端硬编码：读取已部署
`CoordinatorFactory.routerAddress()`，再读取该 Router 的 `WETH()`。部署前必须链上确认两项调用均成功，且 `factory()` 返回非零地址。

## 2. 主网时间规则

所有时间参数均为秒。前端可展示为小时/天，但写入合约时必须传秒数。

| 参数 | 合法范围 | 说明 |
|---|---:|---|
| `duration` | `1 hours ~ 90 hours`（`3600 ~ 324000`） | 单轮预售持续时间；边界值均允许 |
| `vestingDelay` | `5 minutes ~ 30 minutes`（`300 ~ 1800`） | 每期解锁间隔；边界值均允许 |
| `vestingRate` | `5 ~ 20` | 每期释放百分比 |
| `LAUNCH_DEADLINE` | `72 hours` | 预售达标结束后，任何人可触发失败退款的窗口 |

`duration = 300`（5 分钟）和 `vestingDelay < 5 minutes` 或 `vestingDelay > 30 minutes` 在主网版本都会以
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
    uint256 vestingDelay;         // 5 minutes ~ 30 minutes
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

## 6. 管理员更新平台费用

创建费和地址预留费均由 `CoordinatorFactory.DEFAULT_ADMIN_ROLE` 管理，前端必须继续通过
`creationFee()` 和 `reservationFee()` 动态读取，不能硬编码。管理员可使用
`script/SetPlatformFees.s.sol` 更新两项费用；两个金额均以 BNB wei 传入，且必须非零。

```bash
forge script script/SetPlatformFees.s.sol:SetPlatformFees \
  --sig "run(address,uint256,uint256)" \
  0xc7284F96716E4FbB3f794Cb407D882C29AA653B1 \
  5000000000000000 \
  1000000000000000 \
  --rpc-url bsc \
  --account <FOUNDRY_ACCOUNT> \
  --broadcast
```

上例设置创建费为 `0.005 BNB`、预留费为 `0.001 BNB`。脚本仅对发生变化的费用发送交易；因为已部署合约提供的是两个独立 setter，若两项均变更，将产生两笔管理员交易，并非原子批量更新。广播账户必须拥有该 CoordinatorFactory 的 `DEFAULT_ADMIN_ROLE`。
