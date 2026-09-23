// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";
import {TokenConfig} from "src/TokenFactory.sol";
import {BuybackConfig, BuybackMode, TriggerMode, BuybackVault, VaultStats} from "src/BuybackVault.sol";
import {PRESALE} from "src/Presale.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IPancakeRouter02, IPancakePair} from "src/lib/interfaces/IPancakeRouter02.sol";
import {VanitySaltFinder} from "../test/TokenReservation.t.sol";

/// @notice 测试网 Keeper 端到端验收脚本，对应 docs/keeper-cloudflare.md 阶段 E 第 3~7 步。
/// @dev 入口（用 `--sig` 调用）：
///      1. create()：一笔广播内完成 发币(带金库) → claimAllTokens 领取即上线 → 加 Pancake V2 底池
///                   → 两笔卖出把税推过动态清算阈值。建池与卖出必须同批，否则 Keeper 的
///                   5~60 分钟历史锚点会包含卖出前价格，偏差超 3% 时它会（按设计）拒绝执行。
///      2. trade() ：需要追加应税成交时再卖出若干笔（可选）。
///      3. status()：只读打印 Pair 储备、poolState、待处理税与金库状态。
///
///      脚本不做权限提升：发币人 = 加池人 = 卖出人 = 广播账户，全部是普通用户权限。
///      Coordinator 地址取自 script/deployments/<chainid>.json，可用 COORDINATOR_ADDRESS 覆盖。
///      验收产物写入 script/deployments/<chainid>-keeper-acceptance.json（dry-run 不写）。
///
///      用法（仓库根目录，keystore 密码只在交互式提示中输入）：
///        forge script script/KeeperAcceptance.s.sol:KeeperAcceptance --sig "create()" \
///          --rpc-url <BSC testnet RPC> --account launchpad-testnet-deployer --legacy --broadcast --slow
contract KeeperAcceptance is Script {
    uint256 internal constant BSC_TESTNET_CHAIN_ID = 97;
    uint64 internal constant DEADLINE_DELAY = 20 minutes;
    /// @dev SELL_TAX_BPS=1000 时单笔 1e8 枚产出 1e7 枚税代币（= 实现合约 START_LIQ_THRESHOLD）
    uint256 internal constant DEFAULT_SELL_TOKENS = 100_000_000 ether;

    struct Artifact {
        address token;
        address presale;
        address vault;
        address pair;
        uint256 lpTokens;
        uint256 lpBnb;
    }

    // -----------------------------------------------------------------------
    // 阶段 3~4：发币（带金库）→ 开盘 → 加池 → 制造应税交易
    // -----------------------------------------------------------------------

    function create() external {
        _requireTestnet();
        CoordinatorFactory coordinator = _coordinator();
        address router = coordinator.routerAddress();
        uint256 creationFee = coordinator.creationFee();

        uint256 lpTokens = vm.envOr("ACCEPTANCE_LP_TOKENS", uint256(300_000_000 ether));
        uint256 lpBnb = vm.envOr("ACCEPTANCE_LP_BNB", uint256(0.2 ether));
        uint256 sellTokens = vm.envOr("ACCEPTANCE_SELL_TOKENS", DEFAULT_SELL_TOKENS);
        uint256 rounds = vm.envOr("ACCEPTANCE_SELL_ROUNDS", uint256(2));
        require(lpTokens + sellTokens * rounds <= 1_000_000_000 ether, "lpTokens + sells exceed supply");

        bytes32 salt = _vanitySalt(address(coordinator.tokenFactory()), _saltTag());

        TokenConfig memory config = TokenConfig({
            name: vm.envOr("ACCEPTANCE_NAME", string("Keeper Acceptance Token")),
            symbol: vm.envOr("ACCEPTANCE_SYMBOL", string("KAT")),
            meta: "",
            buyTax: uint16(vm.envOr("ACCEPTANCE_BUY_TAX_BPS", uint256(500))),
            sellTax: uint16(vm.envOr("ACCEPTANCE_SELL_TAX_BPS", uint256(1000))),
            // 金库模式下 Coordinator 会把该字段覆盖为金库地址，这里只需非零
            feeRecipient: msg.sender,
            marketBps: uint16(vm.envOr("ACCEPTANCE_MARKET_BPS", uint256(4_000))),
            deflationBps: uint16(vm.envOr("ACCEPTANCE_DEFLATION_BPS", uint256(1_000))),
            lpBps: uint16(vm.envOr("ACCEPTANCE_LP_BPS", uint256(2_000))),
            dividendBps: uint16(vm.envOr("ACCEPTANCE_DIVIDEND_BPS", uint256(3_000))),
            minimumShareBalance: vm.envOr("ACCEPTANCE_MINIMUM_SHARE_BALANCE", uint256(10_000 ether)),
            antiFarmerDuration: vm.envOr("ACCEPTANCE_ANTI_FARMER_DURATION", uint256(0)),
            liqExpectedOutputAmount: 0
        });

        BuybackConfig memory buyback = BuybackConfig({
            mode: BuybackMode(vm.envOr("ACCEPTANCE_BUYBACK_MODE", uint256(0))),
            trigger: TriggerMode(vm.envOr("ACCEPTANCE_TRIGGER_MODE", uint256(0))),
            // 金库要求 firstExecuteAt ≥ 执行时 block.timestamp + 60；取 600 s 以容忍模拟与广播之间的时间偏差
            firstExecuteAt: uint64(block.timestamp + vm.envOr("ACCEPTANCE_FIRST_EXECUTE_DELAY", uint256(600))),
            intervalSeconds: uint64(vm.envOr("ACCEPTANCE_INTERVAL_SECONDS", uint256(60))),
            triggerAmount: vm.envOr("ACCEPTANCE_TRIGGER_AMOUNT", uint256(0)),
            // 单次上限；实际执行额还会被金库余额与 Pair WBNB 储备的 1% 安全线动态缩小
            buybackAmount: vm.envOr("ACCEPTANCE_BUYBACK_AMOUNT", uint256(0.001 ether))
        });

        vm.startBroadcast();
        (address token, address presale, address vault) =
            coordinator.createTokenWithVault{value: creationFee}(config, salt, buyback);
        PRESALE(payable(presale)).claimAllTokens();
        IERC20(token).approve(router, lpTokens);
        IPancakeRouter02(router).addLiquidityETH{value: lpBnb}(
            token, lpTokens, 0, 0, msg.sender, block.timestamp + DEADLINE_DELAY
        );
        IERC20(token).approve(router, type(uint256).max);
        _sell(router, token, sellTokens, rounds);
        vm.stopBroadcast();

        address pair = FlapTaxTokenV3(token).mainPool();
        Artifact memory artifact =
            Artifact({token: token, presale: presale, vault: vault, pair: pair, lpTokens: lpTokens, lpBnb: lpBnb});
        // 模拟运行（不带 --broadcast）不得写出可能被误当成广播结果的产物文件
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("dry run: artifact not written");
        } else {
            _writeArtifact(artifact);
        }

        console2.log("token:", token);
        console2.log("presale:", presale);
        console2.log("vault:", vault);
        console2.log("pair:", pair);
        console2.log("taxProcessor:", FlapTaxTokenV3(token).taxProcessor());
        console2.log("dividend:", FlapTaxTokenV3(token).dividendContract());
        console2.log("creator token balance:", IERC20(token).balanceOf(msg.sender));
        _logState(artifact);
        console2.log("next: wait >= 8 minutes, then run status() and read D1 keeper_runs/transactions");
    }

    /// @notice 恢复 create() 在代币已创建、已领取，但加池前因本地广播文件锁中断的验收。
    /// @dev 只允许对当前 Coordinator 注册的、尚无 LP 的验收资产使用；不会重复创建代币。
    function completeSetup() external {
        _requireTestnet();
        Artifact memory artifact = _readArtifact();
        CoordinatorFactory coordinator = _coordinator();
        require(coordinator.tokenVaults(artifact.token) == artifact.vault, "vault not registered in coordinator");
        require(FlapTaxTokenV3(artifact.token).mainPool() == artifact.pair, "pair mismatch");
        require(IPancakePair(artifact.pair).totalSupply() == 0, "pool already initialized");

        uint256 sellTokens = vm.envOr("ACCEPTANCE_SELL_TOKENS", DEFAULT_SELL_TOKENS);
        uint256 rounds = vm.envOr("ACCEPTANCE_SELL_ROUNDS", uint256(2));
        require(
            IERC20(artifact.token).balanceOf(msg.sender) >= artifact.lpTokens + sellTokens * rounds,
            "creator tokens insufficient"
        );

        address router = coordinator.routerAddress();
        vm.startBroadcast();
        IERC20(artifact.token).approve(router, artifact.lpTokens);
        IPancakeRouter02(router).addLiquidityETH{value: artifact.lpBnb}(
            artifact.token, artifact.lpTokens, 0, 0, msg.sender, block.timestamp + DEADLINE_DELAY
        );
        IERC20(artifact.token).approve(router, type(uint256).max);
        _sell(router, artifact.token, sellTokens, rounds);
        vm.stopBroadcast();

        _logState(artifact);
    }

    // -----------------------------------------------------------------------
    // 可选：追加应税成交
    // -----------------------------------------------------------------------

    function trade() external {
        _requireTestnet();
        Artifact memory artifact = _readArtifact();
        address router = _coordinator().routerAddress();
        uint256 sellTokens = vm.envOr("ACCEPTANCE_SELL_TOKENS", DEFAULT_SELL_TOKENS);
        uint256 rounds = vm.envOr("ACCEPTANCE_SELL_ROUNDS", uint256(1));

        vm.startBroadcast();
        IERC20(artifact.token).approve(router, type(uint256).max);
        _sell(router, artifact.token, sellTokens, rounds);
        vm.stopBroadcast();

        _logState(artifact);
    }

    // -----------------------------------------------------------------------
    // 只读核对
    // -----------------------------------------------------------------------

    function status() external view {
        _requireTestnet();
        Artifact memory artifact = _readArtifact();
        console2.log("token:", artifact.token);
        console2.log("vault:", artifact.vault);
        console2.log("pair:", artifact.pair);
        _logState(artifact);
        _logVault(artifact);
    }

    // -----------------------------------------------------------------------
    // 内部工具
    // -----------------------------------------------------------------------

    function _sell(address router, address token, uint256 sellTokens, uint256 rounds) internal {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = IPancakeRouter02(router).WETH();
        for (uint256 i = 0; i < rounds; i++) {
            IPancakeRouter02(router)
                .swapExactTokensForETHSupportingFeeOnTransferTokens(
                    sellTokens, 0, path, msg.sender, block.timestamp + DEADLINE_DELAY
                );
        }
    }

    function _requireTestnet() internal view {
        require(block.chainid == BSC_TESTNET_CHAIN_ID, "keeper acceptance is BSC testnet only");
    }

    function _coordinator() internal view returns (CoordinatorFactory) {
        address configured = vm.envOr("COORDINATOR_ADDRESS", address(0));
        if (configured != address(0)) return CoordinatorFactory(configured);
        string memory path = string.concat("script/deployments/", vm.toString(block.chainid), ".json");
        require(vm.exists(path), "deployment file missing; set COORDINATOR_ADDRESS");
        return CoordinatorFactory(vm.parseJsonAddress(vm.readFile(path), ".coordinatorFactory"));
    }

    function _saltTag() internal view returns (string memory) {
        return vm.envOr("ACCEPTANCE_SALT_TAG", string.concat("keeper-acceptance-", vm.toString(block.chainid)));
    }

    /// @dev 与 test/TokenReservation.t.sol 的 VanitySaltFinder 同一公式（低 16 bit == 0x8888）。
    ///      复用验收盐标签重跑会撞已部署地址，需要换 ACCEPTANCE_SALT_TAG。
    function _vanitySalt(address tokenFactory, string memory tag) internal view returns (bytes32 salt) {
        bool found;
        (salt, found) = VanitySaltFinder.find(
            tokenFactory, TokenFactoryLike(tokenFactory).flapImplementation(), uint256(keccak256(bytes(tag)))
        );
        require(found, "vanity salt not found within budget");
    }

    function _artifactPath() internal view returns (string memory) {
        return string.concat("script/deployments/", vm.toString(block.chainid), "-keeper-acceptance.json");
    }

    function _writeArtifact(Artifact memory artifact) internal {
        string memory key = "acceptance";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "token", artifact.token);
        vm.serializeAddress(key, "presale", artifact.presale);
        vm.serializeAddress(key, "vault", artifact.vault);
        vm.serializeAddress(key, "pair", artifact.pair);
        vm.serializeUint(key, "lpTokens", artifact.lpTokens);
        string memory json = vm.serializeUint(key, "lpBnb", artifact.lpBnb);
        vm.writeJson(json, _artifactPath());
    }

    function _readArtifact() internal view returns (Artifact memory artifact) {
        string memory path = _artifactPath();
        require(vm.exists(path), "acceptance artifact missing; run create() first");
        string memory json = vm.readFile(path);
        artifact.token = vm.parseJsonAddress(json, ".token");
        artifact.presale = vm.parseJsonAddress(json, ".presale");
        artifact.vault = vm.parseJsonAddress(json, ".vault");
        artifact.pair = vm.parseJsonAddress(json, ".pair");
        artifact.lpTokens = vm.parseJsonUint(json, ".lpTokens");
        artifact.lpBnb = vm.parseJsonUint(json, ".lpBnb");
    }

    function _logState(Artifact memory artifact) internal view {
        (uint8 state, uint16 buyTax, uint16 sellTax,, uint96 threshold, uint256 taxExpiration,) =
            FlapTaxTokenV3(artifact.token).poolState();
        (uint112 reserve0, uint112 reserve1,) = IPancakePair(artifact.pair).getReserves();
        console2.log("poolState:", state);
        console2.log("buyTax bps:", buyTax);
        console2.log("sellTax bps:", sellTax);
        console2.log("liquidationThreshold:", uint256(threshold));
        console2.log("taxExpirationTime:", taxExpiration);
        console2.log("pair reserve0:", uint256(reserve0));
        console2.log("pair reserve1:", uint256(reserve1));
        console2.log("token contract tax balance:", IERC20(artifact.token).balanceOf(artifact.token));
        PendingTaxLike processor = PendingTaxLike(FlapTaxTokenV3(artifact.token).taxProcessor());
        console2.log("pendingTaxTokens:", processor.pendingTaxTokens());
        console2.log("lpTokenBalance:", processor.lpTokenBalance());
        console2.log("lpQuoteBalance:", processor.lpQuoteBalance());
        console2.log("pendingDividendQuote:", processor.pendingDividendQuoteTokenBalance());
    }

    function _logVault(Artifact memory artifact) internal view {
        if (artifact.vault == address(0)) return;
        VaultStats memory stats = BuybackVault(payable(artifact.vault)).getVaultStats();
        console2.log("vault balance:", artifact.vault.balance);
        console2.log("vault canExecute:", stats.canExecute);
        console2.log("vault maxBuybackAmount:", stats.buybackAmount);
        console2.log("vault executableBuybackAmount:", stats.executableBuybackAmount);
        console2.log("vault readiness:", uint8(stats.readiness));
        console2.log("vault buybackCount:", stats.buybackCount);
        console2.log("vault totalBurnedToken:", stats.totalBurnedToken);
    }
}

interface TokenFactoryLike {
    function flapImplementation() external view returns (address);
}

interface PendingTaxLike {
    function pendingTaxTokens() external view returns (uint256);
    function lpTokenBalance() external view returns (uint256);
    function lpQuoteBalance() external view returns (uint256);
    function pendingDividendQuoteTokenBalance() external view returns (uint256);
}
