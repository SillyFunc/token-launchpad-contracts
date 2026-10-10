import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.FunctionReturnDecoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.Address;
import org.web3j.abi.datatypes.Bool;
import org.web3j.abi.datatypes.Function;
import org.web3j.abi.datatypes.Type;
import org.web3j.abi.datatypes.generated.Uint8;
import org.web3j.abi.datatypes.generated.Uint16;
import org.web3j.abi.datatypes.generated.Uint32;
import org.web3j.abi.datatypes.generated.Uint48;
import org.web3j.abi.datatypes.generated.Uint64;
import org.web3j.abi.datatypes.generated.Uint96;
import org.web3j.abi.datatypes.generated.Uint112;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameter;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.Response;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.EthBlock;
import org.web3j.protocol.core.methods.response.EthCall;
import org.web3j.protocol.core.methods.response.EthChainId;
import org.web3j.protocol.core.methods.response.EthEstimateGas;
import org.web3j.protocol.core.methods.response.EthGasPrice;
import org.web3j.protocol.core.methods.response.EthGetBalance;
import org.web3j.protocol.core.methods.response.EthSendTransaction;
import org.web3j.protocol.http.HttpService;
import org.web3j.tx.TransactionManager;

import java.math.BigInteger;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Deque;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

// 把本类放入后端项目，并补充后端已有 ChainConfigVO、EthCommonUtil 的包导入。
// 这是单实例、串行发送的回购示例；样本放在内存，重启后重新预热。
// 完整生产 Keeper 的数据库、待确认交易恢复、钱包锁见 keeper-java-reference.md。
@SuppressWarnings({"rawtypes", "unchecked"})
public class BuybackKeeperService {

    // 百分比基数：10000 bps = 100%。
    private static final BigInteger BPS = BigInteger.valueOf(10000);
    // 当前项目 Keeper 的报价配置：25 bps。接入时核对实际池费率。
    private static final BigInteger AMM_FEE_BPS = BigInteger.valueOf(25);
    // 报价输出允许的滑点：100 bps = 1%。
    private static final BigInteger SLIPPAGE_BPS = BigInteger.valueOf(100);
    // 当前报价与历史报价的最大偏差：300 bps = 3%。
    private static final BigInteger MAX_DEVIATION_BPS = BigInteger.valueOf(300);
    // LP 买毁分支用于兑换代币的 BNB 预算比例：49.90%。
    private static final BigInteger LP_SWAP_BPS = BigInteger.valueOf(4990);
    // Gas 用量余量：130 表示估算值的 130%。
    private static final BigInteger GAS_LIMIT_MULTIPLIER = BigInteger.valueOf(130);
    // 本示例的 Gas 单价上限：10 gwei。
    private static final BigInteger MAX_GAS_PRICE_WEI = new BigInteger("10000000000");
    // 支付本次 Gas 后，Keeper 钱包至少保留 0.003 BNB。
    private static final BigInteger MIN_KEEPER_BALANCE_WEI = new BigInteger("3000000000000000");
    // 最低有效历史样本数量。
    private static final int MIN_ANCHOR_SAMPLES = 3;
    // 最多使用最近 15 条符合时间要求的样本。
    private static final int MAX_ANCHOR_SAMPLES = 15;
    // 历史样本至少来自 5 分钟前。
    private static final long ANCHOR_MIN_AGE_SECONDS = 300;
    // 历史样本最多保留 60 分钟。
    private static final long ANCHOR_MAX_AGE_SECONDS = 3600;
    // 单个池最多每 60 秒写入一条样本，避免重复调用凑满样本数量。
    private static final long SAMPLE_INTERVAL_SECONDS = 60;
    // deadline 使用区块时间加 300 秒，合约允许的最大延迟是 600 秒。
    private static final long DEADLINE_SECONDS = 300;

    // 此字段属于长期存活的服务实例；键为 chainId:小写池地址。
    private final Map<String, Deque<Sample>> deWindows = new ConcurrentHashMap<>();

    public static class Asset {
        // 代币合约地址。
        public final String token;
        // 税费处理器地址，本回购示例中只保留资产元数据。
        public final String taxProcessor;
        // token/WBNB 主池地址。
        public final String pair;
        // 回购金库地址；无金库时为 null 或零地址。
        public final String vault;

        public Asset(String token, String taxProcessor, String pair, String vault) {
            this.token = token;
            this.taxProcessor = taxProcessor;
            this.pair = pair;
            this.vault = vault;
        }
    }

    private static class Reserves {
        // 主池中的代币储备，最小单位整数。
        final BigInteger token;
        // 主池中的 WBNB 储备，单位 wei。
        final BigInteger wbnb;

        Reserves(BigInteger token, BigInteger wbnb) {
            this.token = token;
            this.wbnb = wbnb;
        }
    }

    private static class Sample {
        // 本次读取使用的区块号，用于避免同一个区块重复写入。
        final BigInteger blockNumber;
        // 该区块的 Unix 秒时间戳。
        final long ts;
        // 对应区块的两侧储备。
        final Reserves reserves;

        Sample(BigInteger blockNumber, long ts, Reserves reserves) {
            this.blockNumber = blockNumber;
            this.ts = ts;
            this.reserves = reserves;
        }
    }

    /**
     * 返回 null：本轮仅采样，或条件/报价/模拟未通过。
     * 返回 txHash：节点已接收广播；最终成功仍须检查交易回执 status。
     * 抛异常：RPC、ABI、配置或发送失败，调用方应记录原始异常。
     *
     * synchronized 只串行化同一个实例；同钱包多实例须使用数据库钱包锁。
     * vaultMode、coinIssuePlatformAddress 保留原调用签名；实际模式从金库读取，
     * poolState 从代币直接读取，因此不依赖 EthCommonContract 的自定义字段名。
     */
    public synchronized String buybackJob(
            Asset a, int vaultMode, ChainConfigVO chainConfig,
            String privateKey, String coinIssuePlatformAddress) throws Exception {
        if (a == null) throw new IllegalArgumentException("asset 不能为空");
        if (isZeroAddress(a.vault)) return skip(a, "代币未配置回购金库");

        // 本轮 RPC 客户端；采样 Map 属于本服务，不会随客户端关闭而清空。
        Web3j web3j = Web3j.build(new HttpService(chainConfig.getUrl()));
        try {
            // 用字符串转换兼容后端 chainId 字段的 Integer/Long/long 表示。
            long chainId = Long.parseLong(String.valueOf(chainConfig.getChainId()));
            if (chainId != 56 && chainId != 97) throw new IllegalArgumentException("仅支持 BSC 56/97");

            // 节点链 ID 响应，先检查错误再解析数字。
            EthChainId chainResponse = web3j.ethChainId().send();
            requireResult("eth_chainId", chainResponse);
            if (!chainResponse.getChainId().equals(BigInteger.valueOf(chainId))) {
                throw new IllegalStateException("RPC 网络与 chainConfig.chainId 不一致");
            }

            // 复用后端现有的交易管理器构造方式。
            TransactionManager txm = EthCommonUtil.getTransactionManager(
                    web3j, chainConfig.getChainId(), privateKey);
            // 本次模拟、估算与签名必须使用同一个 Keeper 地址。
            String keeper = txm.getFromAddress();
            // 最新区块响应；本轮资产状态统一在该区块读取。
            EthBlock blockResponse = web3j.ethGetBlockByNumber(DefaultBlockParameterName.LATEST, false).send();
            requireResult("eth_getBlockByNumber", blockResponse);
            // 已完成错误检查的区块对象。
            EthBlock.Block block = blockResponse.getBlock();
            // 同区块快照的区块号。
            BigInteger blockNumber = block.getNumber();
            // 区块时间，不使用 System.currentTimeMillis() 作为采样时间或 deadline 基准。
            long now = block.getTimestamp().longValueExact();
            // 固定区块参数，供所有只读 ABI 调用使用。
            DefaultBlockParameter blockTag = DefaultBlockParameter.valueOf(blockNumber);

            // 核对元数据，避免把代币、主池或金库地址混用。
            if (!a.token.equalsIgnoreCase(readAddress(web3j, keeper, a.vault, "token", blockTag))
                    || !a.pair.equalsIgnoreCase(readAddress(web3j, keeper, a.vault, "pair", blockTag))
                    || !a.pair.equalsIgnoreCase(readAddress(web3j, keeper, a.token, "mainPool", blockTag))) {
                throw new IllegalStateException("Asset.token/pair/vault 与链上关联不一致");
            }

            // 在就绪检查前保存样本；金库余额不足或时间未到也持续积累历史。
            Reserves r = reserves(a, web3j, keeper, chainId, blockNumber, now, blockTag);
            // 金库预检返回两个值：实际可执行 BNB、readiness 状态码。
            List<Type> out = callAtBlock(web3j, keeper, a.vault, "previewBuyback",
                    Arrays.<TypeReference<?>>asList(new TypeReference<Uint256>() {}, new TypeReference<Uint8>() {}), blockTag);
            // 本轮 BNB 输入预算，单位 wei，直接取预检结果。
            BigInteger executable = (BigInteger) out.get(0).getValue();
            // 0=Ready；非 0 时记录原因并等待下一轮。
            int readiness = ((BigInteger) out.get(1).getValue()).intValueExact();
            if (readiness != 0) return skip(a, "readiness=" + readiness);
            if (executable.signum() <= 0) throw new IllegalStateException("Ready 状态却返回非正执行金额");

            // 以链上金库模式为准：0 TokenBurn，1 LpBurn。
            int mode = readUint(web3j, keeper, a.vault, "mode", new TypeReference<Uint8>() {}, blockTag).intValueExact();
            if (mode != 0 && mode != 1) throw new IllegalStateException("未知金库模式：" + mode);
            // 当前区块仍有效的买税；税过期或处于无税状态时为 0。
            BigInteger buyTaxBps = effectiveBuyTax(a, web3j, keeper, now, blockTag);
            // 当前储备对应的税前兑换产出。
            BigInteger gross = getAmountOut(executable, r.wbnb, r.token);
            // 5～60 分钟前储备对应的税前锚点报价。
            BigInteger anchorGross = anchorQuote(a, chainId, executable, false, now);
            if (anchorGross == null) return skip(a, "历史样本不足，等待至少 3 条 5～60 分钟前的有效样本");
            if (!within(gross, anchorGross)) return skip(a, "全额回购报价偏差超过策略限制");

            // 当前报价扣除买税，得到金库实收口径。
            BigInteger net = afterTax(gross, buyTaxBps);
            // 历史报价也按当前有效买税折算，保持比较口径一致。
            BigInteger anchorNet = afterTax(anchorGross, buyTaxBps);
            // 全额/回退分支的最低代币到账量。
            BigInteger minTokenOut = protectedMinOut(net, anchorNet);
            // TokenBurn 模式没有 LP 分支，第二个最低输出为 0。
            BigInteger minLpTokenOut = BigInteger.ZERO;
            if (mode == 1) {
                // LP 分支实际使用的兑换预算。
                BigInteger lpIn = executable.multiply(LP_SWAP_BPS).divide(BPS);
                // 当前储备下 LP 分支的税前代币报价。
                BigInteger lpGross = getAmountOut(lpIn, r.wbnb, r.token);
                // LP 分支也使用独立计算的历史报价。
                BigInteger lpAnchorGross = anchorQuote(a, chainId, lpIn, false, now);
                if (lpAnchorGross == null || !within(lpGross, lpAnchorGross)) {
                    return skip(a, "LP 分支历史样本不足或报价偏差过大");
                }
                minLpTokenOut = protectedMinOut(afterTax(lpGross, buyTaxBps), afterTax(lpAnchorGross, buyTaxBps));
            }
            if (minTokenOut.signum() <= 0 || (mode == 1 && minLpTokenOut.signum() <= 0)) {
                return skip(a, "最低到账量为 0");
            }

            // 交易有效截止时间，单位 Unix 秒。
            long deadline = Math.addExact(now, DEADLINE_SECONDS);
            // 精确 ABI 入参顺序；金额使用原始整数，不先转换为小数。
            List<Type> params = Arrays.<Type>asList(new Uint256(executable), new Uint256(minTokenOut),
                    new Uint256(minLpTokenOut), new Uint64(deadline));
            // executeBuyback 没有返回值，输出类型列表为空。
            Function fn = new Function("executeBuyback", params, Collections.<TypeReference<?>>emptyList());
            // 函数 selector 加四个 ABI 参数，放入交易 data。
            String data = FunctionEncoder.encode(fn);
            System.out.println("回购计划：block=" + blockNumber + ", amountWei=" + executable
                    + ", mode=" + mode + ", buyTaxBps=" + buyTaxBps + ", minTokenOut=" + minTokenOut);
            if (!simulate(a.vault, data, keeper, web3j)) return skip(a, "回购模拟失败，详见 RPC 错误日志");
            return send(a.vault, data, txm, web3j);
        } catch (Exception e) {
            throw new IllegalStateException("回购任务失败：token=" + a.token, e);
        } finally {
            web3j.shutdown();
        }
    }

    /** 读取固定区块储备并采样；同一实例的 buybackJob 串行调用。 */
    private Reserves reserves(Asset a, Web3j web3j, String keeper, long chainId,
            BigInteger blockNumber, long now, DefaultBlockParameter blockTag) throws Exception {
        // pair 的原始返回顺序：reserve0、reserve1、上次池状态更新时间。
        List<Type> out = callAtBlock(web3j, keeper, a.pair, "getReserves", Arrays.<TypeReference<?>>asList(
                new TypeReference<Uint112>() {}, new TypeReference<Uint112>() {}, new TypeReference<Uint32>() {}), blockTag);
        // 主池的两种资产地址，用来确认储备方向。
        String token0 = readAddress(web3j, keeper, a.pair, "token0", blockTag);
        // 第二种池资产地址。
        String token1 = readAddress(web3j, keeper, a.pair, "token1", blockTag);
        // 金库实际使用的 WBNB 地址。
        String wbnb = readAddress(web3j, keeper, a.vault, "wbnb", blockTag);
        // token0 对应的原始储备。
        BigInteger r0 = (BigInteger) out.get(0).getValue();
        // token1 对应的原始储备。
        BigInteger r1 = (BigInteger) out.get(1).getValue();
        // 归一后的储备，始终按 token、WBNB 排列。
        Reserves rs;
        if (token0.equalsIgnoreCase(a.token) && token1.equalsIgnoreCase(wbnb)) rs = new Reserves(r0, r1);
        else if (token1.equalsIgnoreCase(a.token) && token0.equalsIgnoreCase(wbnb)) rs = new Reserves(r1, r0);
        else throw new IllegalStateException("主池资产不是指定 token/WBNB");

        // 统一小写并带上链 ID，避免相同池字符串被分成多个窗口。
        String key = sampleKey(chainId, a.pair);
        // 该池的历史队列；只在没有窗口时创建一次。
        Deque<Sample> w = deWindows.computeIfAbsent(key, k -> new ArrayDeque<Sample>());
        // 清理超过一小时的旧记录。
        while (!w.isEmpty() && now - w.peekFirst().ts > ANCHOR_MAX_AGE_SECONDS) w.pollFirst();
        // 最近一条记录，用于限制重复采样。
        Sample last = w.peekLast();
        if (last == null || (!last.blockNumber.equals(blockNumber) && now - last.ts >= SAMPLE_INTERVAL_SECONDS)) {
            w.addLast(new Sample(blockNumber, now, rs));
        }
        System.out.println("储备采样：service=" + System.identityHashCode(this)
                + ", map=" + System.identityHashCode(deWindows) + ", key=" + key + ", samples=" + w.size());
        return rs;
    }

    /** 过滤 5～60 分钟前的非零储备样本，取最近至多 15 条报价的中位数。 */
    private BigInteger anchorQuote(Asset a, long chainId, BigInteger amountIn, boolean sellDirection, long now) {
        // 读取与保存时完全一致的窗口键。
        String key = sampleKey(chainId, a.pair);
        // 同一个长期存活服务中的历史队列。
        Deque<Sample> samples = deWindows.get(key);
        if (samples == null) return null;
        // 筛选后的有效历史报价。
        List<BigInteger> quotes = new ArrayList<>();
        // 从新到旧读取，选择最近的有效历史样本。
        Iterator<Sample> iterator = samples.descendingIterator();
        while (iterator.hasNext() && quotes.size() < MAX_ANCHOR_SAMPLES) {
            // 本条历史储备记录。
            Sample sample = iterator.next();
            // 样本年龄，使用当前区块时间减历史区块时间。
            long age = now - sample.ts;
            if (age < ANCHOR_MIN_AGE_SECONDS || age > ANCHOR_MAX_AGE_SECONDS) continue;
            if (sample.reserves.token.signum() <= 0 || sample.reserves.wbnb.signum() <= 0) continue;
            // 每条历史储备都按本轮相同输入量重新报价。
            BigInteger quote = sellDirection
                    ? getAmountOut(amountIn, sample.reserves.token, sample.reserves.wbnb)
                    : getAmountOut(amountIn, sample.reserves.wbnb, sample.reserves.token);
            if (quote.signum() > 0) quotes.add(quote);
        }
        System.out.println("历史报价：key=" + key + ", totalSamples=" + samples.size() + ", validQuotes=" + quotes.size());
        if (quotes.size() < MIN_ANCHOR_SAMPLES) return null;
        Collections.sort(quotes);
        // 排序后的中间位置。
        int middle = quotes.size() / 2;
        return quotes.size() % 2 == 1 ? quotes.get(middle)
                : quotes.get(middle - 1).add(quotes.get(middle)).divide(BigInteger.valueOf(2));
    }

    private BigInteger effectiveBuyTax(Asset a, Web3j web3j, String keeper,
            long now, DefaultBlockParameter blockTag) throws Exception {
        // 直接按当前 FlapTaxTokenV3 的七个返回值解码，避免猜测后端 wrapper 的属性名。
        List<Type> pool = callAtBlock(web3j, keeper, a.token, "poolState", Arrays.<TypeReference<?>>asList(
                new TypeReference<Uint8>() {}, new TypeReference<Uint16>() {}, new TypeReference<Uint16>() {},
                new TypeReference<Bool>() {}, new TypeReference<Uint96>() {}, new TypeReference<Uint64>() {},
                new TypeReference<Uint48>() {}), blockTag);
        // 代币税状态：2 AntiFarmer、3 Taxed。
        int state = ((BigInteger) pool.get(0).getValue()).intValueExact();
        // 配置中的原始买税，单位 bps。
        BigInteger configuredBuyTax = (BigInteger) pool.get(1).getValue();
        // 税率到期时间，单位 Unix 秒。
        long expires = ((BigInteger) pool.get(5).getValue()).longValueExact();
        return (state == 2 || state == 3) && now <= expires ? configuredBuyTax : BigInteger.ZERO;
    }

    private BigInteger getAmountOut(BigInteger amountIn, BigInteger reserveIn, BigInteger reserveOut) {
        if (amountIn.signum() <= 0 || reserveIn.signum() <= 0 || reserveOut.signum() <= 0) return BigInteger.ZERO;
        // 保留 bps 基数的手续费后输入，整数计算不使用浮点数。
        BigInteger inputWithFee = amountIn.multiply(BPS.subtract(AMM_FEE_BPS));
        return inputWithFee.multiply(reserveOut).divide(reserveIn.multiply(BPS).add(inputWithFee));
    }

    private BigInteger afterTax(BigInteger gross, BigInteger taxBps) {
        if (taxBps.signum() < 0 || taxBps.compareTo(BPS) > 0) throw new IllegalArgumentException("税率超出 0～10000 bps");
        return gross.multiply(BPS.subtract(taxBps)).divide(BPS);
    }

    private boolean within(BigInteger current, BigInteger anchor) {
        if (current.signum() <= 0 || anchor.signum() <= 0) return false;
        return current.subtract(anchor).abs().multiply(BPS).divide(anchor).compareTo(MAX_DEVIATION_BPS) <= 0;
    }

    private BigInteger protectedMinOut(BigInteger currentNet, BigInteger anchorNet) {
        // 当前实收报价对应的 1% 滑点下限。
        BigInteger currentFloor = currentNet.multiply(BPS.subtract(SLIPPAGE_BPS)).divide(BPS);
        // 历史实收报价对应的 1% 滑点下限。
        BigInteger anchorFloor = anchorNet.multiply(BPS.subtract(SLIPPAGE_BPS)).divide(BPS);
        // 与仓库正式 Keeper 一致，取更高的保护下限，禁止用 min 降低历史保护。
        return currentFloor.max(anchorFloor);
    }

    private boolean simulate(String to, String data, String keeper, Web3j web3j) throws Exception {
        // 无附带 BNB 的回购调用，from 必须为实际签名地址。
        Transaction tx = Transaction.createFunctionCallTransaction(keeper, null, null, null, to, BigInteger.ZERO, data);
        // 在最新状态模拟；若预检快照之后状态变化导致回滚，本轮跳过。
        EthCall response = web3j.ethCall(tx, DefaultBlockParameterName.LATEST).send();
        if (response.hasError()) {
            System.out.println("回购模拟失败：" + rpcError(response));
            return false;
        }
        if (response.isReverted()) {
            System.out.println("回购模拟回滚：" + response.getRevertReason());
            return false;
        }
        if (response.getValue() == null) throw new IllegalStateException("eth_call 缺少 result");
        // executeBuyback 是无返回值方法，正常结果为 "0x"；不作数字解码。
        return true;
    }

    public synchronized String send(String to, String data, TransactionManager txm, Web3j web3j) throws Exception {
        // 估算请求与实际广播使用相同 from、to、data、value。
        Transaction tx = Transaction.createFunctionCallTransaction(txm.getFromAddress(), null, null, null, to, BigInteger.ZERO, data);
        // 估算 Gas 的完整响应，检查错误后才能调用数字 getter。
        EthEstimateGas estimateResponse = web3j.ethEstimateGas(tx).send();
        requireResult("eth_estimateGas", estimateResponse);
        // 节点估算的 Gas 用量。
        BigInteger estimated = estimateResponse.getAmountUsed();
        if (estimated.signum() <= 0) throw new IllegalStateException("Gas 估算值非正");
        // 估算用量增加 30% 余量，并加 1 消除整数舍入误差。
        BigInteger gasLimit = estimated.multiply(GAS_LIMIT_MULTIPLIER).divide(BigInteger.valueOf(100)).add(BigInteger.ONE);
        // 当前 Gas 单价响应。
        EthGasPrice gasPriceResponse = web3j.ethGasPrice().send();
        requireResult("eth_gasPrice", gasPriceResponse);
        // 每单位 Gas 的价格，单位 wei。
        BigInteger gasPrice = gasPriceResponse.getGasPrice();
        if (gasPrice.signum() <= 0 || gasPrice.compareTo(MAX_GAS_PRICE_WEI) > 0) {
            throw new IllegalStateException("Gas 单价超出策略范围：" + gasPrice);
        }
        // Keeper 钱包余额响应，余额只用于支付 Gas。
        EthGetBalance balanceResponse = web3j.ethGetBalance(txm.getFromAddress(), DefaultBlockParameterName.LATEST).send();
        requireResult("eth_getBalance", balanceResponse);
        // 本次 Gas 上限成本，加上钱包保留余额。
        BigInteger requiredBalance = gasLimit.multiply(gasPrice).add(MIN_KEEPER_BALANCE_WEI);
        if (balanceResponse.getBalance().compareTo(requiredBalance) < 0) {
            throw new IllegalStateException("Keeper 钱包 BNB 不足以支付本轮 Gas 并保留最低余额");
        }
        // 广播响应；此步骤可能已经把交易发出，调用方不能盲目用新 nonce 重试。
        EthSendTransaction response = txm.sendTransaction(gasPrice, gasLimit, to, data, BigInteger.ZERO);
        requireResult("eth_sendRawTransaction", response);
        return response.getTransactionHash();
    }

    /** 所有读取固定在同一个区块；无输出方法的模拟使用上面的 simulate。 */
    private List<Type> callAtBlock(Web3j web3j, String keeper, String to, String name,
            List<TypeReference<?>> outputTypes, DefaultBlockParameter blockTag) throws Exception {
        // 本示例的只读方法都没有输入参数。
        Function fn = new Function(name, Collections.<Type>emptyList(), outputTypes);
        // ABI 编码后的只读请求数据。
        String data = FunctionEncoder.encode(fn);
        // 固定 from 和目标地址，不附带 BNB。
        Transaction tx = Transaction.createEthCallTransaction(keeper, to, data);
        // 保留完整 RPC 响应以便报告错误。
        EthCall response = web3j.ethCall(tx, blockTag).send();
        requireResult(name, response);
        if (response.isReverted()) throw new IllegalStateException(name + " reverted: " + response.getRevertReason());
        // 按 ABI 类型解码返回值，不将完整 ABI 字符串当作 RPC Quantity 解码。
        List<Type> values = FunctionReturnDecoder.decode(response.getValue(), fn.getOutputParameters());
        if (values.size() != outputTypes.size()) throw new IllegalStateException(name + " 返回值数量与 ABI 不一致");
        return values;
    }

    private String readAddress(Web3j web3j, String keeper, String to, String name,
            DefaultBlockParameter blockTag) throws Exception {
        return (String) callAtBlock(web3j, keeper, to, name,
                Collections.<TypeReference<?>>singletonList(new TypeReference<Address>() {}), blockTag).get(0).getValue();
    }

    private BigInteger readUint(Web3j web3j, String keeper, String to, String name,
            TypeReference<?> outputType, DefaultBlockParameter blockTag) throws Exception {
        return (BigInteger) callAtBlock(web3j, keeper, to, name,
                Collections.<TypeReference<?>>singletonList(outputType), blockTag).get(0).getValue();
    }

    private static void requireResult(String method, Response<?> response) {
        if (response.hasError()) throw new IllegalStateException(method + " failed: " + rpcError(response));
        if (response.getResult() == null) throw new IllegalStateException(method + " 缺少 result");
    }

    private static String rpcError(Response<?> response) {
        return "code=" + response.getError().getCode() + ", message=" + response.getError().getMessage()
                + ", data=" + response.getError().getData();
    }

    private static String sampleKey(long chainId, String pair) {
        return chainId + ":" + pair.toLowerCase(Locale.ROOT);
    }

    private static boolean isZeroAddress(String address) {
        return address == null || address.equalsIgnoreCase("0x0000000000000000000000000000000000000000");
    }

    private static String skip(Asset a, String reason) {
        System.out.println("回购跳过：token=" + a.token + ", reason=" + reason);
        return null;
    }
}
