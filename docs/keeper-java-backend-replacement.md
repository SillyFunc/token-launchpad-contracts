# Java Keeper：按原代码上下文修改

本版重新以你上传的两个原文件为基线。完整替换文件：

- [BuyBackScheduleManager.java](examples/backend-replacement/BuyBackScheduleManager.java)
- [EthContractService.java](examples/backend-replacement/EthContractService.java)
- [逐项代码差异](examples/backend-replacement/changes.diff)

## 1. 原调用流程

```text
buyBackValueInitJob：原 @Scheduled 每 30 秒
  → getAssets
  → 更新 assetMap
  → 补充只读 samplePool
  → 原 taxClear

checkAndStartSch：原调用方启动
  → loadAndStartAllBuyBackTask
  → scanNewTask 每 3 秒发现新增任务

scheduleNextRun：原递归延迟调度
  → 首次按 firstExecuteAt
  → executor 执行原 addLiquidity、buybackJob
  → 成功回执后更新 lastExecuteAt
  → finally 按原 intervalSeconds 调度下一轮
```

继续使用原 EthCommonContract、EthCommonContractUtil、EthCommonUtil、StaticGasProvider、Asset、Reserves 和 Sample。价格窗口仍然是原来的内存 Map<String, Deque<Sample>>，保留 1 小时、至少 3 条样本、原中位数算法、3% 偏差与 1% 滑点。

上一版新增的文件锁、待确认状态文件、5 秒统一轮询、Snapshot/PendingTx 类均已撤掉。

## 2. 本次修改

### BuyBackScheduleManager

1. 私钥字段沿用原定义，值为 `替换为Keeper钱包私钥`。
2. taskFutureMap 从 HashMap 改为 ConcurrentHashMap，适应原有多线程访问；启动和调度入口加 synchronized，避免并发覆盖调度状态。
3. assetMap 存取统一小写，修复链上地址与数据库地址大小写不同导致查不到资产。
4. 在原 30 秒初始化循环里补一次只读储备采样，避免没有待清算税费时不能积累历史。
5. 增加一个内存 attemptedTaskIds 集合。首次已经尝试但跳过或报错，下一轮仍按原 intervalSeconds 等待，不再立即递归空跑。这个集合只标记“尝试过”，不记录成功。
6. 延迟任务实际运行前重新读取开关与代币启用状态。
7. 只有 buybackJob 返回非空哈希才更新 lastExecuteAt；此时 send 已检查成功回执。记录的是原有本地时钟的确认时间。
8. 原先吞掉的异常补充日志；关闭线程池后不再递归提交新任务。

### EthContractService

1. 税费、加池、回购、采样与 send 方法增加 synchronized。继续使用原线程池与服务实例，同实例的实际链上操作串行执行。
2. 新增一个简单 samplePool 方法，沿用原 SDK 包装器调用已有 reserves，不发送交易。
3. reserves 的窗口键统一小写，同池每 60 秒最多保存一条，防止税费/加池/回购连续读三次就凑满历史。
4. buybackJob 先采样，再判断 readiness；主分支的当前报价与历史报价都扣买税后计算 minTokenOut。
5. LP 回购分支也使用现有 anchorQuote 与 protectedMinOut 检查历史报价。
6. protectedMinOut 取当前和历史报价中更高的保护下限，避免降低历史价格保护。
7. simulate 检查 RPC error；executeBuyback 成功的 `0x` 按无返回值处理。
8. send 检查 nonce、估算、Gas 单价和广播的 error/result，保留真实回滚原因。
9. send 使用 Web3j 自带 PollingTransactionReceiptProcessor 等待回执：每 1.5 秒查一次，最多 40 次，约 60 秒加 RPC 耗时。成功回执返回原 txHash；回滚或等待失败抛出包含哈希的异常。
10. 原业务异常包装保留 cause，便于定位 SDK/RPC 的真实错误。

## 3. 替换方式

覆盖后端对应的两个类。原包名和现有公开方法签名继续保留；私钥在调度器这一行交给 Java 人员处理：

```java
private final static String privateKey = "替换为Keeper钱包私钥";
```

继续使用原来的链配置、合约地址、数据库开关与任务表。原 checkAndStartSch 的调用方也继续保留，本版没有另加启动入口。初始化开关 buyBackValueInitJob 需要开启，才能加载资产并持续采样；回购开关为 buyBackLoadJob。

不需要 keeper.private-key 配置，也不需要创建 pending-file。压缩包中的 README 和代码已经按这个版本更新。

## 4. 副作用与边界

- **预热约 2 分钟或更久。** 第一条采样后，还要再积累两条间隔至少 60 秒的样本。沿用原“至少 3 条”规则，没有新增上一版的“至少 5 分钟年龄”要求。RPC 或调度延迟可能延长预热。
- **多一些 RPC 读取。** 原初始化循环新增采样；send 新增 nonce 和回执查询。只读调用不消耗链上 Gas。
- **send 会等待回执。** 与原来“广播返回就结束”不同，通常约 60 秒加 RPC 耗时仍无回执会报等待失败；同一服务实例的其他交易与采样可能等待这把锁，因此实际运行会比精确配置时间晚。
- **价格保护更严格。** 取更高最低输出和 LP 历史检查，价格变化时可能跳过或模拟失败；原滑点仍是 1%。
- **lastExecuteAt 更准确。** 跳过、异常、失败回执不会更新。已有错误记录不自动清洗，后续成功回购覆盖。
- **等待回执失败并不证明交易失败。** 可能是 RPC 超时或交易仍 pending。异常保留 txHash 供查询；send 的 pending nonce 检查会阻止本节点已知在途交易时继续发送。
- **保留原应用边界。** 没有跨进程钱包锁、原始交易持久化和重启回执补记；请由一个实例使用该 Keeper 钱包，并停掉旧 Worker。重启丢失内存样本并重新预热，超时或重启期间的交易需要按哈希核查。
- **原税费分流与 TaxProcessor 自动加池报价仍沿用上传代码。** 本次重点修回购与调度问题，不再扩大修改。若设置了直接销毁或 LP 税收分配，原 taxClear 用整批数量报价、原 addLiquidity 按名义代币配比的逻辑仍可能导致模拟/执行失败；需针对该配置单独修正。你当前 50% 金库、50% 分红、LP=0 的测试不走这些分支。

资产与执行边界：发送仍附带 value=0；Keeper 支付 Gas，回购 BNB 由金库支出，代币销毁/分红/加池仍由原合约完成。失败交易按合约原子回滚。Java 继续信任原链配置、SDK、RPC 和有权限的 Keeper；现有历史窗口提供价格限制，不是独立预言机。本次检查的不变量为：跳过或失败不记成功、同实例不并发发送、按实际买税保护金库实收、连续读取不能凑满样本。

## 5. 验证结果

- 使用 Java 8 语言级别、真实 Lombok 注解处理和 Web3j 4.12.3 编译替换源文件；缺少的后端模型、SDK 包装器与 Spring 注解使用对应签名的桩。完整后端工程未提供，未验证整包启动。
- 先在原代码复现问题，再跑修改版。14 项检查通过：历史下限、重复采样、估算错误、void 模拟、模拟 RPC error、买税报价、回滚回执、pending nonce、首次空跑、null/异常不记成功、地址大小写、初始化采样和无真实广播。
- 测试使用本地 RPC 与假发送器，没有读取附件私钥，没有向链上签名或广播交易。

差异文件的原始基线已将私钥值替换为同一占位符，不包含附件中的实际私钥。