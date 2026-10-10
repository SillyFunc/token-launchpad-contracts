# Java 后端 Keeper 参考实现（BSC，清税 / 加池 / 回购）

> 范围：把当前 `keeper/src/` 的业务规则交给 Java 后端实现，包括普通代币的清税和加池，以及启用金库后的回购。本文是**完整的执行规则和 Java 核心代码参考**，不是已经部署、已经连接数据库与 RPC 的独立服务。`ChainPort`、`StorePort`、`SignerPort` 必须接入后端现有基础设施；生产上线前按本文最后一节验收。涉及资金的公式以仓库当前 `keeper/src/planner.ts`、`keeper/src/policy.ts`、`keeper/src/signer.ts` 为准。
>
> **部署版本边界**：`docs/frontend-integration-mainnet.md` 记录的现有主网地址尚未包含这套四通道 TaxProcessor / BuybackVault，不能把本 ABI 套在那些旧地址上。先用 `broadcast/` 与链上代码核对目标部署。测试网新动态金库与旧固定金额金库的 ABI 也不同。

## 1. 先看懂一轮的顺序

```text
每分钟触发一次 Java 定时任务
  1. 核对 chainId、Coordinator 合约代码、Keeper 钱包与 KEEPER_ROLE
  2. 恢复上一轮尚未确认的交易（先查回执 / nonce，再考虑新交易）
  3. 从 Coordinator 分页发现代币，更新本地资产表和发现游标
  4. 从资产表取 status=active 且 next_check_at<=当前时间的前 N 个代币
  5. 对每个代币，在同一个区块读取池储备、代币税率、TaxProcessor 余额、金库预览
  6. 保存本次主池储备样本
  7. 检查 5～60 分钟前是否有至少 3 条有效储备样本
  8. 按 tax → liquidity → buyback 顺序生成候选任务；无金库时 buyback 为空
  9. 每笔交易在签名前重新读链、重新规划、eth_call 模拟、核对 Gas 和余额
 10. 同一个 Keeper 钱包串行占用 nonce；先持久化已签名交易，再广播
 11. 保存交易状态；完成巡检后把 next_check_at 推到约 60 秒以后
```

“进入巡检队列”只表示读取链上状态，不代表一定发交易。新发现代币在数据库中以 `active`、`next_check_at=0` 注册；即使没有金库或暂时没有税费，也会被定时检查。单轮默认最多检查 8 个代币，因此代币多时不能保证每个代币严格每 60 秒检查一次。

例如：代币 A 的 `vault=null`，仍照常读取 `pendingTaxTokens` 与 LP 双边余额，可能执行清税/加池，回购分支直接跳过。代币 B 有新版金库，且金库 BNB 余额为 3 BNB、创建者设置的 `buybackAmount` 上限为 10 BNB、主池 WBNB 储备为 100 BNB；当触发条件和冷却均满足时，`previewBuyback()` 给出的本次输入最多是 `min(3,10,100×1%)=1 BNB`。后端以这 **1 BNB** 计算 `minTokenOut`，而不是以 10 BNB 报价。

## 2. 资金与信任边界

| 项目 | 约束 |
|---|---|
| 资产 | 税代币、WBNB、BNB 和 LP 都留在合约中；Keeper 钱包只付 BNB Gas，不接收回购或清税资金。 |
| 任意触发 | 定时器只影响何时尝试；`processPendingTax` 与 `executeBuyback` 仍受链上 Keeper 权限控制。 |
| 报价 | 使用主池当前储备和 5～60 分钟历史储备分别报价；偏差超过 3% 跳过。清税 swap 与回购 swap 的最低输出取两个报价各降 1% 后的**较大值**；加池用当前配对报价的上下界和历史偏差检查。同池历史样本只是现有策略的价格约束，不等同独立预言机；主网还需要 MEV 保护发送 RPC。 |
| 失败 | `eth_call` 失败不广播；已广播但结果未知时按同一笔已签名交易恢复，不能直接换 nonce 再发。合约执行失败通常整笔回滚；新版金库 LP 买毁失败可能按合约逻辑回退为 Token 买毁。 |
| 不变量 | 一个 Keeper 钱包同一时间只允许一个未解决的 nonce；一个 jobId 最多签名一次；发送前重新核对目标合约和最新链上金额。 |

三笔资金交易的终态也要给后端说明白：清税成功后 TaxProcessor 按市场/销毁/LP/分红通道记账，失败则原交易回滚；加池成功后 LP 铸给 `0xdead`，失败则代币与 WBNB 转账整体回滚；回购成功由金库花费自身 BNB 并销毁代币或 LP，LP 路径失败时合约可回退为 Token 买毁，未用完的 BNB 仍留在金库。Keeper 只支付自己的 Gas，不需要先从金库提币，也不应收取回购输出。

## 3. 后端保存什么

可以沿用 `keeper/migrations/0001_init.sql` 的 `settings`、`assets`、`price_samples`、`keeper_runs`、`transactions`、`alerts` 表。另建一个**受控访问**的 `signer_jobs` 表，保存 `job_id`、`kind`、`token`、`target`、`nonce`、`tx_hash`、`raw_tx`、`gas_price`、`deadline`、`status`、`submitted_at`、`attempts`。该表必须在广播前完成持久化；签名原文不是私钥，但仍应限制读取权限。私钥放密钥服务，禁止写入数据库或日志。

三个核心持久化对象如下：

| 对象 | 字段 | 为什么要存 |
|---|---|---|
| `assets` | `chain_id, token, tax_processor, vault(nullable), pair, wbnb, status, next_check_at, last_checked_at, last_error` | 确定巡检队列与可信交易目标。`active` 是后端调度状态，不是代币链上的 `poolState.state`。 |
| `price_samples` | `chain_id, pair, block_number, sampled_at, reserve_token, reserve_wbnb` | 历史报价锚点。所有金额用十进制字符串或 `NUMERIC(78,0)`，Java 用 `BigInteger`；不要用 `double`。同一 `(chain_id,pair,block_number)` 去重。 |
| `signer_jobs` | 上述签名任务字段 | 崩溃恢复、回执核对、同 nonce 重播或替换、幂等。 |

`settings` 另存 `discovery_cursor:<chainId>`；`keeper_runs`、`transactions`、`alerts` 用于审计和告警。当前 `pendingTaxTokens`、当前 LP 待处理余额、当前主池储备和金库 BNB 余额**每次从链上重新读取**，不可把数据库快照当成签名前的最终值。历史样本可以按超过锚点最大年龄再加适当缓冲的保留期清理。

若后端使用 PostgreSQL，签名任务表可从下面的最小结构开始；MySQL 等数据库需要改写部分索引语法，但必须保持唯一活跃任务约束：

```sql
CREATE TABLE signer_jobs (
    job_id TEXT PRIMARY KEY,
    chain_id INTEGER NOT NULL,
    keeper_address TEXT NOT NULL,
    kind TEXT NOT NULL,
    token TEXT NOT NULL,
    target TEXT NOT NULL,
    status TEXT NOT NULL,
    nonce NUMERIC(78, 0) NOT NULL,
    tx_hash TEXT NOT NULL,
    raw_tx TEXT NOT NULL,
    gas_price NUMERIC(78, 0) NOT NULL,
    deadline BIGINT NOT NULL,
    submitted_at BIGINT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    detail TEXT
);
CREATE UNIQUE INDEX signer_one_active_per_wallet
    ON signer_jobs(chain_id, keeper_address)
    WHERE status IN ('prepared', 'submitted');
```

## 4. Java 类型与配置

以下代码使用 Java 21 的 `record`，用标准 JDK 类型表示核心逻辑。它不依赖某个 Spring/web3j 版本，便于后端把核心算法放入自己的服务。区块链和数据库接线见第 6 节。

启动时配置值的声明示意如下；RPC 地址由 `RpcPort` 分别使用，私钥由 `RawSigner` 从密钥服务读取，不加入 `Config` 或数据库：

```java
java.util.Map<String, String> env = System.getenv();
int chainId = Integer.parseInt(env.getOrDefault("CHAIN_ID", "97"));
String readRpcUrl = java.util.Objects.requireNonNull(env.get("READ_RPC_URL"));
String sendRpcUrl = java.util.Objects.requireNonNull(env.get("SEND_RPC_URL"));
String coordinator = java.util.Objects.requireNonNull(env.get("COORDINATOR_ADDRESS"));
String keeperAddress = java.util.Objects.requireNonNull(env.get("KEEPER_ADDRESS"));
int discoveryPageSize = Integer.parseInt(env.getOrDefault("DISCOVERY_PAGE_SIZE", "8"));
int maxAssetsPerRun = Integer.parseInt(env.getOrDefault("MAX_ASSETS_PER_RUN", "8"));
long checkIntervalSeconds = Long.parseLong(env.getOrDefault("CHECK_INTERVAL_SECONDS", "60"));
int ammFeeBps = Integer.parseInt(env.getOrDefault("AMM_FEE_BPS", "25"));
int taxMaxReserveBps = Integer.parseInt(env.getOrDefault("TAX_MAX_RESERVE_BPS", "30"));
int slippageBps = Integer.parseInt(env.getOrDefault("SLIPPAGE_BPS", "100"));
int maxPriceDeviationBps = Integer.parseInt(env.getOrDefault("MAX_PRICE_DEVIATION_BPS", "300"));
long anchorMinAgeSeconds = Long.parseLong(env.getOrDefault("ANCHOR_MIN_AGE_SECONDS", "300"));
long anchorMaxAgeSeconds = Long.parseLong(env.getOrDefault("ANCHOR_MAX_AGE_SECONDS", "3600"));
int minAnchorSamples = Integer.parseInt(env.getOrDefault("MIN_ANCHOR_SAMPLES", "3"));
long deadlineSeconds = Long.parseLong(env.getOrDefault("DEADLINE_SECONDS", "300"));
int gasPriceMultiplierBps = Integer.parseInt(env.getOrDefault("GAS_PRICE_MULTIPLIER_BPS", "12000"));
java.math.BigInteger maxGasPriceWei = new java.math.BigInteger(
        env.getOrDefault("MAX_GAS_PRICE_WEI", "10000000000"));
java.math.BigInteger minKeeperBalanceWei = new java.math.BigInteger(
        env.getOrDefault("MIN_KEEPER_BALANCE_WEI", "3000000000000000"));
long pendingRetrySeconds = Long.parseLong(env.getOrDefault("PENDING_RETRY_SECONDS", "90"));

KeeperCore.Config cfg = new KeeperCore.Config(chainId, coordinator, keeperAddress,
        discoveryPageSize, maxAssetsPerRun, checkIntervalSeconds, ammFeeBps,
        taxMaxReserveBps, slippageBps, maxPriceDeviationBps, anchorMinAgeSeconds,
        anchorMaxAgeSeconds, minAnchorSamples, deadlineSeconds, gasPriceMultiplierBps,
        maxGasPriceWei, minKeeperBalanceWei, pendingRetrySeconds);
```

这段只展示变量声明；正式服务还要按 `keeper/src/config.ts` 校验整数范围、非零地址、HTTPS URL、`chainId ∈ {56,97}`、`anchorMaxAgeSeconds > anchorMinAgeSeconds`，并要求主网读 RPC 与 MEV 保护发送 RPC 不同。不能把测试网 ABI/地址和主网地址混用。

```java
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

public final class KeeperCore {
    private KeeperCore() {}

    // bps 的分母：10000 = 100%。所有报价与阈值都使用整数运算。
    private static final BigInteger BPS = BigInteger.valueOf(10_000L);
    // LP 回购模式用单次预算的 49.90% 先购买代币。
    private static final BigInteger LP_SWAP_BPS = BigInteger.valueOf(4_990L);
    // 旧版固定金额金库额外校验：输入不得超过主池 WBNB 储备的 1%。
    private static final BigInteger LEGACY_BUYBACK_RESERVE_BPS = BigInteger.valueOf(100L);
    // BigInteger 零值的公共常量。
    private static final BigInteger ZERO = BigInteger.ZERO;

    public enum Kind { TAX, LIQUIDITY, BUYBACK }

    /** 所有秒数单位都是秒；所有金额单位都是链上最小单位（wei / token base unit）。 */
    public record Config(
            int chainId,                  // BSC 主网 56；BSC 测试网 97。
            String coordinator,           // 已核验部署的 CoordinatorFactory 地址。
            String keeperAddress,         // 仅有 KEEPER_ROLE 的签名钱包地址。
            int discoveryPageSize,        // 默认 8；每轮发现多少枚代币。
            int maxAssetsPerRun,          // 默认 8；每轮最多巡检多少枚代币。
            long checkIntervalSeconds,    // 默认 60；巡检完后再次到期的间隔。
            int ammFeeBps,                // 默认 25；Pancake V2 池交易费假设。
            int taxMaxReserveBps,         // 默认 30；单笔清税/加池的代币储备上限 0.3%。
            int slippageBps,              // 默认 100；输出/加池允许的 1% 偏差。
            int maxPriceDeviationBps,     // 默认 300；当前价相对历史锚点最大偏差 3%。
            long anchorMinAgeSeconds,     // 默认 300；历史样本至少 5 分钟前。
            long anchorMaxAgeSeconds,     // 默认 3600；历史样本最多 60 分钟前。
            int minAnchorSamples,         // 默认 3；不足时只采样，不执行。
            long deadlineSeconds,         // 默认 300；交易 deadline = 当前区块时间 + 5 分钟。
            int gasPriceMultiplierBps,    // 默认 12000；Gas 价格乘数 1.2 倍。
            BigInteger maxGasPriceWei,    // 默认 10_000_000_000 wei；超过则不发交易。
            BigInteger minKeeperBalanceWei, // 默认 0.003 BNB；付 Gas 后仍要保留的余额。
            long pendingRetrySeconds      // 默认 90；待确认交易重播间隔。
    ) {}

    public record Asset(
            int chainId,                  // 所属 BSC 网络 ID。
            String token,                 // 代币地址。
            String taxProcessor,          // 该代币的 TaxProcessor 地址。
            String vault,                 // 金库地址；普通代币为 null。
            String pair,                  // 主池地址；必须是 token/WBNB 池。
            String wbnb,                  // TaxProcessor 记录的 WBNB 地址。
            String status,                // 后端状态，通常为 active。
            long nextCheckAt              // 下次巡检 Unix 秒。
    ) {}

    public record Sample(
            long blockNumber,             // 采样区块号，用于去重和追踪。
            long sampledAt,               // 采样区块的 Unix 秒时间戳。
            BigInteger reserveToken,      // 主池的代币储备，按 token0/token1 归一化。
            BigInteger reserveWbnb        // 主池的 WBNB 储备，按 token0/token1 归一化。
    ) {}

    public record PoolState(
            int state,                    // poolState() 第 1 个字段；2/3 为有效税率状态。
            int buyTaxRate,               // 买入税，单位 bps。
            int sellTaxRate,              // 卖出税，单位 bps。
            long taxExpirationTime        // 税率到期的 Unix 秒。
    ) {}

    public record FeeConfig(
            int marketBps,               // 市场份额。
            int deflationBps,            // 销毁份额。
            int lpBps,                   // 自动加池份额。
            int dividendBps,             // 分红份额；整数除法的尾差实际上归协议费。
            int feeRate,                 // 处理器先扣除的费率。
            int commissionBps            // fee 之后先扣除的佣金率。
    ) {}

    public record VaultState(
            int version,                  // 0 无金库；1 旧固定金额 ABI；2 新动态金额 ABI。
            BigInteger executableAmount, // 该区块可执行 BNB 输入；非 buybackAmount 原始上限。
            int readiness,                // 0=Ready；1..5=新版等待原因；6=旧版超储备上限。
            int mode                     // 1=LP 买毁，其余当前模式按 Token 买毁报价。
    ) {}

    public record Snapshot(
            Asset asset,                  // 当前巡检的资产登记信息。
            long blockNumber,            // 本次所有 eth_call 固定的区块号。
            long blockTimestamp,         // 本次区块时间，用于税期和 deadline。
            Sample sample,               // 当前主池储备。
            PoolState poolState,         // 当前代币税率状态。
            BigInteger pendingTax,       // TaxProcessor.pendingTaxTokens()。
            FeeConfig feeConfig,         // TaxProcessor.feeConfigV2()。
            BigInteger lpTokenBalance,   // TaxProcessor.lpTokenBalance()。
            BigInteger lpQuoteBalance,   // TaxProcessor.lpQuoteBalance()。
            BigInteger pairTotalSupply,  // Pair.totalSupply()，计算预期 LP 份额。
            VaultState vault             // 无金库时为 version=0、金额=0 的值对象。
    ) {}

    /** args 顺序必须严格按第 6 节的 ABI 签名编码；不得自行重排。 */
    public record Plan(
            Kind kind,                   // tax / liquidity / buyback。
            String token,                // 哪枚代币产生该任务。
            String target,               // TaxProcessor 或 BuybackVault 地址。
            String signature,            // 完整 ABI 签名，用于区分同名回购函数的两种参数列表。
            List<BigInteger> args,       // ABI 入参，按声明顺序排列。
            long snapshotBlock,          // 规划所依据的区块号，仅供审计；发前会重读。
            BigInteger amountIn,         // 此次名义输入：tokenAmount 或 BNB 输入。
            BigInteger currentQuote,     // 当前池储备算出的输出/配对报价。
            BigInteger anchorQuote,      // 历史有效样本报价的中位数。
            BigInteger minimumOut,       // 第一重最低输出。
            BigInteger secondaryMinOut,  // 加池 LP 最低量或回购 LP 半仓代币最低量。
            long deadline               // 当前区块时间 + 配置的 deadlineSeconds。
    ) {}

    /** 只接受非负整数；转换成 BigInteger 后不发生浮点误差。 */
    private static BigInteger bi(long value) {
        if (value < 0L) throw new IllegalArgumentException("negative integer");
        return BigInteger.valueOf(value);
    }

    /** 两个非负链上整数中的较小值。 */
    private static BigInteger min(BigInteger left, BigInteger right) {
        return left.min(right);
    }

    /** 从排序后的有效历史报价取中位数；偶数个样本时向下取整。 */
    private static BigInteger median(List<BigInteger> values) {
        if (values.isEmpty()) throw new IllegalArgumentException("no anchor quotes");
        List<BigInteger> sorted = new ArrayList<>(values); // 不修改调用者传入的历史报价。
        sorted.sort(Comparator.naturalOrder());            // BigInteger 的自然升序。
        int middle = sorted.size() / 2;                    // 中位元素下标。
        if (sorted.size() % 2 == 1) return sorted.get(middle);
        BigInteger left = sorted.get(middle - 1);          // 偶数个样本的左中值。
        BigInteger right = sorted.get(middle);             // 偶数个样本的右中值。
        return left.add(right).divide(BigInteger.TWO);
    }

    /** 模拟 Fee-on-Transfer：进池或出池时名义数量与实际到账不同。 */
    private static BigInteger afterTransferTax(BigInteger amount, int taxBps) {
        if (amount.signum() < 0 || taxBps < 0 || taxBps > 10_000) {
            throw new IllegalArgumentException("invalid transfer tax");
        }
        return amount.multiply(BPS.subtract(bi(taxBps))).divide(BPS);
    }

    /** Pancake V2 恒定乘积报价；reserveIn/reserveOut 的方向由调用者指定。 */
    private static BigInteger amountOut(
            BigInteger amountIn, BigInteger reserveIn, BigInteger reserveOut, int feeBps) {
        if (amountIn.signum() <= 0 || reserveIn.signum() <= 0 || reserveOut.signum() <= 0) return ZERO;
        if (feeBps < 0 || feeBps >= 10_000) throw new IllegalArgumentException("invalid AMM fee");
        BigInteger inputWithFee = amountIn.multiply(BPS.subtract(bi(feeBps)));
        BigInteger numerator = inputWithFee.multiply(reserveOut);
        BigInteger denominator = reserveIn.multiply(BPS).add(inputWithFee);
        return numerator.divide(denominator);
    }

    /** 当前报价与历史锚点报价的绝对偏差，分母固定使用锚点。 */
    private static BigInteger deviationBps(BigInteger current, BigInteger anchor) {
        if (current.signum() < 0 || anchor.signum() <= 0) {
            throw new IllegalArgumentException("invalid price deviation");
        }
        BigInteger difference = current.subtract(anchor).abs();
        return difference.multiply(BPS).divide(anchor);
    }

    /**
     * 输出下限：偏差超过 3% 则放弃；否则取“当前报价-1%”与“历史报价-1%”的较大值。
     * 注意是 max，不是 min。取 min 会降低对被操纵即时储备的防护。
     */
    private static Optional<BigInteger> protectedMinimum(
            Config cfg, BigInteger currentQuote, BigInteger anchorQuote) {
        if (currentQuote.signum() <= 0 || anchorQuote.signum() <= 0) return Optional.empty();
        BigInteger deviation = deviationBps(currentQuote, anchorQuote);
        if (deviation.compareTo(bi(cfg.maxPriceDeviationBps())) > 0) return Optional.empty();
        BigInteger currentFloor = currentQuote.multiply(BPS.subtract(bi(cfg.slippageBps()))).divide(BPS);
        BigInteger anchorFloor = anchorQuote.multiply(BPS.subtract(bi(cfg.slippageBps()))).divide(BPS);
        BigInteger minimum = currentFloor.max(anchorFloor);
        return minimum.signum() > 0 ? Optional.of(minimum) : Optional.empty();
    }

    /** poolState=2/3 且当前区块时间尚未超过 taxExpirationTime 时，税率才有效。 */
    private static int activeTaxRate(PoolState pool, long blockTimestamp, boolean buy) {
        boolean taxState = pool.state() == 2 || pool.state() == 3;
        boolean beforeExpiry = blockTimestamp <= pool.taxExpirationTime();
        if (!taxState || !beforeExpiry) return 0;
        return buy ? pool.buyTaxRate() : pool.sellTaxRate();
    }

    /**
     * 清税时不是把全部 amountIn 卖出：先按处理器规则分账，销毁及半边 LP 留作代币。
     * 各通道整数除法的尾差归协议 feeTokens；必须与 TaxProcessor._splitTax 的取整顺序一致。
     */
    private static BigInteger taxSwapAmount(BigInteger amount, FeeConfig feeConfig) {
        BigInteger fee = amount.multiply(bi(feeConfig.feeRate())).divide(BPS);
        BigInteger afterFee = amount.subtract(fee);
        BigInteger commission = afterFee.multiply(bi(feeConfig.commissionBps())).divide(BPS);
        BigInteger distributable = afterFee.subtract(commission);
        BigInteger market = distributable.multiply(bi(feeConfig.marketBps())).divide(BPS);
        BigInteger deflation = distributable.multiply(bi(feeConfig.deflationBps())).divide(BPS);
        BigInteger lp = distributable.multiply(bi(feeConfig.lpBps())).divide(BPS);
        BigInteger dividend = distributable.multiply(bi(feeConfig.dividendBps())).divide(BPS);
        BigInteger dust = distributable.subtract(market).subtract(deflation).subtract(lp).subtract(dividend);
        fee = fee.add(dust);
        return fee.add(commission).add(market).add(lp.subtract(lp.divide(BigInteger.TWO))).add(dividend);
    }

    /** 清税卖出：先扣卖出税，再按 token -> WBNB 方向套 AMM 公式。 */
    private static BigInteger quoteTax(BigInteger swapAmount, Sample sample, int sellTax, Config cfg) {
        BigInteger pairInput = afterTransferTax(swapAmount, sellTax);
        return amountOut(pairInput, sample.reserveToken(), sample.reserveWbnb(), cfg.ammFeeBps());
    }

    /** 金库回购：WBNB -> token；先算池输出，再扣买入税，得到金库实际到账。 */
    private static BigInteger quoteBuyback(BigInteger bnbIn, Sample sample, int buyTax, Config cfg) {
        BigInteger grossToken = amountOut(bnbIn, sample.reserveWbnb(), sample.reserveToken(), cfg.ammFeeBps());
        return afterTransferTax(grossToken, buyTax);
    }

    /** 自动加池：所需 WBNB = 实际进入池子的 token 数量 × WBNB 储备 / token 储备。 */
    private static BigInteger quoteLiquidity(BigInteger actualToken, Sample sample) {
        if (actualToken.signum() <= 0 || sample.reserveToken().signum() <= 0
                || sample.reserveWbnb().signum() <= 0) return ZERO;
        return actualToken.multiply(sample.reserveWbnb()).divide(sample.reserveToken());
    }

    /**
     * 核心规划器。history 必须是 5～60 分钟前、储备均非 0、最多 15 条的有效样本。
     * 返回空表示条件不足或价格策略拒绝；没有交易、也不应该靠猜测补默认参数。
     */
    public static Optional<Plan> plan(Config cfg, Snapshot s, List<Sample> history, Kind kind) {
        if (history.size() < cfg.minAnchorSamples()) return Optional.empty();
        if (s.sample().reserveToken().signum() == 0 || s.sample().reserveWbnb().signum() == 0) {
            return Optional.empty();
        }
        int buyTax = activeTaxRate(s.poolState(), s.blockTimestamp(), true);
        int sellTax = activeTaxRate(s.poolState(), s.blockTimestamp(), false);
        long deadline = Math.addExact(s.blockTimestamp(), cfg.deadlineSeconds());
        return switch (kind) {
            case TAX -> planTax(cfg, s, history, sellTax, deadline);
            case LIQUIDITY -> planLiquidity(cfg, s, history, sellTax, deadline);
            case BUYBACK -> planBuyback(cfg, s, history, buyTax, deadline);
        };
    }

    private static Optional<Plan> planTax(
            Config cfg, Snapshot s, List<Sample> history, int sellTax, long deadline) {
        if (s.pendingTax().signum() == 0) return Optional.empty();
        BigInteger reserveCap = s.sample().reserveToken().multiply(bi(cfg.taxMaxReserveBps())).divide(BPS);
        BigInteger amountIn = min(s.pendingTax(), reserveCap);
        if (amountIn.signum() == 0) return Optional.empty();
        BigInteger swapAmount = taxSwapAmount(amountIn, s.feeConfig());
        BigInteger currentQuote = ZERO;
        BigInteger anchorQuote = ZERO;
        BigInteger minimumOut = ZERO;
        if (swapAmount.signum() > 0) {
            currentQuote = quoteTax(swapAmount, s.sample(), sellTax, cfg);
            List<BigInteger> historicalQuotes = history.stream()
                    .map(old -> quoteTax(swapAmount, old, sellTax, cfg)).toList();
            anchorQuote = median(historicalQuotes);
            Optional<BigInteger> protectedOut = protectedMinimum(cfg, currentQuote, anchorQuote);
            if (protectedOut.isEmpty()) return Optional.empty();
            minimumOut = protectedOut.get();
        }
        // 若没有任何 swap 部分，合约允许 minQuoteOut=0；不能强行报一个非零输出。
        List<BigInteger> args = List.of(amountIn, minimumOut, bi(deadline));
        return Optional.of(new Plan(Kind.TAX, s.asset().token(), s.asset().taxProcessor(),
                "processPendingTax(uint256,uint256,uint64)", args, s.blockNumber(), amountIn, currentQuote,
                anchorQuote, minimumOut, ZERO, deadline));
    }

    private static Optional<Plan> planLiquidity(
            Config cfg, Snapshot s, List<Sample> history, int sellTax, long deadline) {
        if (s.lpTokenBalance().signum() == 0 || s.lpQuoteBalance().signum() == 0
                || s.pairTotalSupply().signum() == 0) return Optional.empty();
        BigInteger reserveCap = s.sample().reserveToken().multiply(bi(cfg.taxMaxReserveBps())).divide(BPS);
        BigInteger tokenAmount = min(s.lpTokenBalance(), reserveCap);
        BigInteger actualToken = afterTransferTax(tokenAmount, sellTax);
        BigInteger neededQuote = quoteLiquidity(actualToken, s.sample());
        if (neededQuote.compareTo(s.lpQuoteBalance()) > 0) {
            BigInteger actualTokenCap = s.lpQuoteBalance().multiply(s.sample().reserveToken())
                    .divide(s.sample().reserveWbnb());
            BigInteger taxDenominator = BPS.subtract(bi(sellTax));
            if (taxDenominator.signum() == 0) return Optional.empty();
            tokenAmount = actualTokenCap.multiply(BPS).divide(taxDenominator);
            tokenAmount = min(tokenAmount, s.lpTokenBalance());
            actualToken = afterTransferTax(tokenAmount, sellTax);
            neededQuote = quoteLiquidity(actualToken, s.sample());
        }
        if (tokenAmount.signum() == 0 || actualToken.signum() == 0 || neededQuote.signum() == 0
                || neededQuote.compareTo(s.lpQuoteBalance()) > 0) return Optional.empty();
        BigInteger finalActualToken = actualToken; // Stream lambda 捕获本次最终实际到账代币量。
        List<BigInteger> historicalQuotes = history.stream()
                .map(old -> quoteLiquidity(finalActualToken, old)).toList();
        BigInteger anchorQuote = median(historicalQuotes);
        if (anchorQuote.signum() == 0
                || deviationBps(neededQuote, anchorQuote).compareTo(bi(cfg.maxPriceDeviationBps())) > 0) {
            return Optional.empty();
        }
        BigInteger minQuote = neededQuote.multiply(BPS.subtract(bi(cfg.slippageBps()))).divide(BPS);
        BigInteger maxQuote = neededQuote.multiply(BPS.add(bi(cfg.slippageBps()))).divide(BPS)
                .add(BigInteger.ONE);
        BigInteger tokenLp = actualToken.multiply(s.pairTotalSupply()).divide(s.sample().reserveToken());
        BigInteger quoteLp = neededQuote.multiply(s.pairTotalSupply()).divide(s.sample().reserveWbnb());
        BigInteger expectedLp = min(tokenLp, quoteLp);
        BigInteger minLiquidity = expectedLp.multiply(BPS.subtract(bi(cfg.slippageBps()))).divide(BPS);
        if (minQuote.signum() == 0 || minLiquidity.signum() == 0) return Optional.empty();
        List<BigInteger> args = List.of(tokenAmount, minQuote, maxQuote, minLiquidity, bi(deadline));
        return Optional.of(new Plan(Kind.LIQUIDITY, s.asset().token(), s.asset().taxProcessor(),
                "addPendingLiquidity(uint256,uint256,uint256,uint256,uint64)", args, s.blockNumber(), tokenAmount, neededQuote,
                anchorQuote, minQuote, minLiquidity, deadline));
    }

    private static Optional<Plan> planBuyback(
            Config cfg, Snapshot s, List<Sample> history, int buyTax, long deadline) {
        VaultState vault = s.vault();
        if (s.asset().vault() == null || vault.version() == 0 || vault.readiness() != 0) {
            return Optional.empty();
        }
        BigInteger bnbIn = vault.executableAmount();
        if (bnbIn.signum() == 0) return Optional.empty();
        BigInteger currentQuote = quoteBuyback(bnbIn, s.sample(), buyTax, cfg);
        List<BigInteger> historicalQuotes = history.stream()
                .map(old -> quoteBuyback(bnbIn, old, buyTax, cfg)).toList();
        BigInteger anchorQuote = median(historicalQuotes);
        Optional<BigInteger> protectedToken = protectedMinimum(cfg, currentQuote, anchorQuote);
        if (protectedToken.isEmpty()) return Optional.empty();
        BigInteger minTokenOut = protectedToken.get();
        BigInteger minLpTokenOut = ZERO;
        if (vault.mode() == 1) {
            BigInteger lpInput = bnbIn.multiply(LP_SWAP_BPS).divide(BPS);
            BigInteger currentLpQuote = quoteBuyback(lpInput, s.sample(), buyTax, cfg);
            List<BigInteger> historicalLpQuotes = history.stream()
                    .map(old -> quoteBuyback(lpInput, old, buyTax, cfg)).toList();
            BigInteger anchorLpQuote = median(historicalLpQuotes);
            Optional<BigInteger> protectedLp = protectedMinimum(cfg, currentLpQuote, anchorLpQuote);
            if (protectedLp.isEmpty()) return Optional.empty();
            minLpTokenOut = protectedLp.get();
        }
        // 新金库：expectedBnbIn, minTokenOut, minLpTokenOut, deadline。
        // 旧金库：没有 expectedBnbIn 参数，固定金额由旧合约内的 buybackAmount 决定。
        List<BigInteger> args = vault.version() == 1
                ? List.of(minTokenOut, minLpTokenOut, bi(deadline))
                : List.of(bnbIn, minTokenOut, minLpTokenOut, bi(deadline));
        return Optional.of(new Plan(Kind.BUYBACK, s.asset().token(), s.asset().vault(),
                vault.version() == 1
                        ? "executeBuyback(uint256,uint256,uint64)"
                        : "executeBuyback(uint256,uint256,uint256,uint64)",
                args, s.blockNumber(), bnbIn, currentQuote, anchorQuote,
                minTokenOut, minLpTokenOut, deadline));
    }

    /** 旧固定金额金库没有 previewBuyback；canExecute=false 时用 1% 储备上限诊断原因。 */
    public static VaultState legacyVaultState(
            boolean canExecute, BigInteger fixedAmount, int mode, Sample sample) {
        int readiness;
        BigInteger executableAmount = canExecute ? fixedAmount : ZERO;
        if (canExecute) readiness = 0;
        else if (sample.reserveToken().signum() == 0 || sample.reserveWbnb().signum() == 0) readiness = 4;
        else {
            BigInteger reserveCap = sample.reserveWbnb().multiply(LEGACY_BUYBACK_RESERVE_BPS).divide(BPS);
            readiness = fixedAmount.compareTo(reserveCap) > 0 ? 6 : 3;
        }
        return new VaultState(1, executableAmount, readiness, mode);
    }
}
```

`Plan.signature` 保存完整 ABI 签名；旧新金库的链上方法都叫 `executeBuyback`，但参数数量不同，selector 也不同。金额与样本均是最小单位的整数；不要在计算中格式化成“BNB”或“枚”再转回。

## 5. 定时调度器与签名器：逐步骤 Java 骨架

这一段描述适配器之间的调用契约。接口名称可以按后端项目改；每个方法的语义不能省略。

```java
// 示例类：后端可放入 Spring @Service；@Scheduled 只负责调用 runOnce。
final class KeeperRunner {
    private final KeeperCore.Config cfg;     // 启动时校验过的 BSC/Keeper 参数。
    private final ChainPort chain;            // RPC + ABI 读取/编码适配器。
    private final StorePort store;            // 数据库事务与巡检队列适配器。
    private final SignerPort signer;          // 单钱包持久化签名/广播适配器。

    KeeperRunner(KeeperCore.Config cfg, ChainPort chain, StorePort store, SignerPort signer) {
        this.cfg = cfg;
        this.chain = chain;
        this.store = store;
        this.signer = signer;
    }

    // 每次定时触发生成一个 runId；同一轮失败重试时必须沿用原 runId。
    void runOnce(String runId, long nowSeconds) {
        chain.assertEnvironment(cfg); // 检查双 RPC 的 chainId、Coordinator 代码、KEEPER_ROLE。
        signer.reconcilePending();     // 先处理旧 nonce；不要先签下一笔交易。

        long total = chain.getTotalTokenCount(cfg.coordinator());
        long savedCursor = store.discoveryCursor(cfg.chainId());
        long offset = savedCursor >= total ? 0L : savedCursor;
        long remaining = total - offset;
        long limit = Math.min(remaining, cfg.discoveryPageSize());
        if (limit > 0L) {
            List<String> tokens = chain.getTokenPage(cfg.coordinator(), offset, limit);
            for (String token : tokens) {
                KeeperCore.Asset asset = chain.readAndVerifyAsset(cfg.chainId(), cfg.coordinator(), token);
                store.upsertAssetWithoutResettingNextCheck(asset); // 已登记币不能每次都重置到期时间。
            }
            long nextCursor = offset + tokens.size() >= total ? 0L : offset + tokens.size();
            store.saveDiscoveryCursor(cfg.chainId(), nextCursor);
        }

        List<KeeperCore.Asset> due = store.findDueActive(
                cfg.chainId(), nowSeconds, cfg.maxAssetsPerRun());
        for (KeeperCore.Asset asset : due) {
            long checkedAt = store.currentUnixSeconds(); // 实际开始检查时间，不复用整个批次的时间。
            List<KeeperCore.Plan> plans;
            try {
                KeeperCore.Snapshot snapshot = chain.inspectAtOneBlock(asset);
                store.insertSampleIfAbsent(cfg.chainId(), asset.pair(), snapshot.sample());
                store.recordVaultReadiness(asset, snapshot.vault(), checkedAt);
                long oldest = snapshot.blockTimestamp() - cfg.anchorMaxAgeSeconds();
                long newest = snapshot.blockTimestamp() - cfg.anchorMinAgeSeconds();
                List<KeeperCore.Sample> history = store.loadValidSamples(
                        cfg.chainId(), asset.pair(), oldest, newest, 15);
                plans = new java.util.ArrayList<>();
                for (KeeperCore.Kind kind : KeeperCore.Kind.values()) {
                    KeeperCore.plan(cfg, snapshot, history, kind).ifPresent(plans::add);
                }
            } catch (RuntimeException readOrPlanError) {
                // 读取/规划失败只影响该币；留下错误以便定位，之后再巡检。
                store.markChecked(asset, checkedAt,
                        checkedAt + cfg.checkIntervalSeconds(), readOrPlanError.getMessage());
                continue;
            }

            for (KeeperCore.Plan candidate : plans) {
                // jobId 在同一个 runId 内固定；签名器必须先查已签名记录，禁止重复签。
                String jobId = runId + ":" + candidate.kind() + ":" + asset.token().toLowerCase();
                // 签名器重新读链、重新规划；candidate.args 不能直接用于最终交易。
                signer.executeReplanned(jobId, asset, candidate.kind());
            }
            store.markChecked(asset, checkedAt, checkedAt + cfg.checkIntervalSeconds(), null);
        }
    }

    interface ChainPort {
        void assertEnvironment(KeeperCore.Config cfg);
        long getTotalTokenCount(String coordinator);
        List<String> getTokenPage(String coordinator, long offset, long limit);
        KeeperCore.Asset readAndVerifyAsset(int chainId, String coordinator, String token);
        KeeperCore.Snapshot inspectAtOneBlock(KeeperCore.Asset asset);
    }

    interface StorePort {
        long discoveryCursor(int chainId);
        void saveDiscoveryCursor(int chainId, long cursor);
        void upsertAssetWithoutResettingNextCheck(KeeperCore.Asset asset);
        KeeperCore.Asset getActiveAsset(int chainId, String token); // 不存在或停用时返回 null。
        List<KeeperCore.Asset> findDueActive(int chainId, long nowSeconds, int limit);
        void insertSampleIfAbsent(int chainId, String pair, KeeperCore.Sample sample);
        List<KeeperCore.Sample> loadValidSamples(
                int chainId, String pair, long oldest, long newest, int limit);
        void recordVaultReadiness(KeeperCore.Asset asset, KeeperCore.VaultState vault, long now);
        void markChecked(KeeperCore.Asset asset, long checkedAt, long nextCheckAt, String error);
        long currentUnixSeconds();
    }

    interface SignerPort {
        void reconcilePending();
        void executeReplanned(String jobId, KeeperCore.Asset asset, KeeperCore.Kind kind);
    }
}
```

如果后端用 Spring，Cron 入口只负责把本轮任务放入**持久化**队列，不直接在注解方法里无限重试。队列消费者保留同一个 `runId`，但每次尝试都传入当时的 Unix 秒调用 `runner.runOnce(runId, nowSeconds)`；`requestedAt` 仅用于审计。[Spring 官方调度文档](https://docs.spring.io/spring-framework/reference/integration/scheduling.html)说明 `@Scheduled` 的 Cron 使用六个字段，并可设置 `zone`：

```java
@org.springframework.stereotype.Component
final class KeeperCron {
    private final RunQueue runQueue; // 数据库或消息队列；按网络限制单轮并发。

    KeeperCron(RunQueue runQueue) {
        this.runQueue = runQueue;
    }

    @org.springframework.scheduling.annotation.Scheduled(cron = "0 * * * * *", zone = "UTC")
    public void enqueueOneRun() {
        String runId = java.util.UUID.randomUUID().toString();
        long requestedAt = java.time.Instant.now().getEpochSecond();
        runQueue.enqueue(runId, requestedAt);
    }

    interface RunQueue {
        void enqueue(String runId, long requestedAt);
    }
}
```

Spring 项目还需启用 `@EnableScheduling`，并确保多实例部署时只有一个实例成功创建本轮 `runId`，或由队列做全局去重；消费者必须持久化失败和重试次数。

下面是签名器的 Java 参考代码。`RpcPort` 由 web3j/JSON-RPC 实现，`SignerJobStore` 由数据库实现，`RawSigner` 使用密钥服务或 web3j 离线签名实现。`withWalletLock` 必须对多实例有效；锁内的“检查旧任务 → 签新交易 → 插入待发送任务”不能被另一个实例交错执行。网络较慢时需要可续租的分布式锁或数据库方案，不能只依赖 JVM `synchronized`。

```java
import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import java.util.function.Supplier;

final class KeeperSigner implements KeeperRunner.SignerPort {
    private static final BigInteger BPS = BigInteger.valueOf(10_000L);
    private final KeeperCore.Config cfg;           // 当前网络和价格/Gas 策略。
    private final KeeperRunner.ChainPort chain;    // 发前同区块快照读取器。
    private final KeeperRunner.StorePort samples;  // 资产登记表和历史储备表。
    private final SignerJobStore jobs;             // 持久化签名任务表及钱包级锁。
    private final RpcPort rpc;                    // 只读 RPC 和专用发送 RPC 的封装。
    private final RawSigner rawSigner;            // 在受控密钥环境中离线签名。

    KeeperSigner(KeeperCore.Config cfg, KeeperRunner.ChainPort chain,
            KeeperRunner.StorePort samples, SignerJobStore jobs, RpcPort rpc, RawSigner rawSigner) {
        this.cfg = cfg;
        this.chain = chain;
        this.samples = samples;
        this.jobs = jobs;
        this.rpc = rpc;
        this.rawSigner = rawSigner;
    }

    record TxJob(
            String jobId, String kind, String token, String target,
            String status, BigInteger nonce, String txHash, String rawTx,
            BigInteger gasPrice, long deadline, long submittedAt, int attempts) {}

    record Receipt(boolean success, long blockNumber) {}
    record SignedRaw(String rawTx, String txHash) {}
    record Reconcile(boolean busy, BigInteger replacementNonce,
            BigInteger minReplacementGasPrice, String replacesJobId) {
        static Reconcile clear() { return new Reconcile(false, null, BigInteger.ZERO, null); }
        static Reconcile busyNow() { return new Reconcile(true, null, BigInteger.ZERO, null); }
    }

    @Override
    public void reconcilePending() {
        jobs.withWalletLock(cfg.chainId(), cfg.keeperAddress(), () -> {
            Optional<TxJob> active = jobs.findActive(); // 唯一 prepared/submitted 任务。
            active.ifPresent(job -> reconcile(job, false));
            return null;
        });
    }

    @Override
    public void executeReplanned(String jobId, KeeperCore.Asset candidate, KeeperCore.Kind kind) {
        jobs.withWalletLock(cfg.chainId(), cfg.keeperAddress(), () -> {
            Optional<TxJob> previous = jobs.findById(jobId);
            if (previous.isPresent()) return null; // 同一任务永远不重复签名。

            Optional<TxJob> active = jobs.findActive();
            Reconcile state = active.isPresent()
                    ? reconcile(active.get(), true) : Reconcile.clear();
            if (state.busy()) return null; // 钱包仍有未解决的 nonce，等待下轮。

            KeeperCore.Asset asset = samples.getActiveAsset(cfg.chainId(), candidate.token());
            if (asset == null) return null; // 代币已被后端停用。
            String expectedTarget = kind == KeeperCore.Kind.BUYBACK
                    ? asset.vault() : asset.taxProcessor();
            String originallyPlannedTarget = kind == KeeperCore.Kind.BUYBACK
                    ? candidate.vault() : candidate.taxProcessor();
            if (expectedTarget == null || originallyPlannedTarget == null
                    || !expectedTarget.equalsIgnoreCase(originallyPlannedTarget)) return null;

            KeeperCore.Snapshot fresh = chain.inspectAtOneBlock(asset); // 不能沿用巡检开始时的快照。
            long oldest = fresh.blockTimestamp() - cfg.anchorMaxAgeSeconds();
            long newest = fresh.blockTimestamp() - cfg.anchorMinAgeSeconds();
            List<KeeperCore.Sample> history = samples.loadValidSamples(
                    cfg.chainId(), asset.pair(), oldest, newest, 15);
            Optional<KeeperCore.Plan> replanned = KeeperCore.plan(cfg, fresh, history, kind);
            if (replanned.isEmpty()) return null;
            KeeperCore.Plan plan = replanned.get();
            if (!plan.target().equalsIgnoreCase(expectedTarget)) return null;

            String data = rpc.encodeAbi(plan.signature(), plan.args());
            // eth_call(from=Keeper,to=目标,data=重算参数,value=0,block=latest)。
            if (!rpc.simulate(cfg.keeperAddress(), plan.target(), data)) return null;
            BigInteger estimate = rpc.estimateGas(cfg.keeperAddress(), plan.target(), data);
            if (estimate.signum() <= 0) return null;
            BigInteger gasLimit = estimate.multiply(BigInteger.valueOf(12L))
                    .divide(BigInteger.TEN).add(BigInteger.ONE);
            BigInteger networkGasPrice = rpc.gasPrice();
            BigInteger gasPrice = networkGasPrice.multiply(
                    BigInteger.valueOf(cfg.gasPriceMultiplierBps())).divide(BPS);
            gasPrice = gasPrice.max(state.minReplacementGasPrice());
            if (gasPrice.compareTo(cfg.maxGasPriceWei()) > 0) {
                jobs.alert("gas-price-high", "Gas price exceeds configured limit");
                return null;
            }
            BigInteger walletBalance = rpc.balance(cfg.keeperAddress());
            BigInteger requiredBalance = gasLimit.multiply(gasPrice)
                    .add(cfg.minKeeperBalanceWei());
            if (walletBalance.compareTo(requiredBalance) < 0) {
                jobs.alert("keeper-balance-low", "Keeper BNB balance is too low");
                return null;
            }
            BigInteger nonce = state.replacementNonce() == null
                    ? rpc.pendingNonce(cfg.keeperAddress()) : state.replacementNonce();
            SignedRaw signed = rawSigner.signLegacyEip155(
                    cfg.chainId(), cfg.keeperAddress(), nonce, gasPrice, gasLimit,
                    plan.target(), data, BigInteger.ZERO);
            long now = samples.currentUnixSeconds();
            TxJob prepared = new TxJob(jobId, kind.name(), asset.token(), plan.target(),
                    "prepared", nonce, signed.txHash(), signed.rawTx(),
                    gasPrice, plan.deadline(), now, 0);

            // 最重要的顺序：先提交数据库，再调用 sendRawTransaction。
            // 替换旧 nonce 时，这一步与把旧任务标记 replaced 必须在同一 DB 事务中完成。
            jobs.insertPreparedReplacing(prepared, state.replacesJobId());
            try {
                String broadcastHash = rpc.broadcastProtected(signed.rawTx());
                if (!signed.txHash().equalsIgnoreCase(broadcastHash)) {
                    throw new IllegalStateException("send RPC returned unexpected tx hash");
                }
                jobs.markSubmitted(jobId, now);
            } catch (RuntimeException uncertainBroadcast) {
                // 已签名交易留在 prepared，下一轮先查回执并重播同一 rawTx。
                jobs.note(jobId, "initial broadcast uncertain: " + uncertainBroadcast.getMessage());
            }
            return null;
        });
    }

    /** 返回 busy，或返回可给下一笔安全替换交易使用的 nonce 和 Gas 底价。 */
    private Reconcile reconcile(TxJob job, boolean allowReplacement) {
        long now = samples.currentUnixSeconds();
        // 即使数据库仍是 prepared，原始交易也可能已广播并上链；先查回执。
        Optional<Receipt> receipt = rpc.receipt(job.txHash());
        if (receipt.isPresent()) {
            Receipt mined = receipt.get();
            jobs.markFinal(job.jobId(), mined.success() ? "confirmed" : "reverted",
                    mined.blockNumber());
            if (!mined.success()) jobs.alert("tx-reverted:" + job.jobId(), "Keeper tx reverted");
            return Reconcile.clear();
        }

        if (job.status().equals("prepared") && now <= job.deadline()) {
            try {
                String broadcastHash = rpc.broadcastProtected(job.rawTx());
                if (!broadcastHash.equalsIgnoreCase(job.txHash())) {
                    throw new IllegalStateException("send RPC returned unexpected tx hash");
                }
                jobs.markSubmitted(job.jobId(), now);
            } catch (RuntimeException uncertainBroadcast) {
                jobs.note(job.jobId(), "prepared broadcast uncertain: " + uncertainBroadcast.getMessage());
            }
            return Reconcile.busyNow();
        }
        if (job.status().equals("submitted")
                && now - job.submittedAt() < cfg.pendingRetrySeconds()) return Reconcile.busyNow();
        if (now <= job.deadline()) {
            try {
                String broadcastHash = rpc.broadcastProtected(job.rawTx());
                if (!broadcastHash.equalsIgnoreCase(job.txHash())) {
                    throw new IllegalStateException("rebroadcast hash mismatch");
                }
                jobs.markRebroadcast(job.jobId(), now);
            } catch (RuntimeException rebroadcastError) {
                jobs.note(job.jobId(), "rebroadcast uncertain: " + rebroadcastError.getMessage());
            }
            return Reconcile.busyNow();
        }
        BigInteger latestNonce = rpc.latestNonce(cfg.keeperAddress());
        if (latestNonce.compareTo(job.nonce()) > 0) {
            jobs.markFinal(job.jobId(), "consumed", -1L);
            return Reconcile.clear();
        }
        if (!allowReplacement) {
            jobs.alert("pending-expired:" + job.jobId(), "Expired tx needs replacement");
            return Reconcile.busyNow();
        }
        BigInteger replacementFloor = job.gasPrice().multiply(BigInteger.valueOf(9L))
                .divide(BigInteger.valueOf(8L)).add(BigInteger.ONE);
        // 先保留旧活跃任务；只有新签名交易持久化成功时，才原子地标记旧任务 replaced。
        // 如果重算价格/模拟/Gas 检查失败，下轮仍可继续恢复旧 nonce。
        return new Reconcile(false, job.nonce(), replacementFloor, job.jobId());
    }

    interface SignerJobStore {
        <T> T withWalletLock(int chainId, String keeperAddress, Supplier<T> operation);
        Optional<TxJob> findById(String jobId);
        Optional<TxJob> findActive();
        void insertPreparedReplacing(TxJob newJob, String replacesJobId);
        void markSubmitted(String jobId, long now);
        void markRebroadcast(String jobId, long now);
        void markFinal(String jobId, String status, long blockNumber);
        void note(String jobId, String detail);
        void alert(String code, String message);
    }

    interface RpcPort {
        String encodeAbi(String canonicalSignature, List<BigInteger> args);
        boolean simulate(String from, String to, String data);
        BigInteger estimateGas(String from, String to, String data);
        BigInteger gasPrice();
        BigInteger balance(String address);
        BigInteger pendingNonce(String address);
        BigInteger latestNonce(String address);
        Optional<Receipt> receipt(String txHash);
        // 使用专用 SEND_RPC_URL；"already known" 应被视为同 rawTx 的可恢复状态。
        String broadcastProtected(String rawTx);
    }

    interface RawSigner {
        // 必须校验私钥推导地址 == expectedAddress，使用正确 chainId 与 legacy EIP-155。
        SignedRaw signLegacyEip155(int chainId, String expectedAddress, BigInteger nonce,
                BigInteger gasPrice, BigInteger gasLimit, String to, String data, BigInteger value);
    }
}
```

这个代码块没有假装提供后端数据库连接或私钥。接入时务必逐项实现 `ChainPort`、`StorePort`、`SignerJobStore`、`RpcPort`、`RawSigner`；`RpcPort.encodeAbi` 应按 `Plan.signature` 选择精确 ABI，`broadcastProtected` 应比对签名交易本地哈希与 RPC 返回哈希。`SignerJobStore` 的唯一键至少包含 `jobId`，并约束一个钱包同一时刻只有一个 `prepared/submitted` 活跃任务。

`executeReplanned` 的实现顺序是**单钱包持久化状态机**，不能简单 `web3j.send()` 后忘记：

1. 对 `(chainId, keeperAddress)` 获取数据库排他锁或等价的单写者租约。锁要跨 Java 实例有效；只用 JVM `synchronized` 无法防止多副本争用 nonce。
2. 以 `jobId` 查 `signer_jobs`。如果已 `submitted` / `confirmed` / `reverted` / `replaced`，返回原结果，不再次签名。
3. 查钱包唯一的 `prepared` / `submitted` 活跃任务：先查 `eth_getTransactionReceipt(txHash)`。若已上链，按 receipt `status` 标记成功或回滚；若仍在 deadline 内，必要时重播同一 `raw_tx`；过期后检查链上 `latest` nonce，确认是否已消耗。尚未消耗时才允许用同 nonce、足够提高的 gasPrice 替换，替换交易仍须重新读取并重新规划。
4. 核对本地 `assets` 表中的 token、status、目标 TaxProcessor/Vault 是否仍匹配；再 `inspectAtOneBlock(asset)` 并查询有效历史样本，调用 `KeeperCore.plan(...)` 重新生成**最终**参数。若返回空，跳过。
5. 按计划编码 ABI，使用 Keeper 地址为 `from`、目标合约为 `to`、`value=0` 做 `eth_call`；若失败，记录原因并跳过。这里 `value=0` 指 Keeper 交易不附带 BNB；金库在自身合约余额中执行回购。
6. 读取 `eth_getTransactionCount(keeper,"pending")`、`eth_gasPrice`、`eth_getBalance`、`eth_estimateGas`；`gasLimit = floor(estimate×1.2)+1`，`gasPrice = floor(networkGasPrice×1.2)`，仍受配置的最高 Gas 单价和钱包最低余额约束。替换交易使用旧 nonce，并满足原发送者的提价要求。
7. 用 Keeper 私钥签 **BSC chainId 的 legacy/EIP-155 交易**；交易 `to=plan.target`、`data=ABI 编码`、`value=0`。检查私钥推导地址等于 `KEEPER_ADDRESS`。先将 `jobId, nonce, txHash, rawTx, gasPrice, deadline, status` **提交到数据库**，再调用专门的 `SEND_RPC_URL` 广播。
8. 广播超时或返回不明时，状态仍保持待核对；下一轮先查回执并重播**同一**原始交易。不要因为 RPC 超时就直接用新 nonce 再发一次。主网 `SEND_RPC_URL` 使用独立的 MEV 保护通道；读 RPC 和发送 RPC 分开。

Web3j 的 RPC 适配层须先检查 `hasError()` 和 `getResult()`，再调用 `getAmountUsed()`、`getGasPrice()` 或 `getTransactionCount()` 等数字 getter。错误响应缺少 `result`，直接解析会用 `MessageDecodingException` 掩盖真实回滚原因。`executeBuyback` 没有返回值，模拟成功时返回 `"0x"`；检查错误与回滚即可，不对它调用 `Numeric.decodeQuantity`。包装异常时保留原始 cause。回购的 `currentQuote` 与 `anchorQuote` 均须是扣除当前有效买税后的实收报价；上面的 `quoteBuyback` 已完成该折算，不可改用税前 AMM 产出来计算最低输出。

单实例回购调试可直接参考 [Java 回购修正版](keeper-java-buyback-patch.md) 与 [完整源码](examples/BuybackKeeperService.java)；它展示具体 web3j ABI 编码与错误检查。生产接管仍使用本节的持久化签名状态机。

定时任务本身也应对 `(chainId, coordinator)` 使用单轮租约，防止两个实例同时扫描同一批到期代币。若签名、广播持久化或数据库记账抛异常，`runOnce` 不能把它当作普通的代币读取错误吞掉；把原 `runId` 放回持久化重试队列，重试仍用同一 `jobId`。只有读取/规划失败才按当前代码块记录 `last_error` 并推进该代币的巡检时间。

如果 Java 服务使用 web3j，ABI 可从当前 `out/<Contract>.sol/<Contract>.json` 的 `abi` 字段生成 Java wrapper；已有部署的合约只需要 ABI，不需要 bytecode。`out/` 被忽略且可被 `forge clean` 清空，后端发布包应保存**已核验部署版本**的 ABI 或生成后的 wrapper。参考 [web3j 官方 wrapper 文档](https://docs.web3j.io/4.14.0/smart_contracts/construction_and_deployment/)和[交易 nonce 文档](https://docs.web3j.io/4.14.0/transactions/transaction_nonce/)。

## 6. ChainPort 如何接 ABI：每个变量从哪里读

### 6.1 发现代币：`readAndVerifyAsset`

| Java 字段 | 合约调用 | 处理 |
|---|---|---|
| `total` | `Coordinator.getTotalTokenCount()` | 分页总数。 |
| `tokens` | `Coordinator.getAllTokenPresalePairs(offset,limit)` | 每个结构体的 `tokenAddress`；其余预售字段不参与 Keeper。 |
| `asset.taxProcessor` | `token.taxProcessor()` | 必须非零、有代码。 |
| `asset.pair` | `token.mainPool()` | 后续校验 token0/token1 恰为 token/WBNB。 |
| `asset.vault` | `Coordinator.tokenVaults(token)` | 零地址转为 Java `null`；不因此排除代币。 |
| `asset.wbnb` | `TaxProcessor.weth()` | 本项目在 BSC 中实际是 WBNB；再检查 `TaxProcessor.taxToken()==token`。 |

新发现后 `status="active"`、`next_check_at=0`；再次发现仅更新合约元数据，**不要**重置巡检时间。分页游标在最后一页归零，以便后续发现新发代币并复核旧资产。

如果同一条链切换到新的 Coordinator，旧 `assets` 行不会自动消失。应在迁移方案中明确哪些旧代币继续由同一 Keeper 服务，并核对旧 Coordinator 的 `KEEPER_ROLE`；哪些旧资产应停用。不能因为配置了新 Coordinator 就默认旧资产已退出巡检。

### 6.2 同区块快照：`inspectAtOneBlock`

先 `eth_getBlockByNumber("latest",false)` 取得 `blockNumber`、`blockTimestamp`。把该区块号作为下面每一个 `eth_call` 的 blockTag；禁止部分字段读 latest、部分字段读更早的区块。

| Java 字段 | 合约调用 | 处理 |
|---|---|---|
| `sample.reserveToken / reserveWbnb` | Pair `token0()`, `token1()`, `getReserves()` | 根据 token0/token1 方向归一化，不能假设 token 总是 token0。样本时间取**区块时间**，不用本地服务器时间。 |
| `pairTotalSupply` | Pair `totalSupply()` | LP 最低铸造量计算。 |
| `poolState` | Token `poolState()` | 第 1、2、3、6 个输出分别是 `state,buyTaxRate,sellTaxRate,taxExpirationTime`。 |
| `pendingTax` | TaxProcessor `pendingTaxTokens()` | 为 0 时不清税。 |
| `feeConfig` | TaxProcessor `feeConfigV2()` | 依序为 `marketBps,deflationBps,lpBps,dividendBps,feeRate,isWeth,commissionBps,dividendToken`。 |
| `lpTokenBalance/lpQuoteBalance` | TaxProcessor 同名函数 | 两侧都非 0 才考虑加池。 |
| 新金库 `VaultState` | `previewBuyback()`、`mode()` | `previewBuyback` 返回 `(executableAmount,readiness)`；只有 readiness=0 才规划回购。金额直接使用预览结果。 |
| 旧金库 `VaultState` | `canExecuteBuyback()`、`buybackAmount()`、`mode()` | 仅在新金库 ABI **不存在或调用不兼容**时走旧 ABI；旧合约的 `canExecuteBuyback()` 负责可执行判断，返回 false 时后端另用池 WBNB 储备 1% 上限区分告警原因。 |

旧 ABI 的 `executeBuyback` 是 `(minTokenOut,minLpTokenOut,deadline)`；新 ABI 是 `(expectedBnbIn,minTokenOut,minLpTokenOut,deadline)`。`Plan.signature` 用完整类型列表选择正确的 selector。错误 ABI 会产生错误 selector，必须在上线前用目标地址 `eth_call` 验证。

新版 readiness 数字要与 Solidity 枚举一致：`0 Ready`、`1 InsufficientBalance`、`2 TriggerBalanceNotMet`、`3 TooEarly`、`4 InvalidPoolReserves`、`5 ReserveCapBelowMinimum`。Java 的 `6` 只为旧固定金额金库的后端诊断状态，不是新版合约返回值。模式 `1` 是 LP 买毁；LP 路径失败时，合约可能回退到 Token 买毁，因此 Java 同时给出全额预算的 `minTokenOut` 和半仓买入的 `minLpTokenOut`。

### 6.3 三类发送调用

| 类型 | 目标 | 精确 ABI 入参顺序 |
|---|---|---|
| 清税 | TaxProcessor | `processPendingTax(uint256 amountIn,uint256 minQuoteOut,uint64 deadline)` |
| 加池 | TaxProcessor | `addPendingLiquidity(uint256 tokenAmount,uint256 minQuoteAmount,uint256 maxQuoteAmount,uint256 minLiquidity,uint64 deadline)` |
| 新金库回购 | Vault | `executeBuyback(uint256 expectedBnbIn,uint256 minTokenOut,uint256 minLpTokenOut,uint64 deadline)` |
| 旧金库回购 | Vault | `executeBuyback(uint256 minTokenOut,uint256 minLpTokenOut,uint64 deadline)` |

`deadline` 是区块 Unix **秒**，不是毫秒。新金库 `expectedBnbIn` 来自 `previewBuyback()`，其链上计算为 `min(金库 BNB 余额, buybackAmount, 主池 WBNB 储备的 1%)`，并先检查触发额、冷却时间和最低执行额。Java 不再把创建者设置的 `buybackAmount` 原值当作交易输入。

### 6.4 从当前合约产物获取 ABI

在合约仓库执行 `forge build`，然后提取下面编译产物 JSON 的 `abi` 字段：

```text
out/CoordinatorFactory.sol/CoordinatorFactory.json
out/FlapTaxTokenV3.sol/FlapTaxTokenV3.json
out/TaxProcessor.sol/TaxProcessor.json
out/BuybackVault.sol/BuybackVault.json
out/IPancakeRouter02.sol/IPancakePair.json
```

可以把这些纯 ABI 文件交给 web3j CLI 的 `web3j generate solidity -a=<abiFile> -o=<javaSourceDir> -p=<packageName>`。生成的 wrapper 只是编码/解码工具，不能代替本文的历史报价、同区块快照、签名前重算和 nonce 恢复策略。旧金库三参数 ABI 要从旧版已核验构建取得，或只为这一个方法声明精确的旧签名；不可用当前四参数 wrapper 调旧实例。

## 7. 配置建议与回归验收

默认值与现有 `keeper/src/config.ts` 对齐：`discoveryPageSize=8`、`maxAssetsPerRun=8`、`checkIntervalSeconds=60`、`ammFeeBps=25`、`taxMaxReserveBps=30`、`slippageBps=100`、`maxPriceDeviationBps=300`、`anchorMinAgeSeconds=300`、`anchorMaxAgeSeconds=3600`、`minAnchorSamples=3`、`deadlineSeconds=300`；另外 Gas 价格倍数 `12000 bps`、Gas 最高单价 `10 gwei`、Keeper 最低余额 `0.003 BNB`、待确认重播间隔 `90 秒`。这些是当前默认策略，不是链上合约常量；上线要核对实际 Pancake 池费率与部署配置。

交给后端前至少用同一批快照比较 Java 与 TypeScript 的结果：

1. 无金库、无待清税余额、无 LP 余额：只保存样本并推进巡检时间，不签名。
2. 历史样本不足 3 条、样本太新/太旧或当前储备为 0：三个规划均为空。
3. 清税：验证 `swapAmount` 只包含真正卖出的份额；卖出税按实际进池量计算；无 swap 部分时 `minQuoteOut=0`。
4. 加池：验证 token 卖出税、WBNB 余额反推输入、`minQuote/maxQuote/minLiquidity` 的整数向下取整。
5. 回购：验证 `previewBuyback` 的实际金额、买入税后最低到账、LP 49.90% 半仓下限、旧新 ABI 区分。
6. 报价当前值和历史值相差 3% 以上时跳过；在允许区间内最低输出是两个保护下限的较大值。
7. 模拟失败、发送超时、服务重启、待确认超过 deadline、同钱包双实例竞争时，不重复签名、不跳 nonce。
8. BSC 测试网使用真实状态化 Pancake 池或 fork 验证 Fee-on-Transfer、退款/回调/回退路径；主网启动前先停旧 Keeper，再核对旧待确认 tx 的 hash/nonce。没有迁移历史储备样本时，新服务先采样预热，达到历史样本条件前不交易。

第 6 项可以用一个纯整数断言防止把 `max` 写反：`currentQuote=10000`、`anchorQuote=10200`、`slippageBps=100` 时，两个下限分别是 `9900` 和 `10098`，最后 `minimumOut` 必须是 `10098`。

相关源码：`keeper/src/discovery.ts`、`keeper/src/workflow.ts`、`keeper/src/planner.ts`、`keeper/src/policy.ts`、`keeper/src/signer.ts`、`keeper/migrations/0001_init.sql`、`src/BuybackVault.sol`、`src/TaxProcessor.sol`。
