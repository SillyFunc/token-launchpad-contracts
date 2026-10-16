# 自动维护、Reader 与资金回收设计

状态：pending deployment。以下为 2026-10-16 的源码改造，不代表旧主网地址已支持新接口。当前测试阶段只交付一个 BuybackVault 实现，包含创建者 BNB/WBNB 提款；未来正式上线时重新部署，不再维护测试与正式两套实现、部署模式或验收记录。部署成本优先：继续使用 EIP-1167 克隆；全平台只部署一个 Reader；调度在 Keeper 中完成。

## 资产与执行规则

税代币由代币模板转入 TaxProcessor 后入队；清算分配市场、销毁、LP、分红份额，LP 代币和 WBNB 分别保留在现有账本。市场收入进入 Vault，按原有 TokenBurn / LpBurn 路径消耗。失败整笔回滚，LP 失败沿用原有原子回退。取消固定 0.0001 BNB 下限，仅保留正整数输入、1% WBNB 储备上限、独立最低输出与期限；极小输出不足时仍须回滚，不能虚记成功。

Coordinator 使用一个 uint8 executionFlags 位图：tax=1、liquidity=2、buyback=4，初始为7。管理员通过 setExecutionControls(bool taxProcessingEnabled,bool liquidityEnabled,bool buybackEnabled) 一次更新，三个 false 即全停，不另增第四个状态。每次变更发 ExecutionControlsUpdated(uint8)。Keeper 无管理权限。该权限允许管理员暂停自动化，不授予提款权。

TaxProcessor.processPendingTax/processPendingBurn 检查 tax；addPendingLiquidity 检查 liquidity。Vault.executeBuyback 检查 buyback，LpBurn 还在 try/catch 之前检查 liquidity。被暂停的维护入口不转移资产、不改冷却/次数/累计额；收税入队、固定收款人 dispatch、正常交易与分红领取保持可用，同时关闭 tax 与 liquidity 后额外开放下述 TaxProcessor 创建者结算。注册中心调用失败时禁止执行，不允许吞错后放行。恢复后按现有余额重新报价，保持原 Gas 预算、冷却和批次限制。

保留 Keeper 角色限制、十分钟期限、非零最低输出、实际到账/退款记账。即时储备只限制量级和提供状态，不替代 Keeper 的历史价格锚点及抗操纵边界。已广播交易与暂停有排序竞争：暂停先上链时执行回滚，Gas 不退；Keeper 的读取与模拟只能减少此风险，不能消除。

## 创建者回收

当前 BuybackVault 通过单个 `withdrawAll(address payable recipient)` 提取全部 BNB/WBNB，沿用原有 initializer 和 Factory。创建者通过既有 Coordinator.tokenCreators(token) 原始创建记录确定，不能随预售 owner 变化，不增加 creator 存储或初始化参数。仅该创建者可将自己金库执行时的两种资产余额全部转至指定非零、非自身地址；明确覆盖税金与注资，不为“只退本金”引入额外会计。WBNB 原币转出，不解包为 BNB；前端不需填写金额或安排两次提款。

简短威胁模型：入口只接受原始创建者调用，信任固定 Coordinator 的创建记录与既有 WBNB 合约；注册中心读取失败时拒绝提款。先读取 BNB/WBNB 余额，并将两项累计提款量记账，再依次转出非零 WBNB、非零 BNB；仅对实际非零转账发对应资产事件。两种余额均为零时成功无操作，不发事件。转账或接收者回调失败时，前序转账、累计量和事件整笔回滚；提款与回购共用重入保护，接收者回调不能再次提款或执行回购。累计量只反映成功转出的对应资产，不把 WBNB 与 BNB 混算。入口不进行 DEX 交易或价格换算；排序竞争只决定提款与回购谁先消费余额，不授予第三方资金权限。若接收者在回调中主动返还资产，该新增余额留待下一次提款，不能通过循环清空扩大回调面。

提款不推进回购冷却或统计。提款先执行导致旧回购预算不足时，回购必须回滚重新报价。提款不受三个自动化开关限制，Keeper/管理员角色本身不授予提款权。部署只使用现有 Deploy 脚本与按 chainId 区分的记录；前端必须明确创建者可提款，不能把本版金库宣传为不可撤回。

## TaxProcessor 暂停结算设计与威胁模型

2026-10-16，用户明确授权：待加池资产与尚未进入 Dividend 的分红资金全部归原始代币创建者。以现有 `TaxProcessor.withdrawAll(address recipient)` 入口实现受控结算，不新增永久关闭状态、控制器、部署模式或 Reader 字段。以下为编码前确定的设计，实际验证结果须在实现后单独记录。

权限与开关：仅 `Coordinator.tokenCreators(taxToken)` 登记的原始创建者调用；Keeper 或管理员角色本身不授予提款权。执行前必须同时关闭 TAX 与 LIQUIDITY 位，BUYBACK 位可独立保持开启；未同时关闭则 `TaxProcessingActive()`。这复用的是平台全局暂停，**任何临时暂停也会向所有代币的原始创建者开放这项结算权**，不能对外描述成只有永久下线才能退出。管理员若重新开放，可用后续新入账余额继续运营；已合法结算给创建者的资产不恢复。

| 来源或账本 | 暂停结算的资产与终态 |
|---|---|
| 当前未预留的待清税代币 | 使用现有 `_splitTax` 的 fee、commission、market、burn、LP、dividend 比例及舍入规则拆分，不经 DEX |
| fee / commission / market 原始税代币份额 | 原币发往原固定收款人；若该收款人恰为 Coordinator 登记的非零本币 Vault，则改发同一创建者指定的 recipient，避免把 Vault 无法取回的税代币转入其中。普通收款人归属不变 |
| burn 税代币 | 原币发送 dead，仅增加实际 `totalTaxTokenBurned` |
| 已预留 `lpTokenBalance` 与新拆出的 LP / dividend 税代币 | 原币发创建者指定 recipient，无需凑齐 LP 双边或等待分红持有人出现 |
| `feeQuoteBalance` / `commissionQuoteBalance` / `marketQuoteBalance` | quote 原币发往原固定收款人；WBNB 不解包，进入 Vault 的 WBNB 可再由创建者调用 Vault.withdrawAll |
| `lpQuoteBalance` / `pendingDividendQuoteTokenBalance` / `dividendTokenBalance` | quote 原币发创建者指定 recipient；不增加 LP 成功量、分红已派发量 |
| `pendingDeflationQuoteBalance` | quote 原币发 dead，只计入 `totalQuoteBurned`，不得伪装成已买入并销毁税代币 |
| 原生 BNB 与非账本捐赠 | 先将 BNB 包装成 WBNB；quote 为 WBNB 时沿用 donation 规则计入 fee 账，quote 非 WBNB 时额外 WBNB 原币发 feeReceiver；quote 的超账余额同样归 feeReceiver |
| 已进入 Dividend 的资产与持有人权益 | 留在 Dividend，按现有领取路径履行；本入口不调用 Factory 的 emergencyWithdrawDividend，不挪用已入账权益 |

会计与失败路径：先核对税代币余额覆盖 `lpTokenBalance`、quote 余额覆盖全部 quote 账本，完成 BNB 包装与捐赠归账，再快照本批金额。转账前清零所有已结算余额及 `pendingDirection`，按实际通道更新固定收款 quote 派发累计量、市场派发累计量与原币销毁累计量；创建者退出不得增加 LP 或分红运营统计。每笔非零资产转出发 `TaxAssetsWithdrawn(creator,asset,recipient,amount)`，其中 amount 是处理器实际转出的资产最小单位数。注册中心、WBNB 包装、任何 ERC20 转账或接收方回调失败均整笔回滚，不能清账后吞错继续。共用 `nonReentrant` 阻止提款与其他维护/派发入口交叉重入；接收方在回调中新增转入的资产由下一次结算处理，不循环清空。

外部依赖与攻击面：信任固定 Coordinator 的创建者、Vault 登记和控制位，信任配置的 WBNB 与既有税代币；任何核心读取失败均拒绝执行，无管理员后备授权。入口只做原币分配、不执行 swap/mint、没有储备或价格输入，因此不依赖 AMM 深度，也不给闪电流动性或抢跑报价提供套利入口。创建者指定 recipient 拒绝零地址、处理器自身、税代币、Dividend、router、quote、WBNB 以及税代币登记的所有 pool，防止转入交易入口导致扣税或回调；也拒绝 Coordinator 登记的本币 Vault，防止归创建者的原始税代币再次转入无对应提款出口的 Vault。每笔非零转出还会对实际固定收款人执行前述危险地址检查，失败同样报 `InvalidTaxWithdrawalRecipient()`，而非仅校验用户填写的 recipient；固定 quote 通道向本币 Vault 分配仍允许，raw 税代币通道则按上述规则改发创建者。固定收款人归属仍按既有配置处理，配置无效、接收者拒收或资产合约失效可能导致整体回滚，不能承诺任意外部合约故障下仍可退出。

长期不变量：每一笔快照资产仅能分配一次；结算拆分总额等于实际持有的税代币总额；quote 出账总额等于已记账余额加捐赠；暂停结算只变更 TaxProcessor 内的资金，不减少 Dividend 对持有人的负债。现有 `processTaxTokens` 在暂停期间仍可入队，创建者可反复结算后续税；`dispatch()` 也继续有效，交易排序可能决定某笔尚未分配分红先进入 Dividend，进入后即不能再由本入口取回。验证应覆盖权限、暂停组合、单边 LP、零持有人分红、捐赠、后续入队、原币/Vault 收款差异、转账失败原子回滚及重入，并以真实 BSC 税代币/WBNB 或可信状态化 AMM 证明退出不误走交易。

本设计已完成实现与下述资金回归，补齐已识别的 TaxProcessor 受控资产终态。新接口仍为 pending deployment，需新部署核验后接入；不能将源码验证视为旧实例已支持退出。它不是任意 ERC20 救援器，不覆盖未知第三方资产、失效外部资产合约、旧实例升级或已销毁资产恢复。已经销毁的代币与发送至 dead 的 LP 是预期不可逆终态。

## Reader 与 Keeper

独立 Reader 固定绑定 Coordinator，只读、不持有资产、不需要 Keeper 角色。getTokenSnapshot(token) 返回命名 struct：schemaVersion、blockNumber、blockTimestamp、contracts、controls、pool、tax、liquidity、buyback。contracts 包括 token/pair/taxProcessor/vault/wbnb；pool 包括双边储备、LP总量、token池状态/买卖税率/税期；tax 包括 pendingAmount 与 feeConfigV2；liquidity 包括 pendingToken/pendingWbnb；buyback 包括 BNB余额/可执行额/模式/就绪原因/下一执行时间。核心读取失败明确报错，不伪装零值。无金库由零地址明确表示。

Reader 只支持本次新版 Coordinator；新 ABI/Reader 地址均 pending deployment，旧地址继续使用原有批量读取适配。Keeper 以可选 READER_ADDRESS 启用 Reader，新版控制读取须明确版本配置，不通过 catch 任意错误猜测成旧版。返回对象不构成报价承诺，签名前仍重取最新状态、独立历史价格校验、模拟和 Gas 检查。

maintainToken 放在 Keeper，按 tax → liquidity → buyback 串行安排需要且经济的任务。任何资金任务尚未确认时停止该代币后续步骤，留给下轮持久化流程继续；不能为了单次函数返回阻塞等待链上。每步确认后重读、重算、沿用持久化去重与预算；不在旧快照上同时预制三个报价。不新增链上批处理、任意目标 call、delegatecall、资金托管或授权。

## 验证与发布边界

先红测再实现：小池真实成交；零/1wei及LP整数边界；三个开关组合与管理员权限；LP暂停不触发fallback；关闭后队列与余额守恒、恢复可用；金库创建者权限、双资产/单资产全部提款、双零无操作、暂停可退、WBNB 已转出后 BNB 失败的原子回滚、回调重入与统计守恒；Reader字段与原 getter 一致、错误不伪装零；Keeper暂停跳过、按步重读、未确认停止、旧版适配与Gas预算不被绕过。至少执行BSC/Pancake fork或等价可信状态化AMM验证关键资金路径。

旧 clone 实现固定、Factory implementation immutable、旧 Coordinator 工厂接线仅一次。本次不能升级旧实例或取出旧金库资金。保持现有 broadcast/、默认地址与旧 ABI 的部署含义，新接口无可用地址；更新前端文档并另行部署核验后才可切换配置。记录合约大小、部署Gas估计，不以改编译器/删除保护来换取成本。

## 验证与成本度量记录

2026-10-16，TaxProcessor 暂停结算完成后的本地全量 Solidity 回归为 310 项通过、0 失败、3 项未配置 fork 显式跳过，包含 3 个不变量测试（每项 256 轮、128000 次调用）。26 项退出测试覆盖单边 LP、未分配分红、六通道税代币与七项 quote 账本守恒、BNB 包装、捐赠、危险接收地址、登记 Vault 分流、资产重叠、账本不足、失败回滚、重入及转账回调中新入税留待下次结算。真实 Coordinator + FlapTaxTokenV3 + Dividend 集成验证原持有人在退出后仍可领取已分配分红，新收到退出代币的地址不能追领历史分红，Reader 也同步反映清账结果。

另使用公开 BSC RPC 在主网区块 `127905381` 运行两项真实 Pancake V2 fork 并通过。金库测试验证 `0.001 WBNB` 小池的 TokenBurn 与 LpBurn，以及 BNB/WBNB 一次提款。TaxProcessor 测试先以真实 Pancake 兑换产生待加池双边库存与零份额时的待分红，再验证全部库存的原币分账、`0.003 BNB + 0.002 WBNB` 捐赠归属、Dividend 原余额不动与运营统计；恢复开关后再次真实清算成功。所有 fork 交易均本地模拟，无链上广播。

同一维护改造中，此前 Keeper 的 116 项测试、TypeScript 类型检查通过，覆盖无操作轮次仅一次快照、暂停不报价、未确认停止后续动作、签名前重检、读取失败拒签和原 Gas 预算。SDK ABI 已与 `out/Reader.sol/Reader.json` 逐项核对嵌套字段、类型和顺序一致；本次 TaxProcessor 结算没有修改 Keeper 或 Reader ABI。

下表使用 TaxProcessor 结算完成后的编译产物（Solidity 0.8.35、optimizer runs=200）。旧部署基线通过 `script/deployments/56.json` 所列地址的主网 `eth_getCode` 只读核对。这不是部署总费用对比。

| 合约 | 旧部署 runtime bytes | 新版 runtime bytes | 差值 |
|---|---:|---:|---:|
| CoordinatorFactory | 18189 | 18513 | +324 |
| TaxProcessor | 13581 | 16210 | +2629 |
| BuybackVault | 9066 | 10411 | +1345 |
| Reader（全平台一个） | 无 | 4398 | +4398 |

三个执行位与原有 router/factoryEnabled 同槽，不为每个代币新建控制器或 Reader；通过已有创建记录识别提款人，不增加初始化参数或 creator 存储。`ExecutionControls` 是内联库，不需要独立部署。上述合约均低于 EIP-170 的 24576 字节限制。

本轮 `forge test --summary --gas-report` 的本地创建开销：Coordinator `4291124 gas`、TaxProcessor 实现 `3580294 gas`、统一 Vault 实现 `2348966 gas`、共享 Reader `1013841 gas`。相比仅含暂停控制的版本，结算出口使共享 TaxProcessor runtime 增加 2324 字节，对应实现构造路径增加 `501999 gas`；没有新增每币状态字段或部署合约。相比两个独立提款入口，单个 `withdrawAll` 使 Vault runtime 减少 169 字节，对应实现构造路径减少 `36574 gas`。这些仅为对应构造路径的模拟度量，不是单次回购 Gas 或已支付费用；实际费用还需包括其余部署、授权交易并乘部署时 Gas price。单一部署脚本写入 `script/deployments/<chainId>.json`；验收脚本按该网络记录选择目标，仍须核对 Coordinator 与代币、预售仓、金库的链上归属。
