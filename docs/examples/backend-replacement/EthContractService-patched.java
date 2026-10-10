package cn.ztuo.bitrade.service.chain;

import cn.ztuo.bitrade.chain.eth.EthCommonContract;
import cn.ztuo.bitrade.chain.eth.EthCommonContractUtil;
import cn.ztuo.bitrade.util.BeanUtil;
import com.aioff.trade.chain.entity.vo.ChainConfigVO;
import com.aioff.trade.chain.impl.eth.commonUtil.EthCommonUtil;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.stereotype.Service;
import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.Address;
import org.web3j.abi.datatypes.Function;
import org.web3j.abi.datatypes.Type;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.abi.datatypes.generated.Uint64;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.Response;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.EthCall;
import org.web3j.protocol.core.methods.response.EthSendTransaction;
import org.web3j.protocol.core.methods.response.EthEstimateGas;
import org.web3j.protocol.core.methods.response.EthGasPrice;
import org.web3j.protocol.core.methods.response.EthGetTransactionCount;
import org.web3j.protocol.core.methods.response.TransactionReceipt;
import org.web3j.protocol.http.HttpService;
import org.web3j.tx.TransactionManager;
import org.web3j.tx.gas.StaticGasProvider;
import org.web3j.tx.response.PollingTransactionReceiptProcessor;

import java.math.BigInteger;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@Service
@Slf4j
public class EthContractService {

    public String getUpAddress(ChainConfigVO chainConfig, String address, String contractAddress) throws Exception {
        Web3j web3j = Web3j.build(new HttpService(chainConfig.getUrl()));
        EthCommonContract ethCommonContract = EthCommonContractUtil.getCommonContractRead(web3j, chainConfig.getChainId(), contractAddress);
        String upAddress = ethCommonContract.team(address).send();
        web3j.shutdown();
        if (StringUtils.isEmpty(upAddress)) {
            return null;
        }
        if (upAddress.equalsIgnoreCase("0x0000000000000000000000000000000000000000")) {
            return null;
        }
        return upAddress;
    }


    public List<Asset> getAssets(ChainConfigVO chainConfig, String contractAddress) throws Exception {
        List<Asset> out = new ArrayList<>();
        Web3j web3j = null;
        try {
            web3j = Web3j.build(new HttpService(chainConfig.getUrl()));
            EthCommonContract ethCommonContract = EthCommonContractUtil.getCommonContractRead(web3j, chainConfig.getChainId(), contractAddress);
            BigInteger total = ethCommonContract.readUint(contractAddress, "getTotalTokenCount");
            for (BigInteger i = BigInteger.ZERO; i.compareTo(total) < 0; i = i.add(BigInteger.ONE)) {
                List<Type> tokenRet = ethCommonContract.call(contractAddress, "allTokens",
                        Collections.<Type>singletonList(new Uint256(i)),
                        Collections.<TypeReference<?>>singletonList(new TypeReference<Address>() {
                        }));
                String token = (String) tokenRet.get(0).getValue();

                List<Type> taxRet = ethCommonContract.call(token, "taxProcessor", Collections.<Type>emptyList(),
                        Collections.<TypeReference<?>>singletonList(new TypeReference<Address>() {
                        }));
                String taxProcessor = (String) taxRet.get(0).getValue();

                List<Type> pairRet = ethCommonContract.call(token, "mainPool", Collections.<Type>emptyList(),
                        Collections.<TypeReference<?>>singletonList(new TypeReference<Address>() {
                        }));
                String pair = (String) pairRet.get(0).getValue();

                List<Type> vaultRet = ethCommonContract.call(contractAddress, "tokenVaults",
                        Collections.<Type>singletonList(new Address(token)),
                        Collections.<TypeReference<?>>singletonList(new TypeReference<Address>() {
                        }));
                String vault = (String) vaultRet.get(0).getValue();

                String vaultVal;
                if ("0x0000000000000000000000000000000000000000".equalsIgnoreCase(vault)) {
                    vaultVal = null;
                } else {
                    vaultVal = vault;
                }
                out.add(new Asset(token, taxProcessor, pair, vaultVal));
            }
        } finally {
            if (web3j != null) {
                web3j.shutdown();
            }
        }
        return out;
    }

    static final BigInteger BPS = BigInteger.valueOf(10_000);
    static final BigInteger AMM_FEE_BPS = BigInteger.valueOf(25);   // Pancake V2 0.25%
    static final BigInteger SLIPPAGE_BPS = BigInteger.valueOf(100);  // 1%
    static final BigInteger MAX_DEVIATION_BPS = BigInteger.valueOf(300);  // 3%
    static final BigInteger TAX_MAX_RESERVE_BPS = BigInteger.valueOf(30);   // 单批 ≤ 储备 0.3%
    static final BigInteger LP_SWAP_BPS = BigInteger.valueOf(4_990); // 金库 LP 模式半仓
    static final long DEADLINE_SECONDS = 300;                      // 合约上限 600
    static final BigInteger GAS_LIMIT_MULTIPLIER = BigInteger.valueOf(130);  // %


    public synchronized String taxClear(Asset a, ChainConfigVO chainConfig, String privateKey, String coinIssuePlatformAddress) throws Exception {
        Web3j web3j = null;
        try {
            web3j = Web3j.build(new HttpService(chainConfig.getUrl()));
            StaticGasProvider gasProvider = new StaticGasProvider(chainConfig.getDefaultGasPrice(), chainConfig.getDefaultGasLimit());
            TransactionManager transactionManager = EthCommonUtil.getTransactionManager(web3j, chainConfig.getChainId(), privateKey);
            EthCommonContract ethCommonContract = EthCommonContract.load(coinIssuePlatformAddress, web3j, transactionManager, gasProvider);

            EthCommonContract.PoolState state = null;
            try {
                state = ethCommonContract.poolState(a.token);
            } catch (Exception ignored) {
            }
            if (state == null) {
                throw new RuntimeException("加载poolState出错");
            }
            BigInteger pending = ethCommonContract.readUint(a.taxProcessor, "pendingTaxTokens");
            if (pending.signum() == 0) {
                return null;
            }
            Reserves r = reserves(a, ethCommonContract);
            if (r.token.signum() == 0) {
                return null;
            }
            BigInteger amountIn = pending.min(r.token.multiply(TAX_MAX_RESERVE_BPS).divide(BPS));
            if (amountIn.signum() == 0) {
                return null;
            }

            // 读四通道占比：合约只把其中一部分真正送进 router 做 swap。
            // feeConfig() = (marketBps, deflationBps, lpBps, dividendBps, feeRate, isWeth)
            List<Type> fc = ethCommonContract.call(a.taxProcessor, "feeConfig", Collections.<Type>emptyList(),
                    Arrays.<TypeReference<?>>asList(
                            new TypeReference<org.web3j.abi.datatypes.generated.Uint16>() {
                            },
                            new TypeReference<org.web3j.abi.datatypes.generated.Uint16>() {
                            },
                            new TypeReference<org.web3j.abi.datatypes.generated.Uint16>() {
                            },
                            new TypeReference<org.web3j.abi.datatypes.generated.Uint16>() {
                            },
                            new TypeReference<org.web3j.abi.datatypes.generated.Uint16>() {
                            },
                            new TypeReference<org.web3j.abi.datatypes.Bool>() {
                            }));
            BigInteger[] bps = new BigInteger[4];
            for (int i = 0; i < 4; i++) {
                bps[i] = (BigInteger) fc.get(i).getValue();
            }

            // 复刻 TaxProcessor._splitTax（整数逐项向下取整，顺序不可合并，否则末位与合约不一致）：
            //   burnTokens 直接转 0xdead，lpReserve = lpTokens/2 留在 processor，两者都不进 router。
            // 旧实现直接用整批 amountIn 报价，在 deflationBps/lpBps 非 0 时会高估约 25%
            // （Token1/Token2 实测：swapAmount 仅为 amountIn 的 80%），导致 minQuoteOut 高于链上
            // 物理可达产出，必然 PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT。
            BigInteger afterFee = amountIn;
            BigInteger distributable = afterFee;
            BigInteger marketTokens = distributable.multiply(bps[0]).divide(BPS);
            BigInteger deflationTokens = distributable.multiply(bps[1]).divide(BPS);
            BigInteger lpTokens = distributable.multiply(bps[2]).divide(BPS);
            BigInteger dividendTokens = distributable.subtract(marketTokens).subtract(deflationTokens).subtract(lpTokens);
            BigInteger lpReserve = lpTokens.divide(BigInteger.valueOf(2));
            BigInteger swapAmount = marketTokens.add(lpTokens.subtract(lpReserve)).add(dividendTokens);

            if (swapAmount.signum() == 0) {
                // 全通缩等极端配置下合约不执行 swap，此时也不需要报价
                return null;
            }

            BigInteger effectiveIn = swapAmount.multiply(BPS.subtract(state.getSellTaxRate())).divide(BPS);
            BigInteger currentQuote = getAmountOut(effectiveIn, r.token, r.wbnb);
            BigInteger anchorQuote = anchorQuote(a, effectiveIn, true);
            if (anchorQuote == null || !within(currentQuote, anchorQuote, MAX_DEVIATION_BPS)) {
                return null;
            }
            // 保护性最低输出：当前/历史报价取更高下限再减滑点。
            // 注意：现网曾把该值写死为 1（= 关闭 router 滑点断言）。修好上面的 swapAmount 基准后
            // 可安全恢复；恢复前请先用对账脚本比对"预测值 vs 实际 quoteOut"若干个批次。
            BigInteger minQuoteOut = protectedMinOut(currentQuote, anchorQuote);
            if (minQuoteOut.signum() == 0) {
                return null;
            }
            long deadline = System.currentTimeMillis() / 1000 + DEADLINE_SECONDS;

            List<Type> params = Arrays.<Type>asList(
                    new Uint256(amountIn),
                    new Uint256(minQuoteOut),
                    new Uint64(deadline)
            );
            Function fn = new Function("processPendingTax", params, Collections.<TypeReference<?>>emptyList());
            String data = FunctionEncoder.encode(fn);
            if (!simulate(a.taxProcessor, data, transactionManager.getFromAddress(), web3j)) {
                return null;
            }
            String txhash = null;
            try {
                txhash = send(a.taxProcessor, data, transactionManager, web3j);
            } catch (Exception e) {
                throw new RuntimeException("调用方法processPendingTax出错", e);
            }
            return txhash;
        } finally {
            if (web3j != null) {
                web3j.shutdown();
            }
        }
    }


    /**
     * 当前生效的卖出/买入税率（bps）：与 taxClear 同款口径。
     * state 2=TaxEnforcedAntiFarmer、3=TaxEnforced 才收税；4=TaxFree 或已过 taxExpirationTime 时为 0。
     */
    private BigInteger poolTaxRateBps(EthCommonContract ethCommonContract, String token, boolean sellDirection) throws Exception {
        EthCommonContract.PoolState state = ethCommonContract.poolState(token);
        if (state == null) {
            // 读不到 poolState 时按"有税"处理（保守）
            return sellDirection ? BigInteger.valueOf(10_000) : BigInteger.ZERO;
        }
        BigInteger s = state.getState();
        boolean taxState = s.equals(BigInteger.valueOf(2)) || s.equals(BigInteger.valueOf(3));
        BigInteger now = BigInteger.valueOf(System.currentTimeMillis() / 1000);
        if (!taxState || now.compareTo(state.getTaxExpirationTime()) > 0) {
            return BigInteger.ZERO;
        }
        return sellDirection ? state.getSellTaxRate() : state.getBuyTaxRate();
    }

    /**
     * ② 自动加池：addPendingLiquidity(tokenAmount, minQuote, maxQuote, minLiquidity, deadline)
     *
     * 报价基准修正（重要）：合约用 _transferTokenToPair 的**实测到账量**反推所需 WBNB，而这笔
     * 转账本身要交卖税 —— FlapTaxTokenV3._taxedTransfer 先把全额转给 pair，再把税转回代币合约，
     * 所以 pair 实际只收到 tokenAmount × (1 - sellTax)。旧实现用未扣税的 tokenAmount 算 quote，
     * 在卖税生效期间会比合约期望值高约 10%，而 minQuote/maxQuote 只有 ±2% 容差，于是合约
     * `quoteAmount < minQuoteAmount` 直接 InvalidLiquidityBounds revert；又因为发送前有
     * simulate() 守门，失败被静默吞成 return null，外部只看得到"加池从不发生"。
     */
    public synchronized String addLiquidity(Asset a, ChainConfigVO chainConfig, String privateKey, String coinIssuePlatformAddress) throws Exception {
        Web3j web3j = null;
        try {
            web3j = Web3j.build(new HttpService(chainConfig.getUrl()));
            StaticGasProvider gasProvider = new StaticGasProvider(chainConfig.getDefaultGasPrice(), chainConfig.getDefaultGasLimit());
            TransactionManager transactionManager = EthCommonUtil.getTransactionManager(web3j, chainConfig.getChainId(), privateKey);
            EthCommonContract ethCommonContract = EthCommonContract.load(coinIssuePlatformAddress, web3j, transactionManager, gasProvider);

            BigInteger lpToken = ethCommonContract.readUint(a.taxProcessor, "lpTokenBalance");
            BigInteger lpQuote = ethCommonContract.readUint(a.taxProcessor, "lpQuoteBalance");
            if (lpToken.signum() == 0 || lpQuote.signum() == 0) {
                return null;
            }
            Reserves r = reserves(a, ethCommonContract);
            if (r.token.signum() == 0 || r.wbnb.signum() == 0) {
                return null;
            }

            BigInteger sellTaxBps = poolTaxRateBps(ethCommonContract, a.token, true);
            BigInteger taxComplement = BPS.subtract(sellTaxBps);

            // 名义量受单批储备上限与 lpTokenBalance 双重约束
            BigInteger tokenAmount = lpToken.min(r.token.multiply(TAX_MAX_RESERVE_BPS).divide(BPS));
            BigInteger effectiveToken = tokenAmount.multiply(taxComplement).divide(BPS);

            // 报价侧不足时按可用 WBNB 反推名义代币量，避免每轮都构造注定失败、只能被 simulate()
            // 拦下的调用；再乘 99.9% 防止整除误差越过合约的 quoteAmount > lpQuoteBalance 检查
            BigInteger affordableToken = lpQuote.multiply(r.token).divide(r.wbnb);
            BigInteger tokenCap = affordableToken.multiply(taxComplement)
                    .multiply(BigInteger.valueOf(999)).divide(BPS.multiply(BigInteger.valueOf(1000)));
            if (tokenCap.compareTo(tokenAmount) < 0) {
                tokenAmount = tokenCap;
                effectiveToken = tokenAmount.multiply(taxComplement).divide(BPS);
            }

            if (tokenAmount.signum() == 0 || effectiveToken.signum() == 0) {
                return null;
            }

            // 合约的 quoteAmount = actualToken × quoteReserve / tokenReserve，与这里同源
            BigInteger quote = effectiveToken.multiply(r.wbnb).divide(r.token);
            if (quote.signum() == 0) {
                return null;
            }
            // ±2% 用于吸收计算与上链之间的储备变化
            BigInteger minQuote = quote.multiply(BigInteger.valueOf(98)).divide(BigInteger.valueOf(100));
            BigInteger maxQuote = quote.multiply(BigInteger.valueOf(102)).divide(BigInteger.valueOf(100));
            if (minQuote.signum() == 0 || minQuote.compareTo(maxQuote) > 0) {
                return null;
            }
            long deadline = System.currentTimeMillis() / 1000 + DEADLINE_SECONDS;

            List<Type> params = Arrays.<Type>asList(
                    new Uint256(tokenAmount),
                    new Uint256(minQuote),
                    new Uint256(maxQuote),
                    new Uint256(BigInteger.ONE),
                    new Uint64(deadline)
            );
            Function fn = new Function("addPendingLiquidity", params, Collections.<TypeReference<?>>emptyList());
            String data = FunctionEncoder.encode(fn);
            if (!simulate(a.taxProcessor, data, transactionManager.getFromAddress(), web3j)) {
                return null;
            }
            String txhash = null;
            try {
                txhash = send(a.taxProcessor, data, transactionManager, web3j);
            } catch (Exception e) {
                throw new RuntimeException("调用方法addPendingLiquidity出错", e);
            }
            return txhash;
        } finally {
            if (web3j != null) {
                web3j.shutdown();
            }
        }
    }

    /** ③ 金库回购：previewBuyback → executeBuyback(expectedBnbIn, minTokenOut, minLpTokenOut, deadline) */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public synchronized String buybackJob(Asset a, int vaultMode, ChainConfigVO chainConfig, String privateKey, String coinIssuePlatformAddress) throws Exception {
        if (a.vault == null) {
            return null;
        }
        Web3j web3j = null;

        try {
            web3j = Web3j.build(new HttpService(chainConfig.getUrl()));
            StaticGasProvider gasProvider = new StaticGasProvider(chainConfig.getDefaultGasPrice(), chainConfig.getDefaultGasLimit());
            TransactionManager transactionManager = EthCommonUtil.getTransactionManager(web3j, chainConfig.getChainId(), privateKey);
            EthCommonContract ethCommonContract = EthCommonContract.load(coinIssuePlatformAddress, web3j, transactionManager, gasProvider);
            EthCommonContract.PoolState state = null;
            try {
                state = ethCommonContract.poolState(a.token);
            } catch (Exception e) {
            }
            if (state == null) {
                throw new RuntimeException("加载poolState出错");
            }
            // 先采样；readiness 非 0 的轮次也能积累历史储备。
            Reserves r = reserves(a, ethCommonContract);
            List<Type> out = ethCommonContract.call(a.vault, "previewBuyback", Collections.<Type>emptyList(),
                    Arrays.<TypeReference<?>>asList(
                            new TypeReference<Uint256>() {
                            },
                            new TypeReference<org.web3j.abi.datatypes.generated.Uint8>() {
                            }
                    ));
            BigInteger executable = (BigInteger) out.get(0).getValue();
            int readiness = ((BigInteger) out.get(1).getValue()).intValue();
            if (readiness != 0) {
                return null;
            }
            BigInteger gross = getAmountOut(executable, r.wbnb, r.token);

            BigInteger anchorQuote = anchorQuote(a, executable, false);
            if (anchorQuote == null || !within(gross, anchorQuote, MAX_DEVIATION_BPS)) {
                return null;
            }
            // Router 检查的是金库实际收到的代币，当前/历史报价都需要扣买税。
            BigInteger net = gross.multiply(BPS.subtract(state.getBuyTaxRate())).divide(BPS);
            BigInteger anchorNet = anchorQuote.multiply(BPS.subtract(state.getBuyTaxRate())).divide(BPS);
            BigInteger minTokenOut = protectedMinOut(net, anchorNet);
            BigInteger minLpTokenOut = BigInteger.ZERO;
            if (vaultMode == 1) {
                BigInteger lpIn = executable.multiply(LP_SWAP_BPS).divide(BPS);
                BigInteger lpGross = getAmountOut(lpIn, r.wbnb, r.token);
                BigInteger lpAnchor = anchorQuote(a, lpIn, false);
                if (lpAnchor == null || !within(lpGross, lpAnchor, MAX_DEVIATION_BPS)) {
                    return null;
                }
                BigInteger lpNet = lpGross.multiply(BPS.subtract(state.getBuyTaxRate())).divide(BPS);
                BigInteger lpAnchorNet = lpAnchor.multiply(BPS.subtract(state.getBuyTaxRate())).divide(BPS);
                minLpTokenOut = protectedMinOut(lpNet, lpAnchorNet);
            }
            long deadline = System.currentTimeMillis() / 1000 + DEADLINE_SECONDS;
            List<Type> params = Arrays.<Type>asList(
                    new Uint256(executable),
                    new Uint256(minTokenOut),
                    new Uint256(minLpTokenOut),
                    new Uint64(deadline)
            );
            Function fn = new Function("executeBuyback", params, Collections.<TypeReference<?>>emptyList());
            String data = FunctionEncoder.encode(fn);
            if (!simulate(a.vault, data, transactionManager.getFromAddress(), web3j)) {
                return null;
            }
            String txHash = null;
            try {
                txHash = send(a.vault, data, transactionManager, web3j);
            } catch (Exception e) {
                throw new RuntimeException("调用方法executeBuyback出错", e);
            }
            return txHash;
        } finally {
            if (web3j != null) {
                web3j.shutdown();
            }
        }
    }


    public static class Asset {
        public final String token;
        public final String taxProcessor;
        public final String pair;
        public final String vault;

        public Asset(String token, String taxProcessor, String pair, String vault) {
            this.token = token;
            this.taxProcessor = taxProcessor;
            this.pair = pair;
            this.vault = vault;
        }

        @Override
        public String toString() {
            return BeanUtil.beanToStringMap(this).toString();
        }
    }

    final Map<String, Deque<Sample>> deWindows = new ConcurrentHashMap<>(); // pair -> 样本窗口

    /** 在现有初始化巡检中读取储备；沿用原来的 wrapper 与样本窗口，不发送交易。 */
    public synchronized void samplePool(Asset a, ChainConfigVO chainConfig, String coinIssuePlatformAddress) throws Exception {
        if (a == null || StringUtils.isEmpty(a.pair)
                || "0x0000000000000000000000000000000000000000".equalsIgnoreCase(a.pair)) {
            return;
        }
        Web3j web3j = Web3j.build(new HttpService(chainConfig.getUrl()));
        try {
            EthCommonContract ethCommonContract = EthCommonContractUtil.getCommonContractRead(
                    web3j, chainConfig.getChainId(), coinIssuePlatformAddress);
            reserves(a, ethCommonContract);
        } finally {
            web3j.shutdown();
        }
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    private Reserves reserves(Asset a, EthCommonContract ethCommonContract) throws Exception {
        List<Type> r = ethCommonContract.call(a.pair, "getReserves", Collections.<Type>emptyList(),
                Arrays.<TypeReference<?>>asList(
                        new TypeReference<org.web3j.abi.datatypes.generated.Uint112>() {
                        },
                        new TypeReference<org.web3j.abi.datatypes.generated.Uint112>() {
                        },
                        new TypeReference<org.web3j.abi.datatypes.generated.Uint32>() {
                        }
                ));

        List<Type> t0Ret = ethCommonContract.call(a.pair, "token0", Collections.<Type>emptyList(),
                Collections.<TypeReference<?>>singletonList(new TypeReference<org.web3j.abi.datatypes.Address>() {
                }));
        String token0 = (String) t0Ret.get(0).getValue();

        BigInteger r0 = (BigInteger) r.get(0).getValue();
        BigInteger r1 = (BigInteger) r.get(1).getValue();

        Reserves rs;
        if (token0.equalsIgnoreCase(a.token)) {
            rs = new Reserves(r0, r1);
        } else {
            rs = new Reserves(r1, r0);
        }

        Deque<Sample> w = deWindows.computeIfAbsent(a.pair.toLowerCase(Locale.ROOT), new java.util.function.Function<String, Deque<Sample>>() {
            @Override
            public Deque<Sample> apply(String k) {
                return new ArrayDeque<Sample>();
            }
        });
        long now = System.currentTimeMillis() / 1000;
        while (!w.isEmpty() && now - w.peekFirst().ts > 3600) {
            w.pollFirst();
        }
        // 同一分钟内税费、加池、回购可能各读一次，不能把它们算成三条历史样本。
        if (w.isEmpty() || now - w.peekLast().ts >= 60) {
            w.addLast(new Sample(now, rs));
        }
        return rs;
    }

    public static BigInteger getAmountOut(BigInteger amountIn, BigInteger reserveIn, BigInteger reserveOut) {
        BigInteger inWithFee = amountIn.multiply(BPS.subtract(AMM_FEE_BPS));
        return inWithFee.multiply(reserveOut)
                .divide(reserveIn.multiply(BPS).add(inWithFee));
    }


    /** 锚点报价：窗口内每个样本算一次输出，取中位数；样本 <3 返回 null（不报价）。 */
    private BigInteger anchorQuote(Asset a, BigInteger effectiveIn, boolean sellDirection) {
        Deque<Sample> samples = deWindows.get(a.pair.toLowerCase(Locale.ROOT));
        if (samples == null) {
            return null;
        }
        List<BigInteger> quotes = new ArrayList<BigInteger>();
        for (Sample s : samples) {
            if (s.reserves.token.signum() == 0 || s.reserves.wbnb.signum() == 0) {
                continue;
            }
            BigInteger q;
            if (sellDirection) {
                q = getAmountOut(effectiveIn, s.reserves.token, s.reserves.wbnb);
            } else {
                q = getAmountOut(effectiveIn, s.reserves.wbnb, s.reserves.token);
            }
            quotes.add(q);
        }
        if (quotes.size() < 3) {
            return null;
        }
        Collections.sort(quotes);
        return quotes.get(quotes.size() / 2);
    }

    /** 偏差守门：当前价与锚点价偏差 > maxBps 则放弃本轮（正常等待，不是错误）。 */
    public static boolean within(BigInteger current, BigInteger anchor, BigInteger maxBps) {
        BigInteger diff = current.subtract(anchor).abs();
        return diff.multiply(BPS).compareTo(anchor.multiply(maxBps)) <= 0;
    }

    /** 保护性最低输出：取当前/历史报价更高的下限，再减滑点。 */
    public static BigInteger protectedMinOut(BigInteger currentQuote, BigInteger anchorQuote) {
        return currentQuote.max(anchorQuote)
                .multiply(BPS.subtract(SLIPPAGE_BPS))
                .divide(BPS);
    }

    /** 发送前必须模拟；revert 视为"本轮跳过"（资金安全留在原合约）。 */
    boolean simulate(String to, String data, String address, Web3j web3j) {
        try {
            Transaction tx = Transaction.createFunctionCallTransaction(
                    address, null, null, null, to, BigInteger.ZERO, data);
            EthCall res = web3j.ethCall(tx, DefaultBlockParameterName.PENDING).send();
            if (res.hasError()) {
                log.error("模拟调用失败，target={}，reason={}", to, res.getError().getMessage());
                return false;
            }
            // executeBuyback 无返回值，成功得到 0x；不把它解析成数字。
            return !res.isReverted() && res.getValue() != null;
        } catch (Exception e) {
            log.error("模拟调用异常，target={}", to, e);
            return false;
        }
    }

    public synchronized String send(String to, String data, TransactionManager txm, Web3j web3j) throws Exception {
        // 等上一次交易确认后再发送，避免超时后与原钱包 pending nonce 冲突。
        EthGetTransactionCount latestNonce = web3j.ethGetTransactionCount(txm.getFromAddress(), DefaultBlockParameterName.LATEST).send();
        EthGetTransactionCount pendingNonce = web3j.ethGetTransactionCount(txm.getFromAddress(), DefaultBlockParameterName.PENDING).send();
        checkRpc("latest nonce", latestNonce);
        checkRpc("pending nonce", pendingNonce);
        if (!latestNonce.getTransactionCount().equals(pendingNonce.getTransactionCount())) {
            throw new IllegalStateException("Keeper 钱包已有待确认交易，请等待或核查原交易");
        }
        Transaction tx = Transaction.createFunctionCallTransaction(txm.getFromAddress(), null, null, null, to, BigInteger.ZERO, data);
        EthEstimateGas estimate = web3j.ethEstimateGas(tx).send();
        checkRpc("eth_estimateGas", estimate);
        BigInteger estimated = estimate.getAmountUsed();
        BigInteger gasLimit = estimated.multiply(GAS_LIMIT_MULTIPLIER).divide(BigInteger.valueOf(100));
        EthGasPrice price = web3j.ethGasPrice().send();
        checkRpc("eth_gasPrice", price);
        BigInteger gasPrice = price.getGasPrice();
        EthSendTransaction resp = txm.sendTransaction(gasPrice, gasLimit, to, data, BigInteger.ZERO);
        if (resp.hasError()) {
            throw new RuntimeException("send failed: " + resp.getError().getMessage());
        }
        checkRpc("eth_sendRawTransaction", resp);
        String txHash = resp.getTransactionHash();
        TransactionReceipt receipt;
        try {
            // 沿用原 send 方法等待结果：每 1.5 秒查询，最多 40 次，约 60 秒。
            receipt = new PollingTransactionReceiptProcessor(web3j, 1500, 40).waitForTransactionReceipt(txHash);
        } catch (Exception e) {
            throw new IllegalStateException("等待交易回执失败，txHash=" + txHash, e);
        }
        if (!receipt.isStatusOK()) {
            throw new IllegalStateException("交易上链回滚，txHash=" + txHash);
        }
        return txHash;
    }

    /** RPC 报错时没有数字 result，须先检查，避免掩盖真实回滚原因。 */
    private void checkRpc(String method, Response<?> response) {
        if (response.hasError()) {
            throw new IllegalStateException(method + " failed: " + response.getError().getMessage());
        }
        if (response.getResult() == null) {
            throw new IllegalStateException(method + " returned no result");
        }
    }

    public static class Reserves {
        public final BigInteger token;
        public final BigInteger wbnb;

        public Reserves(BigInteger token, BigInteger wbnb) {
            this.token = token;
            this.wbnb = wbnb;
        }
    }

    public static class Sample {
        public final long ts;
        public final Reserves reserves;

        public Sample(long ts, Reserves reserves) {
            this.ts = ts;
            this.reserves = reserves;
        }
    }


}
