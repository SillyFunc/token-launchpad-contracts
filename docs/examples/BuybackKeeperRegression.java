import org.web3j.protocol.core.Response;
import org.web3j.protocol.core.methods.response.EthEstimateGas;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigInteger;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Map;

/** 无需 JUnit 的最小回归：编译后运行 java BuybackKeeperRegression。 */
@SuppressWarnings({"rawtypes", "unchecked"})
public class BuybackKeeperRegression {
    private static final BuybackKeeperService SERVICE = new BuybackKeeperService();
    private static final BuybackKeeperService.Asset ASSET = new BuybackKeeperService.Asset(
            "token", "processor", "0xAbCd", "vault");
    private static final Class<?> RESERVES;
    private static final Constructor<?> RESERVES_CTOR;
    private static final Constructor<?> SAMPLE_CTOR;
    private static final Method AMOUNT_OUT;
    private static final Method ANCHOR;
    private static final Deque WINDOW = new ArrayDeque();

    static {
        try {
            RESERVES = Class.forName("BuybackKeeperService$Reserves");
            RESERVES_CTOR = RESERVES.getDeclaredConstructor(BigInteger.class, BigInteger.class);
            RESERVES_CTOR.setAccessible(true);
            SAMPLE_CTOR = Class.forName("BuybackKeeperService$Sample").getDeclaredConstructor(
                    BigInteger.class, long.class, RESERVES);
            SAMPLE_CTOR.setAccessible(true);
            AMOUNT_OUT = method("getAmountOut", BigInteger.class, BigInteger.class, BigInteger.class);
            ANCHOR = method("anchorQuote", BuybackKeeperService.Asset.class, long.class,
                    BigInteger.class, boolean.class, long.class);
            Field field = BuybackKeeperService.class.getDeclaredField("deWindows");
            field.setAccessible(true);
            Map windows = (Map) field.get(SERVICE);
            windows.put("97:0xabcd", WINDOW);
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    public static void main(String[] args) throws Exception {
        // 三条刚采集的样本仍不能作为历史锚点。
        reset();
        sample(400, 100000); sample(401, 100000); sample(402, 100000);
        equal(null, anchor(420), "fresh samples must be excluded");

        // 每分钟采样，六分钟时只有两条满足年龄；七分钟时有三条。
        reset();
        sample(0, 100000); sample(60, 100000); sample(120, 100000);
        equal(null, anchor(360), "two eligible samples must wait");
        equal(quote(100000), anchor(420), "third eligible sample enables quote");

        // 超过一小时的记录不能用于凑满有效样本数量。
        reset();
        sample(0, 100000); sample(3300, 100000); sample(3301, 100000);
        equal(null, anchor(3601), "expired sample must be excluded");

        // 两侧储备为零的样本没有报价信息。
        reset();
        sample(0, 100000); sample(60, 100000); sample(120, 0);
        equal(null, anchor(420), "zero reserves must be excluded");

        // 偶数个有效报价取两个中间值的平均，与仓库策略一致。
        reset();
        sample(0, 100000); sample(60, 110000); sample(120, 120000); sample(180, 130000);
        equal(quote(110000).add(quote(120000)).divide(BigInteger.valueOf(2)), anchor(480), "even median");

        // 大小写不同的地址应使用同一窗口键。
        equal("97:0xabcd", method("sampleKey", long.class, String.class).invoke(null, 97L, "0xABCD"), "address normalization");

        // 复现用户截图的税前/税后最低输出差异。
        BigInteger gross = new BigInteger("61062659519686468711547");
        BigInteger net = (BigInteger) method("afterTax", BigInteger.class, BigInteger.class)
                .invoke(SERVICE, gross, BigInteger.valueOf(1000));
        equal(new BigInteger("54956393567717821840392"), net, "buy tax deduction");
        equal(new BigInteger("54406829632040643621988"),
                method("protectedMinOut", BigInteger.class, BigInteger.class).invoke(SERVICE, net, net), "correct floor");
        equal(BigInteger.valueOf(10098), method("protectedMinOut", BigInteger.class, BigInteger.class)
                .invoke(SERVICE, BigInteger.valueOf(10000), BigInteger.valueOf(10200)), "use higher protected floor");

        // RPC 错误必须保留真实回滚原因，不能继续解析缺失的 result。
        EthEstimateGas response = new EthEstimateGas();
        Response.Error error = new Response.Error();
        error.setCode(3);
        error.setMessage("execution reverted: PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        response.setError(error);
        try {
            method("requireResult", String.class, Response.class).invoke(null, "eth_estimateGas", response);
            throw new AssertionError("RPC error was accepted");
        } catch (InvocationTargetException e) {
            if (!(e.getCause() instanceof IllegalStateException)
                    || !e.getCause().getMessage().contains("INSUFFICIENT_OUTPUT_AMOUNT")) {
                throw new AssertionError("Original RPC reason lost", e);
            }
        }
        System.out.println("PASS: sample age/count/zero reserves/median, normalization, buy tax, protected floor, RPC error guard");
    }

    private static Method method(String name, Class<?>... types) throws Exception {
        Method method = BuybackKeeperService.class.getDeclaredMethod(name, types);
        method.setAccessible(true);
        return method;
    }

    private static void reset() { WINDOW.clear(); }

    private static void sample(long ts, long tokenReserve) throws Exception {
        Object reserves = RESERVES_CTOR.newInstance(BigInteger.valueOf(tokenReserve), BigInteger.valueOf(1000));
        WINDOW.addLast(SAMPLE_CTOR.newInstance(BigInteger.valueOf(ts + 1), ts, reserves));
    }

    private static BigInteger anchor(long now) throws Exception {
        return (BigInteger) ANCHOR.invoke(SERVICE, ASSET, 97L, BigInteger.valueOf(1000), false, now);
    }

    private static BigInteger quote(long tokenReserve) throws Exception {
        return (BigInteger) AMOUNT_OUT.invoke(SERVICE, BigInteger.valueOf(1000),
                BigInteger.valueOf(1000), BigInteger.valueOf(tokenReserve));
    }

    private static void equal(Object expected, Object actual, String message) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }
}
