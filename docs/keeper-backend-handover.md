# Keeper 后端接管交接文档

> 面向后端团队：本文档说明如何用一个普通后台服务（任意语言栈）替换现有 Cloudflare Worker Keeper。
> 合约是唯一事实来源；仓库 `keeper/` 目录的 TypeScript 实现是参考实现（含报价与锚点的完整逻辑）。
> 当前测试网（chainId 97）Coordinator：`0x63e325d9782DD42915a41673dA2Cc29F8e9B8424`。

## 1. 角色与职责边界

Keeper 是平台的自动化执行者，**只触发、不管钱**：

| 事项 | 归属 |
|---|---|
| 税代币 | 累计在代币合约 → 归集到 TaxProcessor，合约内四通道分账 |
| 市场通道 BNB | TaxProcessor 直接打入 BuybackVault |
| 分红 WBNB | TaxProcessor 直接存入 Dividend 合约 |
| LP | 全部铸造给 `0xdead`（死锁） |
| Keeper 钱包 | 只付 gas；**任何入口都没有向 keeper 付款的路径** |

权限模型：Keeper 钱包需要被授予 `CoordinatorFactory.KEEPER_ROLE()`。三个执行入口在链上校验 `IAccessControl(coordinator).hasRole(KEEPER_ROLE, msg.sender)`，轮换钱包 = 管理员 `grantRole`/`revokeRole`，无需改任何克隆合约。

## 2. 全链路（给后端的一句话版）

```
用户买卖转账 → 税代币累计在代币合约（达到动态阈值后，由下一笔指向主池的转账归集到 TaxProcessor）
  → ① Keeper 调 processPendingTax：税代币分批 swap 成 WBNB，合约内按四通道分账
      ├─ market    → 原生 BNB 打入 BuybackVault
      ├─ deflation → 税代币直接转 0xdead
      ├─ lp        → 一半留代币(lpTokenBalance)、一半换 WBNB(lpQuoteBalance)
      └─ dividend  → 存入 Dividend 合约
  → ② Keeper 调 addPendingLiquidity：lp 通道的代币+WBNB 配对加池，LP 铸给 0xdead
  → ③ Keeper 调 executeBuyback：金库按发币配置买回代币销毁（或买币加 LP 死锁）
```

用户交易里**没有**任何嵌套 swap（转账只记账），所有价格敏感操作都由 Keeper 独立交易完成。

## 3. 资产发现

```
total = Coordinator.getTotalTokenCount()
pairs = Coordinator.getAllTokenPresalePairs(offset, limit)   // 分页
对每个 token：
    taxProcessor = token.taxProcessor()
    pair         = token.mainPool()
    vault        = Coordinator.tokenVaults(token)            // 0 地址 = 无金库
```

建议：全量分页扫描 + 游标持久化（参考实现每分钟一页、循环游标）。发现后按资产独立调度任务。

## 4. 三类任务（触发条件、调用、参数）

### ① 税收清算 `TaxProcessor.processPendingTax(uint256 amountIn, uint256 minQuoteOut, uint64 deadline)`

- **触发**：`pendingTaxTokens() > 0`。
- **amountIn**：每次最多池代币储备的 0.3%（`TAX_MAX_RESERVE_BPS = 30`），即 `min(pendingTaxTokens, reserveToken * 30 / 10000)`。
- **minQuoteOut**：用**锚点报价**（见 §5），必须 > 0。
- **deadline**：`[now, now+600s]` 内。
- 清算后合约自行完成四通道分账与固定收款人派发（fee/market/dividend），Keeper 不需要也不应干预。

### ② 自动加池 `TaxProcessor.addPendingLiquidity(uint256 tokenAmount, uint256 minQuoteAmount, uint256 maxQuoteAmount, uint256 minLiquidity, uint64 deadline)`

- **触发**：`lpTokenBalance() > 0 && lpQuoteBalance() > 0`。
- **tokenAmount**：≤ `lpTokenBalance()`，同样受储备 0.3% 限制；合约按 `actualToken(含卖税实收) × quoteReserve / tokenReserve` 计算配对 WBNB，`minQuoteAmount/maxQuoteAmount` 给出可接受区间，`minLiquidity` 为 LP 最小产出。
- 配对 WBNB 从 `lpQuoteBalance` 扣减；LP 全部铸给 `0xdead`。

### ③ 金库回购 `BuybackVault.executeBuyback(uint256 expectedBnbIn, uint256 minTokenOut, uint256 minLpTokenOut, uint64 deadline)`

- **触发**：`previewBuyback()` 返回 `(executableAmount, readiness)`，`readiness == 0 (Ready)`。
- **expectedBnbIn**：必须等于/小于调用时 `previewBuyback()` 返回的 `executableAmount`（合约执行时重算，上限收紧则回滚）。
- **minTokenOut**：TokenBurn 路径与 LpBurn 失败回退路径的代币最低产出（按买税折算）。
- **minLpTokenOut**：**LpBurn 模式专用——语义是"LP 路径 swap 半仓的代币最低产出"**（不是 LP token 数量），按 `expectedBnbIn × 49.9%` 的买入量报价；TokenBurn 模式传 0。
- 金库 readiness 枚举：`0 Ready / 1 InsufficientBalance / 2 TriggerBalanceNotMet / 3 TooEarly / 4 InvalidPoolReserves / 5 ReserveCapBelowMinimum`。`1/2/3` 为正常等待；`4/5` 为流动性异常（池无储备或储备过小），持续出现应告警。

### ④ 自动回购金库机制详解（排障必备背景）

**资金来源**：`createTokenWithVault` 发币时 Coordinator 把 `feeRecipient` 覆盖为金库地址，TaxProcessor 的市场通道（`marketBps` 份额）在每次清算后以**原生 BNB** 打入金库（`_forwardQuote` 解包 WBNB）。金库 `receive()` 只收款记账；费通道的整数尘埃也会进金库（`feeReceiver` 同为金库）。**金库没有任何提款/管理员出口**（含创建者），BNB 只能经回购路径流出。

**创建时锁定的配置（`BuybackConfig`，不可改）**：

| 字段 | 取值 | 说明 |
|---|---|---|
| `mode` | 0=TokenBurn / 1=LpBurn | 买币销 0xdead；或买币加 LP 死锁（失败回退 TokenBurn） |
| `trigger` | 0=Time / 1=Balance / 2=TimeAndBalance | 时间触发 / 余额触发 / 双条件 |
| `firstExecuteAt` | uint64 | 模式 0/2：≥ 创建+60s；模式 1：恒为 0 |
| `intervalSeconds` | 60 ~ 31,536,000 | 执行冷却间隔 |
| `triggerAmount` | uint256 | 模式 1/2 的余额触发线（≥ buybackAmount，≤ 1000 BNB） |
| `buybackAmount` | 0.001 ~ 10 BNB（0.001 精度） | 单次回购上限 |

**`previewBuyback()` 的 readiness 推导链**（后端排查"为何不 Ready"按此顺序自查）：

```
1. 余额 < 0.0001 BNB                → 1 InsufficientBalance（等税收流入）
2. 模式 1/2 且 余额 < triggerAmount  → 2 TriggerBalanceNotMet
3. 时间未到                          → 3 TooEarly
   （模式 0/2：now < nextExecuteTime；模式 1：now < lastExecuteTime + interval，首次除外）
4. Pair 储备为 0                     → 4 InvalidPoolReserves（主池无水，告警）
5. executableAmount < 0.0001 BNB     → 5 ReserveCapBelowMinimum（1% 储备上限低于经济下限）
   executableAmount = min(余额, buybackAmount, 池 WBNB 储备 × 1%)
6. 否则                              → 0 Ready
```

**两种回购模式的内部流程**（keeper 不需要实现，理解日志用）：

- **TokenBurn**：全部预算经 Router 买本币（买税实收计量）→ 转 `0xdead`；`totalBuybackBNB/totalBurnedToken` 记账。
- **LpBurn**：预算的 49.9% 买本币（`LP_SWAP_BPS = 4990`）→ 按买后池储备比例计算配对 WBNB（≤ 剩余 50.1%，超出则回退）→ 代币 + WBNB 转入 Pair 铸造 LP → LP 直接铸给 `0xdead`；**未使用预算留在金库**；任何环节失败整段回退到 TokenBurn 路径（同交易）。
- 冷却只在**成功**时推进（`lastExecuteTime/nextExecuteTime` 在换币前写入，失败整笔回滚）。

**keeper 侧注意**：① 金库买入自身要付买税，报价必须按买税折算实收（§5）；② `minLpTokenOut` 语义是"LP 路径半仓 swap 的代币最低产出"，与 `minTokenOut`（全额/回退路径）分别报价；③ 金库无准备金模式区分——纯发币与预售币的金库逻辑完全相同，只是预售币在开盘前池无储备、readiness 停在 `InvalidPoolReserves`（属正常等待）。

## 5. 报价与锚点策略（重点，做错会被夹或一直拒绝）

1. **采样**：每次巡检记录 Pair `getReserves()`，保留最近 ~15 个样本（窗口 5~60 分钟，`ANCHOR_MIN/MAX_AGE_SECONDS`，最少 3 个样本才报价）。
2. **锚点价**：样本储备的中位数；**当前报价与锚点报价偏差 > 3%（`MAX_PRICE_DEVIATION_BPS = 300`）→ 放弃本轮，不下发交易**（这是设计行为：等锚点跟上，实测每批间隔约 8~10 分钟）。
3. **最低输出计算**（与参考实现一致）：
   - 卖税方向（税清算）：`minQuoteOut = getAmountOut(amountIn × (1 - sellTax), reserveToken_anchor, reserveWbnb_anchor, ammFeeBps) × (1 - SLIPPAGE_BPS 100 = 1%)`，再与锚点值取更保守者；
   - 买入方向（金库）：`getAmountOut(bnbIn, reserveWbnb, reserveToken)` 后按买税折算实收，同样 −1%；
   - `ammFeeBps`：Pancake V2 = 25（0.25%）。
4. **硬性纪律**：`minOut` 绝不为 0、绝不放宽到"能成交就行"；模拟（`eth_call`）通过才签名发送；发送用私有/MEV 保护 RPC（主网强制，测试网可公共）。
5. **可预期的"拒绝"**：单笔清算会把价格压低 ~0.54%，锚点滞后期间 Keeper 会连续跳过（`INSUFFICIENT_OUTPUT_AMOUNT` 模拟失败）——这是正常等待，资金原地不动，不要当成故障重试或放宽参数。

## 6. 合约强制的安全约束（后端不需要重复实现，但必须知道）

- 三个入口都校验 `KEEPER_ROLE`、`minOut > 0`、`deadline ∈ [now, now+10min]`；失败整笔回滚，资金留在原合约。
- 金库执行额三重取小：`min(余额, buybackAmount 配置上限, 池 WBNB 储备 × 1%)`；低于 0.0001 BNB 不可执行。
- 金库没有任何提款/管理员出口（含创建者）；LP 与销毁都去 `0xdead`。
- TaxProcessor 的报价侧会计有不变量（`actual ≥ accounted`），异常会整体回滚。

## 7. 钱包、密钥、RPC

- **独立 keeper 钱包**：只放 gas（测试网 ≥ 0.05 tBNB；主网建议 1–2 周消耗量起步 + 余额告警）。
- **私钥管理**：KMS/HSM 或加密环境变量；不进仓库、日志、数据库。
- **nonce**：同一时刻最多一个未确认 nonce（串行发送）；卡住时按原 nonce 替换（`PENDING_RETRY_SECONDS = 90`）。
- **RPC**：读取可用公共节点；主网发送必须私有 MEV 保护 RPC 且与读取 RPC 不同源。
- **gas**：价格上限 `MAX_GAS_PRICE_WEI = 10 gwei`，乘数 `GAS_PRICE_MULTIPLIER_BPS = 12000`。

## 8. 监控与告警（建议指标）

- 每资产每类任务：跳过次数与原因；**连续跳过 ≥ 5 次**告警（成交自动清零解除）。
- 金库 readiness 连续处于 `InvalidPoolReserves / ReserveCapBelowMinimum` ≥ 5 轮 → 流动性告警。
- 每次执行记录：资产、任务类型、amountIn、锚点价/当前价、minOut、tx hash、回执。
- Keeper 钱包余额低于阈值告警；RPC 连续失败告警。

## 9. 联调验收步骤（测试网）

1. 管理员在 Coordinator 上 `grantRole(KEEPER_ROLE, <后端 keeper 地址>)`。
2. 用 `script/KeeperAcceptance.s.sol`（纯发币模式）或 `script/PresaleAcceptance.s.sol`（预售模式）造一个带金库的测试币并制造应税成交（脚本内有用法注释；需要我们协助可喊）。
3. 后端服务应在 ~10 分钟内开始：发现资产 → 分批清算（pendingTaxTokens 递减）→ 金库积累 → `executeBuyback` 触发（`buybackCount ≥ 1`）。
4. 对照链上会计：`totalQuoteSentToReceiver = totalBuybackBNB + 金库余额`（TokenBurn 模式）；`0xdead` 代币持仓 = deflation 销毁 + 回购销毁。
5. 期间可用仓库现有 Cloudflare Worker 作为"对照组"（停启它的 cron 即可切换）。

## 10. 参考实现与资料

- 参考实现（TS）：`keeper/src/`（`planner.ts` 报价/锚点、`workflow.ts` 调度、`transaction.ts`/`signer.ts` 发送与 nonce、`discovery.ts` 资产发现、`policy.ts` 金额与税务折算）。
- 参数基线（测试网在跑配置）：`CHECK_INTERVAL 60s`、`TAX_MAX_RESERVE_BPS 30`、`SLIPPAGE_BPS 100`、`MAX_PRICE_DEVIATION_BPS 300`、`ANCHOR 300–3600s`、`MIN_ANCHOR_SAMPLES 3`、`DEADLINE 300s`、`AMM_FEE_BPS 25`、`MAX_ASSETS_PER_RUN 8`。
- 冒烟报告（真实链路数据与节奏）：`docs/smoke-test-report-2026-09-23.md`、`docs/smoke-test-report-lpburn-2026-09-23.md`、`docs/smoke-test-report-presale-2026-09-23.md`、`docs/smoke-test-report-dividend-fix-2026-09-24.md`。

## 11. 附录：Java（Web3j）参考实现

下面是一份可直接编译运行的最小 Demo，演示 keeper 的完整骨架：读调用、资产发现、报价与锚点、三类任务执行。生产环境建议改用 web3j-codegen 从 ABI 生成强类型包装类（`CoordinatorFactory` / `TaxProcessor` / `BuybackVault` / `PancakePair`），字符串式 `Function` 仅用于演示。

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.web3j</groupId>
    <artifactId>core</artifactId>
    <version>4.12.3</version>
</dependency>
```

### 11.1 初始化与读调用

回购接入请使用 [Java 回购修正版](keeper-java-buyback-patch.md) 的完整类：它补齐同区块读取、区块时间采样、5～60 分钟历史筛选、地址归一化、有效买税和 RPC 错误检查。下文是整体流程的精简骨架；不要把它的采样方法与修正版的窗口键、Sample 类型混用。

```java
import org.web3j.abi.*;
import org.web3j.abi.datatypes.*;
import org.web3j.abi.datatypes.generated.*;
import org.web3j.crypto.Credentials;
import org.web3j.tx.RawTransactionManager;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.EthCall;
import org.web3j.protocol.http.HttpService;

import java.math.BigInteger;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

public class KeeperDemo {
    // ---------- 配置（测试网基线） ----------
    static final long        CHAIN_ID               = 97;                    // 主网 56
    static final String      RPC_READ               = "https://bsc-testnet-rpc.publicnode.com";
    static final String      COORDINATOR            = "0x63e325d9782DD42915a41673dA2Cc29F8e9B8424";
    static final BigInteger  BPS                    = BigInteger.valueOf(10_000);
    static final BigInteger  AMM_FEE_BPS            = BigInteger.valueOf(25);   // Pancake V2 0.25%
    static final BigInteger  SLIPPAGE_BPS           = BigInteger.valueOf(100);  // 1%
    static final BigInteger  MAX_DEVIATION_BPS      = BigInteger.valueOf(300);  // 3%
    static final BigInteger  TAX_MAX_RESERVE_BPS    = BigInteger.valueOf(30);   // 单批 ≤ 储备 0.3%
    static final BigInteger  LP_SWAP_BPS            = BigInteger.valueOf(4_990); // 金库 LP 模式半仓
    static final long        DEADLINE_SECONDS       = 300;                      // 合约上限 600
    static final BigInteger  GAS_LIMIT_MULTIPLIER   = BigInteger.valueOf(130);  // %（首卖教训：给足余量）

    final Web3j web3j = Web3j.build(new HttpService(RPC_READ));
    final RawTransactionManager txm;
    final String keeper;

    KeeperDemo(String privateKeyHex) {
        Credentials cred = Credentials.create(privateKeyHex);
        this.keeper = cred.getAddress();
        this.txm = new RawTransactionManager(web3j, cred, CHAIN_ID);
    }

    /** 通用 eth_call；revert 直接抛异常。 */
    @SuppressWarnings("rawtypes")
    List<Type> call(String to, String name, List<Type> inputs, List<TypeReference<?>> outputs) throws Exception {
        Function fn = new Function(name, inputs, outputs);
        String data = FunctionEncoder.encode(fn);
        Transaction tx = Transaction.createEthCallTransaction(keeper, to, data);
        EthCall res = web3j.ethCall(tx, DefaultBlockParameterName.LATEST).send();
        if (res.isReverted()) throw new IllegalStateException(name + " reverted: " + res.getRevertReason());
        return FunctionReturnDecoder.decode(res.getValue(), fn.getOutputParameters());
    }

    BigInteger readUint(String to, String name) throws Exception {
        return (BigInteger) call(to, name, List.of(), List.of(new TypeReference<Uint256>() {})).get(0).getValue();
    }
}
```

### 11.2 资产发现（分页/游标可在此基础上扩展）

```java
    record Asset(String token, String taxProcessor, String pair, String vault) {}

    @SuppressWarnings("unchecked")
    List<Asset> discover() throws Exception {
        BigInteger total = readUint(COORDINATOR, "getTotalTokenCount");
        List<Asset> out = new ArrayList<>();
        for (BigInteger i = BigInteger.ZERO; i.compareTo(total) < 0; i = i.add(BigInteger.ONE)) {
            String token = (String) call(COORDINATOR, "allTokens",
                    List.of(new Uint256(i)), List.of(new TypeReference<Address>() {})).get(0).getValue();
            String taxProcessor = (String) call(token, "taxProcessor", List.of(),
                    List.of(new TypeReference<Address>() {})).get(0).getValue();
            String pair = (String) call(token, "mainPool", List.of(),
                    List.of(new TypeReference<Address>() {})).get(0).getValue();
            String vault = (String) call(COORDINATOR, "tokenVaults",
                    List.of(new Address(token)), List.of(new TypeReference<Address>() {})).get(0).getValue();
            out.add(new Asset(token, taxProcessor, pair,
                    vault.equalsIgnoreCase("0x0000000000000000000000000000000000000000") ? null : vault));
        }
        return out;
    }
```

### 11.3 报价与锚点（§5 的代码版）

```java
    record Reserves(BigInteger token, BigInteger wbnb) {}
    record Sample(long ts, Reserves reserves) {}

    final Map<String, Deque<Sample>> windows = new ConcurrentHashMap<>(); // pair -> 样本窗口

    /** AMM 输出：Pancake V2 恒定乘积（费率 AMM_FEE_BPS）。 */
    static BigInteger getAmountOut(BigInteger amountIn, BigInteger reserveIn, BigInteger reserveOut) {
        BigInteger inWithFee = amountIn.multiply(BPS.subtract(AMM_FEE_BPS));
        return inWithFee.multiply(reserveOut).divide(reserveIn.multiply(BPS).add(inWithFee));
    }

    /** 读储备并按 token0/token1 归一为 (token, wbnb)。 */
    @SuppressWarnings("rawtypes")
    Reserves reserves(Asset a) throws Exception {
        List<Type> r = call(a.pair(), "getReserves", List.of(), List.of(
                new TypeReference<Uint112>() {}, new TypeReference<Uint112>() {}, new TypeReference<Uint32>() {}));
        String token0 = (String) call(a.pair(), "token0", List.of(), List.of(new TypeReference<Address>() {})).get(0).getValue();
        BigInteger r0 = (BigInteger) r.get(0).getValue(), r1 = (BigInteger) r.get(1).getValue();
        Reserves rs = token0.equalsIgnoreCase(a.token()) ? new Reserves(r0, r1) : new Reserves(r1, r0);
        Deque<Sample> w = windows.computeIfAbsent(a.pair(), k -> new ArrayDeque<>());
        long now = Instant.now().getEpochSecond();
        w.addLast(new Sample(now, rs));
        while (!w.isEmpty() && now - w.peekFirst().ts > 3600) w.pollFirst();   // 只留 1h 窗口
        return rs;
    }

    /** 锚点报价：窗口内每个样本算一次输出，取中位数；样本 <3 返回 null（不报价）。 */
    BigInteger anchorQuote(Asset a, BigInteger effectiveIn, boolean sellDirection) {
        List<BigInteger> quotes = new ArrayList<>();
        for (Sample s : windows.getOrDefault(a.pair(), new ArrayDeque<>())) {
            if (s.reserves().token().signum() == 0 || s.reserves().wbnb().signum() == 0) continue;
            quotes.add(sellDirection
                    ? getAmountOut(effectiveIn, s.reserves().token(), s.reserves().wbnb())
                    : getAmountOut(effectiveIn, s.reserves().wbnb(), s.reserves().token()));
        }
        if (quotes.size() < 3) return null;
        quotes.sort(null);
        return quotes.get(quotes.size() / 2);
    }

    /** 偏差守门：当前价与锚点价偏差 > 3% 则放弃本轮（正常等待，不是错误）。 */
    static boolean within(BigInteger current, BigInteger anchor, BigInteger maxBps) {
        BigInteger diff = current.subtract(anchor).abs();
        return diff.multiply(BPS).compareTo(anchor.multiply(maxBps)) <= 0;
    }

    /** 保护性最低输出：当前/锚点都扣滑点后，取较高的下限，与正式 Keeper 一致。 */
    static BigInteger protectedMinOut(BigInteger currentQuote, BigInteger anchorQuote) {
        BigInteger currentFloor = currentQuote.multiply(BPS.subtract(SLIPPAGE_BPS)).divide(BPS);
        BigInteger anchorFloor = anchorQuote.multiply(BPS.subtract(SLIPPAGE_BPS)).divide(BPS);
        return currentFloor.max(anchorFloor);
    }
```

### 11.4 模拟与发送

```java
    /** 发送前必须模拟；revert 视为"本轮跳过"（资金安全留在原合约）。 */
    boolean simulate(String to, String data) {
        try {
            Transaction tx = Transaction.createFunctionCallTransaction(
                    keeper, null, null, null, to, BigInteger.ZERO, data);
            EthCall res = web3j.ethCall(tx, DefaultBlockParameterName.PENDING).send();
            if (res.hasError()) {
                System.err.println("eth_call failed: code=" + res.getError().getCode()
                        + ", message=" + res.getError().getMessage() + ", data=" + res.getError().getData());
                return false;
            }
            if (res.isReverted()) {
                System.err.println("eth_call reverted: " + res.getRevertReason());
                return false;
            }
            if (res.getValue() == null) return false;
            // executeBuyback 没有返回值；成功时 result="0x"，不能用 Numeric.decodeQuantity 解析。
            return true;
        } catch (Exception e) {
            System.err.println("eth_call exception: " + e.getMessage());
            return false;
        }
    }

    String send(String to, String data) throws Exception {
        Transaction tx = Transaction.createFunctionCallTransaction(keeper, null, null, null, to, BigInteger.ZERO, data);
        var estimateResponse = web3j.ethEstimateGas(tx).send();
        // 先检查 RPC 错误；错误响应没有 result，直接 getAmountUsed() 会掩盖真实回滚原因。
        if (estimateResponse.hasError()) {
            throw new IllegalStateException("eth_estimateGas failed: code=" + estimateResponse.getError().getCode()
                    + ", message=" + estimateResponse.getError().getMessage()
                    + ", data=" + estimateResponse.getError().getData());
        }
        if (estimateResponse.getResult() == null) throw new IllegalStateException("eth_estimateGas returned no result");
        BigInteger estimated = estimateResponse.getAmountUsed();
        BigInteger gasLimit = estimated.multiply(GAS_LIMIT_MULTIPLIER).divide(BigInteger.valueOf(100));
        var gasPriceResponse = web3j.ethGasPrice().send();
        if (gasPriceResponse.hasError()) {
            throw new IllegalStateException("eth_gasPrice failed: " + gasPriceResponse.getError().getMessage());
        }
        if (gasPriceResponse.getResult() == null) throw new IllegalStateException("eth_gasPrice returned no result");
        BigInteger gasPrice = gasPriceResponse.getGasPrice();
        var resp = txm.sendTransaction(gasPrice, gasLimit, to, data, BigInteger.ZERO);
        if (resp.hasError()) throw new RuntimeException("send failed: " + resp.getError().getMessage());
        return resp.getTransactionHash();
    }
```

`Value must be in format 0x[1-9]+[0-9]* or 0x0` 是 Web3j 数字解码异常。先查看原始 RPC 的 `error`；不要把合约回滚后缺失的 `result` 当成数字解析，也不要把无返回值方法模拟成功时的 `"0x"` 当成数字。业务层包装异常时使用 `throw new RuntimeException("调用 executeBuyback 失败", e)` 保留原始堆栈。

### 11.5 三类任务

```java
    /** ① 税收清算：processPendingTax(amountIn, minQuoteOut, deadline) */
    void taxJob(Asset a, BigInteger sellTaxBps) throws Exception {
        BigInteger pending = readUint(a.taxProcessor(), "pendingTaxTokens");
        if (pending.signum() == 0) return;
        Reserves r = reserves(a);
        if (r.token().signum() == 0) return;
        BigInteger amountIn = pending.min(r.token().multiply(TAX_MAX_RESERVE_BPS).divide(BPS));
        if (amountIn.signum() == 0) return;

        BigInteger effectiveIn = amountIn.multiply(BPS.subtract(sellTaxBps)).divide(BPS); // 扣卖税
        BigInteger currentQuote = getAmountOut(effectiveIn, r.token(), r.wbnb());
        BigInteger anchorQuote = anchorQuote(a, effectiveIn, true);
        if (anchorQuote == null || !within(currentQuote, anchorQuote, MAX_DEVIATION_BPS)) return; // 等锚点
        BigInteger minQuoteOut = protectedMinOut(currentQuote, anchorQuote);

        long deadline = Instant.now().getEpochSecond() + DEADLINE_SECONDS;
        String data = FunctionEncoder.encode(new Function("processPendingTax",
                List.of(new Uint256(amountIn), new Uint256(minQuoteOut), new Uint64(deadline)), List.of()));
        if (!simulate(a.taxProcessor(), data)) return;    // 锚点滞后等正常原因，跳过本轮
        send(a.taxProcessor(), data);
    }

    /** ② 自动加池：addPendingLiquidity(tokenAmount, minQuote, maxQuote, minLiquidity, deadline) */
    void liquidityJob(Asset a) throws Exception {
        BigInteger lpToken = readUint(a.taxProcessor(), "lpTokenBalance");
        BigInteger lpQuote = readUint(a.taxProcessor(), "lpQuoteBalance");
        if (lpToken.signum() == 0 || lpQuote.signum() == 0) return;
        Reserves r = reserves(a);
        BigInteger tokenAmount = lpToken.min(r.token().multiply(TAX_MAX_RESERVE_BPS).divide(BPS));
        // 合约按 actualToken(含卖税实收) × quoteReserve / tokenReserve 配对，给出 ±2% 可接受区间
        BigInteger quote = tokenAmount.multiply(r.wbnb()).divide(r.token());
        long deadline = Instant.now().getEpochSecond() + DEADLINE_SECONDS;
        String data = FunctionEncoder.encode(new Function("addPendingLiquidity",
                List.of(new Uint256(tokenAmount),
                        new Uint256(quote.multiply(BigInteger.valueOf(98)).divide(BigInteger.valueOf(100))),
                        new Uint256(quote.multiply(BigInteger.valueOf(102)).divide(BigInteger.valueOf(100))),
                        new Uint256(BigInteger.ONE),                 // minLiquidity：演示用 1，生产按锚点算
                        new Uint64(deadline)),
                List.of(new TypeReference<Uint256>() {}, new TypeReference<Uint256>() {})));
        if (!simulate(a.taxProcessor(), data)) return;
        send(a.taxProcessor(), data);
    }

    /** ③ 金库回购：previewBuyback → executeBuyback(expectedBnbIn, minTokenOut, minLpTokenOut, deadline) */
    @SuppressWarnings("rawtypes")
    void buybackJob(Asset a, BigInteger buyTaxBps, int vaultMode) throws Exception {
        if (a.vault() == null) return;
        List<Type> out = call(a.vault(), "previewBuyback", List.of(),
                List.of(new TypeReference<Uint256>() {}, new TypeReference<Uint8>() {}));
        BigInteger executable = (BigInteger) out.get(0).getValue();
        int readiness = ((BigInteger) out.get(1).getValue()).intValue();
        if (readiness != 0) return;                       // 1/2/3 正常等待；4/5 流动性异常应告警

        Reserves r = reserves(a);
        // TokenBurn 及回退路径：按全额买入 + 买税折算
        BigInteger gross = getAmountOut(executable, r.wbnb(), r.token());
        BigInteger net = gross.multiply(BPS.subtract(buyTaxBps)).divide(BPS);
        BigInteger anchorGross = anchorQuote(a, executable, false);
        if (anchorGross == null || !within(gross, anchorGross, MAX_DEVIATION_BPS)) return;
        // 历史报价也转成金库税后实收；当前和历史报价必须使用相同口径。
        BigInteger anchorNet = anchorGross.multiply(BPS.subtract(buyTaxBps)).divide(BPS);
        BigInteger minTokenOut = protectedMinOut(net, anchorNet);
        // LpBurn 模式：半仓（49.9%）的代币最低产出（注意：minLpTokenOut 语义是代币量，不是 LP 量）
        BigInteger minLpTokenOut = BigInteger.ZERO;
        if (vaultMode == 1) {
            BigInteger lpGross = getAmountOut(executable.multiply(LP_SWAP_BPS).divide(BPS), r.wbnb(), r.token());
            minLpTokenOut = lpGross.multiply(BPS.subtract(buyTaxBps)).divide(BPS)
                    .multiply(BPS.subtract(SLIPPAGE_BPS)).divide(BPS);
        }
        long deadline = Instant.now().getEpochSecond() + DEADLINE_SECONDS;
        String data = FunctionEncoder.encode(new Function("executeBuyback",
                List.of(new Uint256(executable), new Uint256(minTokenOut),
                        new Uint256(minLpTokenOut), new Uint64(deadline)),
                List.of()));
        if (!simulate(a.vault(), data)) return;
        send(a.vault(), data);
    }
```

回购报价排障实例（2026-10-08，BSC 测试网）：预算 `298550966643520 wei`、买税 `1000 bps` 时，该主池按示例 AMM 费率估算的税前产出为 `61062659519686468711547`，税后实收报价为 `54956393567717821840392`。若当前与历史税前报价相同，1% 滑点的正确 `minTokenOut` 为 `54406829632040643621988`；漏扣买税会得到 `60452032924489604024431`，超过税后实收。对金库 `0x2A8c13827329D7aED051fc3EBF2Dd057df61E730` 用已授权 Keeper 发起只读 `eth_call` 和 `eth_estimateGas`，错误下限返回 `PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT`，修正后两者通过。复现时重新读取同一块储备与 `previewBuyback()`，设置新的秒级 deadline，只修改最低输出进行对照；本例数字是历史诊断数据，不能作为生产交易的固定参数。

### 11.6 主循环骨架

```java
    public static void main(String[] args) {
        KeeperDemo keeper = new KeeperDemo(System.getenv("KEEPER_PRIVATE_KEY")); // 私钥只走环境变量/KMS
        ScheduledExecutorService ses = Executors.newSingleThreadScheduledExecutor(); // 串行 = 天然单 nonce
        ses.scheduleWithFixedDelay(() -> {
            try {
                for (Asset a : keeper.discover()) {
                    keeper.taxJob(a, BigInteger.valueOf(1000));      // sellTax 从 poolState()/feeConfig 读取
                    keeper.liquidityJob(a);
                    keeper.buybackJob(a, BigInteger.valueOf(500), 0); // buyTax 与 vault.mode() 同上
                }
            } catch (Exception e) {
                // 记录并告警；绝不在 catch 中放宽 minOut 重试
            }
        }, 0, 60, TimeUnit.SECONDS);
    }
```

**生产化清单**：① 用 `org.web3j.codegen.SolidityFunctionWrapperGenerator` 从 ABI 生成强类型包装类替换字符串式调用；② 买卖税率请从 `token.poolState()`（`buyTaxRate/sellTaxRate`）或 `TaxProcessor.feeConfig()` 链上读取，不要硬编码；③ 发送路径切换为私有 MEV RPC（主网 `SEND_RPC_URL != READ_RPC_URL`）；④ 补 §8 的跳过计数与告警；⑤ 私钥迁移到 KMS/HSM。
