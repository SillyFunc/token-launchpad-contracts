# BSC 测试网动态安全回购与 Keeper 冒烟测试

> 网络：BSC Testnet，chainId 97  
> 新 Coordinator：`0x266f95143B983E0aF7368d82eB60354713eCC47B`  
> 当前状态：PASS（BSC 测试网，2026-09-23）。本报告验证了新部署的税收清算、四通道分配、自动加池，以及 TokenBurn 模式动态回购；不代表 BSC 主网已验收。

## 部署与发布核验

- `broadcast/Deploy.s.sol/97/run-latest.json`：15 笔交易、15 个成功回执。
- `script/deployments/97.json` 的十个地址均有链上代码；四个工厂均向新 Coordinator 授予 `COORDINATOR_ROLE`，两个基础设施工厂的 `keeperRegistry` 均指向新 Coordinator；Keeper 拥有 `KEEPER_ROLE`。
- 新 BuybackVault 实现 `0x55DCeAdFCB0742eA4FBf7742877450C0744f41d2` 的运行时代码为 9,066 bytes，与本地编译体积一致。部署者报告 BscScan 源码验证完成。
- Cloudflare Worker 版本 `7ecd515a-122e-4301-8963-660a215e1aea` 已发布；配置指向新 Coordinator，`/health` 返回 `ok: true`。原有两个旧资产仍留在 D1，新旧 Vault ABI 探测兼容逻辑生效。

## 新验收资产与交易

| 对象 | 地址 |
|---|---|
| Token | `0x324e365857C9e18304E9B7606F6A525adADC8888` |
| Presale | `0x28Fc78bFF196A6de582E1E0df988a4b074aB9f0e` |
| Vault | `0x2C2079Dae24BE5dd48680A8152CaAD1F1F2A9478` |
| Pair | `0xAA363Ae0B27A5d81E395C2Cb9447ee5000705DB5` |

| 步骤 | 交易哈希 | 结果 |
|---|---|---|
| 带金库发币 | `0xf820f09575d3e115f2e2ccf2013fcee5715e5e904a560efd7f2686c441707ba0` | `0x1` |
| 领取即上线 | `0x66a510b36377628f32e880a277559a3f4fb9efcac1189566fa36ae9343b7b41c` | `0x1` |
| 授权建池 | `0xac091c813e3b04cc98a01d9a26735c6042aa4e813da9d79fd5029cc701288828` | `0x1` |
| 0.05 tBNB 加池 | `0xe182435483c626b8b76366616e62f2abc7b89119cef8eb3d35439e46ac7bb47e` | `0x1` |
| 授权卖出 | `0x72fb95df78c7a14240c72c5a6971a48302be0851248e4483ddcf2ea8db7a8560` | `0x1` |
| 首次应税卖出 | `0x5581059564cfb7174ad21bf382964531dbaafe6521dbd6bd16af2e37dd27bed1` | `0x1` |
| 第二次应税卖出 | `0x65bf19e1ecdb630a6a2955f00fd1550732c347b85e2214b837a2dcd960680461` | `0x1` |

首次 `create()` 在第二笔确认后被 Windows `os error 1224` 阻断旧广播文件写入。链上两笔已成功，因此使用新增的 `completeSetup()` 和独立 `FOUNDRY_BROADCAST` 目录恢复余下五笔；未重复创建代币。新目录中的 5/5 回执均成功。

建池后两次卖出完成时：Pair 储备约 `450,000,000 Token / 0.030027018311076307 WBNB`；TaxProcessor 待清算税代币 `40,000,000 Token`；Vault 余额为 0、readiness 为 `InsufficientBalance`，符合税费尚未清算的阶段。

## Keeper 自动执行结果

所有下列链上交易回执均为 `0x1`：

| 类型 | 交易哈希 |
|---|---|
| Tax | `0x0be9da840aeb69bb93e947934efedde6f745183cb3d08db9a9bb1da8dc0e1cda` |
| Tax | `0x797aeca2b6327f200b840c4f16739b859dc384d55405ecb7de27eb40cf02ea42` |
| Tax | `0xf6bba14c53b0ff993e5567f34cf47ea46fd929ee9287936d0ea8607dfcff48b8` |
| Liquidity | `0x5daf7526787ea16b0f4518efee6197e17011581afabcdbb38b25e6fbcd50bb69` |
| Tax | `0x4b360caae7908a14fb62067a7ddf36727c69ced3dd41208d1d30c94430c0d773` |
| Tax | `0x883bde348e83c60925ad1c5ce6d83ce30ccb96a53303931720ba97c933e740a4` |
| Tax | `0x5e6fda2dc871e30006f33be143610b716c95ca5dad6ed1deb73e319fa784c87f` |
| Liquidity | `0x85d62c7dc459a669dc3b0822d6d7934ce3ae2f1660d70235efcecd1c02bdbf81` |
| Buyback | `0xd33841ee11ec242cb23f62e894b497b4cb1c4afe17af8bdeb455765febd845d9` |
| Tax | `0x6fb25ef0c96f6e341752a8ddcafaaf00b0a753ca6037ec4a748ed9275c7b2b14` |
| Tax | `0x97bf042368ee3bacb673b7b264455561596073ae43c7142b47bec7ef85577bd4` |

Tax batches briefly paused after price movements: Keeper simulation returned `PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT`, so no unsafe transaction was broadcast. Once the eligible price-anchor samples reflected the new pool state, tax execution resumed. The skip-streak warning for this new token auto-resolved after a successful Tax transaction. Recent Worker runs were `complete` with no run error.

The Liquidity transactions consumed the accumulated LP-token balance; the remaining LP-token balance is zero. Pair LP minted by the tax channel is held at `0xdead`. The Buyback transaction used the dynamically previewed amount and completed in TokenBurn mode; `buybackCount=1`, `totalLpBurned=0` as expected for that configured mode.

## 链上会计快照

在区块 `132627058` 读取到：

| 指标 | 数值 |
|---|---:|
| 累计市场通道转入金库 | 0.000289016263272990 BNB |
| 累计回购花费 | 0.000192806668750193 BNB |
| 回购后金库余额 | 0.000096209594522808 BNB |
| Buyback 次数 | 1 |
| 回购买入并销毁 | 2,793,215.236758778516186549 Token |
| 累计税收直接销毁 | 1,223,891.711664160742622599 Token |
| TaxProcessor 累计分红入账 | 0.000216762197454741 WBNB |
| TaxProcessor 累计加池 Token | 1,101,502.540497744668360340 Token |
| TaxProcessor 累计加池 WBNB | 0.000071932048864089 WBNB |
| TaxProcessor 待清算税 Token | 37,761,082.883358392573773983 Token |
| LP Token 待加池 | 0 Token |
| LP WBNB 零头待用 | 0.000000322016954155 WBNB |
| Token 合约 `0xdead` 余额 | 4,017,106.948422939258809148 Token |

四通道余额已按比例流转：市场累计值与“已回购 + 金库余额”相差 11 wei；分红、加池和直接销毁通道均有非零链上累计值。Token 的 `0xdead` 余额与税收直接销毁加回购销毁之和一致。LP WBNB 剩余值为极小零头，等待未来 LP 通道额度继续累积后使用。

待清算税 Token 尚有约 3,776 万枚，Keeper 会继续按储备上限分批处理；本次验收不要求清空全部税队列。新金库余额低于下一次经济执行下限时会继续积累，当前不需要人工触发。

## 最终验收结论

- 新部署的 BSC 测试网端到端验收通过：税收清算 → 四通道分配 → LP 加池 → 金库积累 → 动态金额回购销毁。
- 新 Vault 的动态金额低于旧配置上限，并受金库余额与 Pair 储备 1% 双重约束；真实 Keeper 回购已执行成功。
- D1 中仍有一个已知旧资产告警：旧固定金额 Vault `0x226761d49e8a8bd80ddeacd4d0b23a604ab88888` 超过储备上限。它不是本次新 Vault，且旧 Clone 不可升级。
- 主网上线前仍需单独完成生产部署、Keeper/RPC 与运维检查；LP 买回模式（BuybackMode.LpBurn）也未由本次 TokenBurn 配置的测试代币覆盖。
