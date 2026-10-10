package cn.ztuo.bitrade.job.common;

import cn.ztuo.bitrade.config.CommonConfig;
import cn.ztuo.bitrade.config.address.CommonAddressApi;
import cn.ztuo.bitrade.entity.coinIssue.CoinIssued;
import cn.ztuo.bitrade.entity.system.SysCommonConfig;
import cn.ztuo.bitrade.service.CoinIssuedJobService;
import cn.ztuo.bitrade.service.chain.EthContractService;
import cn.ztuo.bitrade.service.system.SysCommonConfigService;
import com.aioff.trade.chain.entity.vo.ChainConfigVO;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import javax.annotation.PostConstruct;
import javax.annotation.PreDestroy;
import java.util.*;
import java.util.concurrent.*;
import java.util.stream.Collectors;

/**
 * 2026-09-29
 * 回购定时任务处理
 */
@Component
@RequiredArgsConstructor
@Slf4j
public class BuyBackScheduleManager {

    private final CoinIssuedJobService coinIssuedJobService;
    private final SysCommonConfigService sysCommonConfigService;
    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final Map<Long, ScheduledFuture<?>> taskFutureMap = new ConcurrentHashMap<>();
    // 本轮尝试过就按原 intervalSeconds 重试，避免第一次跳过时立即递归空跑。
    private final Set<Long> attemptedTaskIds = ConcurrentHashMap.newKeySet();
    private final ScheduledExecutorService delayScheduler = Executors.newSingleThreadScheduledExecutor();

    private ScheduledExecutorService scanScheduler;

    private static final long SCAN_INTERVAL = 3000;
    private final EthContractService ethContractService;
    private final static String privateKey = "替换为Keeper钱包私钥";

    private final CommonAddressApi commonAddressApi;

    private final static Map<String, EthContractService.Asset> assetMap = new ConcurrentHashMap<>();


    //实时加载 需要下面定时任务需要的参数
    @Scheduled(cron = "0/30 * * * * ?")
    public void buyBackValueInitJob() {
        SysCommonConfig config = sysCommonConfigService.findByName("buyBackValueInitJob");
        if (config == null || "0".equals(config.getValue())) {
            return;
        }
        ChainConfigVO chainConfig = CommonConfig.chainConfig;
        if (null == chainConfig) {
            log.error("未获取到链配置信息");
            return;
        }
        String coinIssuePlatformAddress = commonAddressApi.getCoinIssuePlatformAddress();
        if (StringUtils.isBlank(coinIssuePlatformAddress)) {
            log.info("未获取到合约地址");
            return;
        }
        try {
            List<EthContractService.Asset> assets = ethContractService.getAssets(chainConfig, coinIssuePlatformAddress);
            Set<String> currentTokens = assets.stream().filter(Objects::nonNull)
                    .map(o -> o.token.toLowerCase(Locale.ROOT)).collect(Collectors.toSet());
            assetMap.keySet().removeIf(key -> !currentTokens.contains(key));
            assets.forEach(o -> {
                if (o != null)
                    assetMap.put(o.token.toLowerCase(Locale.ROOT), o);
            });
            for (EthContractService.Asset asset : assets) {
                if (asset == null) continue;
                // 沿用这个 30 秒巡检入口采样；服务内每个池每分钟最多保存一条。
                // 无税费或回购未到期时，也能积累原来的历史报价窗口。
                try {
                    ethContractService.samplePool(asset, chainConfig, coinIssuePlatformAddress);
                } catch (Exception e) {
                    log.error("读取主池储备失败，token={}", asset.token, e);
                }
                try {
                    String txhash = ethContractService.taxClear(asset, chainConfig, privateKey, coinIssuePlatformAddress);
                    if (txhash != null) {
                        coinIssuedJobService.saveLog(txhash, asset, "processPendingTax");
                    }
                } catch (Exception e) {
                    log.error("处理税费失败，token={}", asset.token, e);
                    coinIssuedJobService.saveLog(e.getMessage(), asset);
                }


            }
        } catch (Exception e) {
            log.error("加载 Keeper 资产失败", e);
        }
    }

    public synchronized void checkAndStartSch() {
        //判断是否开启
        SysCommonConfig config = sysCommonConfigService.findByName("buyBackLoadJob");
        if (config == null || "0".equals(config.getValue())) {
            return;
        }
        ChainConfigVO chainConfig = CommonConfig.chainConfig;
        if (null == chainConfig) {
            log.error("未获取到链配置信息");
            return;
        }
        String coinIssuePlatformAddress = commonAddressApi.getCoinIssuePlatformAddress();
        if (StringUtils.isBlank(coinIssuePlatformAddress)) {
            log.info("未获取到合约地址");
            return;
        }
        if (scanScheduler == null) {
            loadAndStartAllBuyBackTask(chainConfig, coinIssuePlatformAddress);
            scanScheduler = Executors.newSingleThreadScheduledExecutor();
            scanScheduler.scheduleAtFixedRate(this::scanNewTask, 5, SCAN_INTERVAL, TimeUnit.MILLISECONDS);
            log.info("任务扫描器已启动，扫描间隔：" + SCAN_INTERVAL + "ms");
        }
    }




    private void scanNewTask() {
        try {
            //判断是否开启
            SysCommonConfig config = sysCommonConfigService.findByName("buyBackLoadJob");
            if (config == null || "0".equals(config.getValue())) {
                return;
            }
            ChainConfigVO chainConfig = CommonConfig.chainConfig;
            if (null == chainConfig) {
                log.error("未获取到链配置信息");
                return;
            }
            String coinIssuePlatformAddress = commonAddressApi.getCoinIssuePlatformAddress();
            if (StringUtils.isBlank(coinIssuePlatformAddress)) {
                log.info("未获取到合约地址");
                return;
            }
            List<CoinIssued> dbEnabledTaskList = coinIssuedJobService.findByBuybackVaultEnabled(1);
            Set<Long> runningTaskIds = taskFutureMap.keySet();
            for (CoinIssued task : dbEnabledTaskList) {
                Long taskId = task.getId();
                if (!runningTaskIds.contains(taskId)) {
                    log.info("扫描发现新增任务 id:" + taskId);
                    scheduleNextRun(taskId, chainConfig, coinIssuePlatformAddress);
                }
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    private void loadAndStartAllBuyBackTask(ChainConfigVO configVO, String coinIssuePlatformAddress) {
        List<CoinIssued> taskList = coinIssuedJobService.findByBuybackVaultEnabled(1);
        for (CoinIssued task : taskList) {
            scheduleNextRun(task.getId(), configVO, coinIssuePlatformAddress);
        }
        System.out.println("初始化加载任务数量：" + taskList.size());
    }

    public synchronized void scheduleNextRun(Long taskId, ChainConfigVO configVO, String coinIssuePlatformAddress) {
        CoinIssued task = coinIssuedJobService.findById(taskId);
        SysCommonConfig config = sysCommonConfigService.findByName("buyBackLoadJob");
        if (task == null || task.getBuybackVaultEnabled() != 1 || Optional.ofNullable(config).map(SysCommonConfig::getValue).orElse("0").equals("0")) {
            ScheduledFuture<?> oldFuture = taskFutureMap.remove(taskId);
            attemptedTaskIds.remove(taskId);
            if (oldFuture != null && !oldFuture.isDone()) {
                oldFuture.cancel(false);
            }
            return;
        }

        long now = System.currentTimeMillis();
        long nextExecuteTime;
        long delayMs;

        // ========== 修复核心逻辑 ==========
        if (!attemptedTaskIds.contains(taskId)
                && (task.getLastExecuteAt() == null || task.getLastExecuteAt() == 0)) {
            // 【第一次执行】没有上次执行记录
            if (task.getFirstExecuteAt() == null || task.getFirstExecuteAt() == 0) {
                // firstExecuteAt=0：第一次立刻执行
                nextExecuteTime = now;
            } else {
                // firstExecuteAt>0：等到指定时间再执行（firstExecuteAt是秒）
                long firstMs = task.getFirstExecuteAt() * 1000L;
                nextExecuteTime = firstMs;
            }
        } else {
            // 【已经执行过】上一次执行完成后，间隔 intervalSeconds 再跑
            nextExecuteTime = now + task.getIntervalSeconds() * 1000L;
        }

        delayMs = nextExecuteTime - now;
        if (delayMs < 0) {
            delayMs = 0;
        }

        ScheduledFuture<?> oldFuture = taskFutureMap.get(taskId);
        if (oldFuture != null && !oldFuture.isDone()) {
            oldFuture.cancel(false);
        }

        ScheduledFuture<?> future = delayScheduler.schedule(() -> {
            executor.submit(() -> {
                try {
                    // 业务逻辑
                    // 延迟期间可能关闭开关/禁用代币，实际执行前重新确认。
                    SysCommonConfig currentConfig = sysCommonConfigService.findByName("buyBackLoadJob");
                    CoinIssued currentTask = coinIssuedJobService.findById(taskId);
                    if (currentTask == null || currentTask.getBuybackVaultEnabled() != 1
                            || currentConfig == null || "0".equals(currentConfig.getValue())) {
                        return;
                    }
                    String coinContractAddress = currentTask.getCoinContractAddress();
                    if (StringUtils.isEmpty(coinContractAddress)) {
                        return;
                    }
                    EthContractService.Asset asset = assetMap.get(coinContractAddress.toLowerCase(Locale.ROOT));
                    if (asset == null) {
                        return;
                    }
                    String txhash = null;
                    try {
                        txhash = ethContractService.addLiquidity(asset, configVO, privateKey, coinIssuePlatformAddress);
                        if (txhash != null) {
                            coinIssuedJobService.saveLog(txhash, asset, "addPendingLiquidity");
                        }
                    } catch (Exception e) {
                        log.error("自动加池失败，token={}", asset.token, e);
                        coinIssuedJobService.saveLog(e.getMessage(), asset);
                    }
                    try {
                        txhash = ethContractService.buybackJob(asset, currentTask.getMode(), configVO, privateKey, coinIssuePlatformAddress);
                        if (txhash != null) {
                            // send 已等待成功回执，才记录本地确认时间；null 表示跳过。
                            coinIssuedJobService.updateLastExecuteAtById(System.currentTimeMillis() / 1000, taskId);
                            coinIssuedJobService.saveLog(txhash, asset, "executeBuyback");
                        }
                    } catch (Exception e) {
                        log.error("金库回购失败，token={}", asset.token, e);
                        coinIssuedJobService.saveLog(e.getMessage(), asset);
                    }

                } catch (Exception e) {
                    e.printStackTrace();
                } finally {
                    try {
                        attemptedTaskIds.add(taskId);
                        if (!executor.isShutdown() && !delayScheduler.isShutdown()) {
                            scheduleNextRun(taskId, configVO, coinIssuePlatformAddress);
                        }
                    } catch (Exception ex) {
                        ex.printStackTrace();
                    }
                }
            });
        }, delayMs, TimeUnit.MILLISECONDS);

        taskFutureMap.put(taskId, future);
        log.info("任务[{}] 调度成功，延迟{}", taskId, delayMs);
    }


    @PreDestroy
    public void shutdown() {
        if (scanScheduler != null) {
            scanScheduler.shutdown();
        }
        delayScheduler.shutdown();
        executor.shutdown();
        try {
            if (scanScheduler != null && !scanScheduler.awaitTermination(3, TimeUnit.SECONDS)) {
                scanScheduler.shutdownNow();
            }
            if (!delayScheduler.awaitTermination(3, TimeUnit.SECONDS)) {
                delayScheduler.shutdownNow();
            }
            if (!executor.awaitTermination(3, TimeUnit.SECONDS)) {
                executor.shutdownNow();
            }
        } catch (InterruptedException e) {
            if (scanScheduler != null) scanScheduler.shutdownNow();
            delayScheduler.shutdownNow();
            executor.shutdownNow();
        }
    }


}
