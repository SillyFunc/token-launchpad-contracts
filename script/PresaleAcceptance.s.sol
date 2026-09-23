// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";
import {TokenConfig} from "src/TokenFactory.sol";
import {PresaleConfig} from "src/PresaleFactory.sol";
import {BuybackConfig, BuybackMode, TriggerMode, BuybackVault, VaultStats} from "src/BuybackVault.sol";
import {PRESALE} from "src/Presale.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IPancakeRouter02, IPancakePair} from "src/lib/interfaces/IPancakeRouter02.sol";
import {VanitySaltFinder} from "../test/TokenReservation.t.sol";

/// @notice 预售模式端到端验收 + 托管仓分红泄漏复现脚本（BSC testnet only）。
/// @dev 入口（用 `--sig` 调用，全部以广播账户 = 创建者身份执行）：
///      1. create()        ：带金库发币 → setupPresale（含创建者购买注资）→ openPresale。
///      2. closeAndLaunch()：散户认购达标后调用，endPresale → launch →（有库存则）首轮卖出。
///      3. claimAndSell()  ：归属解锁后 claim 创建者份额并卖出，把累计税推过清算阈值。
///      4. proveLeak()     ：泄漏复现——先读 withdrawableDividends(presale)，再
///                           withdrawDividendsFor(presale) + withdrawRemainingBNB()，
///                           托管仓累计分红被创建者扫走。
///      5. status()        ：只读打印预售/池/税/金库/分红全状态。
///      产物写入 script/deployments/<chainid>-presale-acceptance.json（dry-run 不写）。
contract PresaleAcceptance is Script {
    uint256 internal constant BSC_TESTNET_CHAIN_ID = 97;
    uint64 internal constant DEADLINE_DELAY = 20 minutes;

    struct Artifact {
        address token;
        address presale;
        address vault;
        address pair;
        address dividend;
        address taxProcessor;
    }

    // -----------------------------------------------------------------------
    // 阶段 1：带金库发币 + 预售配置 + 开启认购
    // -----------------------------------------------------------------------

    function create() external {
        _requireTestnet();
        CoordinatorFactory coordinator = _coordinator();
        uint256 creationFee = coordinator.creationFee();

        bytes32 salt = _vanitySalt(address(coordinator.tokenFactory()), _saltTag());

        TokenConfig memory config = TokenConfig({
            name: vm.envOr("ACCEPTANCE_NAME", string("Presale Acceptance Token")),
            symbol: vm.envOr("ACCEPTANCE_SYMBOL", string("PAT")),
            meta: "",
            buyTax: uint16(vm.envOr("ACCEPTANCE_BUY_TAX_BPS", uint256(500))),
            sellTax: uint16(vm.envOr("ACCEPTANCE_SELL_TAX_BPS", uint256(1000))),
            feeRecipient: msg.sender, // 金库模式下被 Coordinator 覆盖为金库地址
            marketBps: uint16(vm.envOr("ACCEPTANCE_MARKET_BPS", uint256(4_000))),
            deflationBps: uint16(vm.envOr("ACCEPTANCE_DEFLATION_BPS", uint256(1_000))),
            lpBps: uint16(vm.envOr("ACCEPTANCE_LP_BPS", uint256(2_000))),
            dividendBps: uint16(vm.envOr("ACCEPTANCE_DIVIDEND_BPS", uint256(3_000))),
            minimumShareBalance: vm.envOr("ACCEPTANCE_MINIMUM_SHARE_BALANCE", uint256(10_000 ether)),
            antiFarmerDuration: uint256(0),
            liqExpectedOutputAmount: 0
        });

        BuybackConfig memory buyback = BuybackConfig({
            mode: BuybackMode(vm.envOr("ACCEPTANCE_BUYBACK_MODE", uint256(0))),
            trigger: TriggerMode.Time,
            firstExecuteAt: uint64(block.timestamp + vm.envOr("ACCEPTANCE_FIRST_EXECUTE_DELAY", uint256(1200))),
            intervalSeconds: uint64(vm.envOr("ACCEPTANCE_INTERVAL_SECONDS", uint256(60))),
            triggerAmount: 0,
            buybackAmount: vm.envOr("ACCEPTANCE_BUYBACK_AMOUNT", uint256(0.001 ether))
        });

        PresaleConfig memory presaleConfig = PresaleConfig({
            presaleTokenPrice: vm.envOr("PRESALE_TOKEN_PRICE", uint256(1e9)), // 1 gwei/枚：0.01 BNB = 1000 万枚
            maxBuyPerWallet: vm.envOr("PRESALE_MAX_BUY_PER_WALLET", uint256(40_000_000 ether)),
            hardcap: vm.envOr("PRESALE_HARDCAP", uint256(0.08 ether)),
            minLiquidityAmount: vm.envOr("PRESALE_MIN_LIQUIDITY", uint256(0.05 ether)),
            softCap: vm.envOr("PRESALE_SOFT_CAP", uint256(0.05 ether)),
            startTime: 0, // 立即开始
            duration: uint256(vm.envOr("PRESALE_DURATION", uint256(1 hours))), // 合约下限 1h；owner 可随时 endPresale
            vestingDelay: uint256(vm.envOr("PRESALE_VESTING_DELAY", uint256(30 minutes))), // 合约上限 30min：泄漏窗口最大
            vestingRate: uint256(vm.envOr("PRESALE_VESTING_RATE", uint256(20))), // 每期 20%，5 期（2.5h）全释放
            slippage: uint256(0),
            creatorBuyTokens: vm.envOr("PRESALE_CREATOR_BUY_TOKENS", uint256(10_000_000 ether)) // 顶格 5% poolShare
        });
        uint256 creatorBuyFunding = vm.envOr("PRESALE_CREATOR_BUY_FUNDING", uint256(0.0035 ether));

        vm.startBroadcast();
        (address token, address presale, address vault) =
            coordinator.createTokenWithVault{value: creationFee}(config, salt, buyback);
        coordinator.setupPresale{value: creatorBuyFunding}(token, presaleConfig);
        PRESALE(payable(presale)).openPresale();
        vm.stopBroadcast();

        Artifact memory artifact = Artifact({
            token: token,
            presale: presale,
            vault: vault,
            pair: FlapTaxTokenV3(token).mainPool(),
            dividend: FlapTaxTokenV3(token).dividendContract(),
            taxProcessor: FlapTaxTokenV3(token).taxProcessor()
        });
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("dry run: artifact not written");
        } else {
            _writeArtifact(artifact);
        }

        console2.log("token:", token);
        console2.log("presale:", artifact.presale);
        console2.log("vault:", vault);
        console2.log("pair:", artifact.pair);
        console2.log("dividend:", artifact.dividend);
        console2.log("taxProcessor:", artifact.taxProcessor);
        console2.log("presale status (expect 1):", PRESALE(payable(presale)).presaleStatus());
        console2.log("next: retail subscribe() >= softCap, then closeAndLaunch()");
    }

    // -----------------------------------------------------------------------
    // 阶段 2：结束认购 + 开盘 + 首轮卖出（创建者购买库存，若到手）
    // -----------------------------------------------------------------------

    function closeAndLaunch() external {
        _requireTestnet();
        Artifact memory artifact = _readArtifact();
        PRESALE p = PRESALE(payable(artifact.presale));
        require(p.presaleStatus() == 1, "presale not open");
        require(p.accumulatedBNB() >= p.softCap(), "softcap not reached");

        address router = _coordinator().routerAddress();
        uint256 sell1 = vm.envOr("ACCEPTANCE_SELL1_TOKENS", uint256(10_000_000 ether));

        vm.startBroadcast();
        p.endPresale();
        p.launch();
        IERC20(artifact.token).approve(router, type(uint256).max);
        uint256 inventory = IERC20(artifact.token).balanceOf(msg.sender);
        if (inventory >= sell1) {
            _sell(router, artifact.token, sell1, 1);
            console2.log("sell1 executed:", sell1);
        } else {
            console2.log("sell1 skipped, creator inventory:", inventory);
        }
        vm.stopBroadcast();

        console2.log("presale status (expect 3):", p.presaleStatus());
        _logState(artifact);
    }

    // -----------------------------------------------------------------------
    // 阶段 3：归属解锁后领取创建者份额并卖出，推过清算阈值
    // -----------------------------------------------------------------------

    function claimAndSell() external {
        _requireTestnet();
        Artifact memory artifact = _readArtifact();
        PRESALE p = PRESALE(payable(artifact.presale));
        require(p.presaleStatus() == 3, "not launched");

        uint256 vested = p.getVestedAmount(msg.sender);
        console2.log("creator claimable:", vested);
        uint256 sellTokens = vm.envOr("ACCEPTANCE_SELL_TOKENS", uint256(110_000_000 ether));

        vm.startBroadcast();
        if (vested > 0) p.claim();
        uint256 balance = IERC20(artifact.token).balanceOf(msg.sender);
        uint256 toSell = balance < sellTokens ? balance : sellTokens;
        _sell(_coordinator().routerAddress(), artifact.token, toSell, 1);
        vm.stopBroadcast();

        console2.log("sold:", toSell);
        _logState(artifact);
    }

    // -----------------------------------------------------------------------
    // 阶段 4：托管仓分红泄漏复现
    // -----------------------------------------------------------------------

    function proveLeak() external {
        _requireTestnet();
        Artifact memory artifact = _readArtifact();
        DividendLike dividend = DividendLike(artifact.dividend);
        PRESALE p = PRESALE(payable(artifact.presale));

        uint256 escrowWithdrawable = dividend.withdrawableDividends(artifact.presale);
        console2.log("== before ==");
        console2.log("withdrawableDividends(presale):", escrowWithdrawable);
        console2.log("withdrawableDividends(creator):", dividend.withdrawableDividends(msg.sender));
        console2.log("presale BNB balance:", artifact.presale.balance);
        console2.log("creator BNB balance:", msg.sender.balance);

        vm.startBroadcast();
        if (escrowWithdrawable > 0) {
            dividend.withdrawDividendsFor(artifact.presale); // 无权限入口：把托管仓应得分红解包打进托管仓
        }
        if (artifact.presale.balance > 0) {
            p.withdrawRemainingBNB(); // onlyOwner：托管仓全部 BNB 扫给创建者
        }
        vm.stopBroadcast();

        console2.log("== after ==");
        console2.log("withdrawableDividends(presale):", dividend.withdrawableDividends(artifact.presale));
        console2.log("presale BNB balance:", artifact.presale.balance);
        console2.log("creator BNB balance:", msg.sender.balance);
    }

    // -----------------------------------------------------------------------
    // 只读核对
    // -----------------------------------------------------------------------

    function status() external {
        _requireTestnet();
        Artifact memory artifact = _readArtifact();
        PRESALE p = PRESALE(payable(artifact.presale));
        DividendLike dividend = DividendLike(artifact.dividend);
        console2.log("presaleStatus:", p.presaleStatus());
        console2.log("accumulatedBNB:", p.accumulatedBNB());
        console2.log("totalSubscribedTokens:", p.totalSubscribedTokens());
        console2.log("totalClaimed:", p.totalClaimed());
        console2.log("creator claimable:", p.getVestedAmount(msg.sender));
        console2.log("presale escrow token balance:", IERC20(artifact.token).balanceOf(artifact.presale));
        console2.log("dividend totalShares:", dividend.totalShares());
        (uint256 escrowShare,,) = dividend.userInfo(artifact.presale);
        console2.log("escrow share:", escrowShare);
        console2.log("withdrawableDividends(presale):", dividend.withdrawableDividends(artifact.presale));
        console2.log("presale BNB balance:", artifact.presale.balance);
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

    function _logState(Artifact memory artifact) internal view {
        (uint8 state, uint16 buyTax, uint16 sellTax,, uint96 threshold,,) = FlapTaxTokenV3(artifact.token).poolState();
        (uint112 reserve0, uint112 reserve1,) = IPancakePair(artifact.pair).getReserves();
        console2.log("poolState:", state);
        console2.log("buyTax bps:", buyTax);
        console2.log("sellTax bps:", sellTax);
        console2.log("liquidationThreshold:", uint256(threshold));
        console2.log("pair reserve0:", uint256(reserve0));
        console2.log("pair reserve1:", uint256(reserve1));
        console2.log("token contract tax balance:", IERC20(artifact.token).balanceOf(artifact.token));
        PendingTaxLike processor = PendingTaxLike(artifact.taxProcessor);
        console2.log("pendingTaxTokens:", processor.pendingTaxTokens());
        console2.log("totalDividendTokenSent:", processor.totalDividendTokenSent());
    }

    function _logVault(Artifact memory artifact) internal view {
        VaultStats memory stats = BuybackVault(payable(artifact.vault)).getVaultStats();
        console2.log("vault balance:", artifact.vault.balance);
        console2.log("vault readiness:", uint8(stats.readiness));
        console2.log("vault buybackCount:", stats.buybackCount);
        console2.log("vault totalBurnedToken:", stats.totalBurnedToken);
    }

    function _requireTestnet() internal view {
        require(block.chainid == BSC_TESTNET_CHAIN_ID, "presale acceptance is BSC testnet only");
    }

    function _coordinator() internal view returns (CoordinatorFactory) {
        address configured = vm.envOr("COORDINATOR_ADDRESS", address(0));
        if (configured != address(0)) return CoordinatorFactory(configured);
        string memory path = string.concat("script/deployments/", vm.toString(block.chainid), ".json");
        require(vm.exists(path), "deployment file missing; set COORDINATOR_ADDRESS");
        return CoordinatorFactory(vm.parseJsonAddress(vm.readFile(path), ".coordinatorFactory"));
    }

    function _saltTag() internal view returns (string memory) {
        return vm.envOr("ACCEPTANCE_SALT_TAG", string.concat("presale-acceptance-", vm.toString(block.chainid)));
    }

    function _vanitySalt(address tokenFactory, string memory tag) internal view returns (bytes32 salt) {
        bool found;
        (salt, found) = VanitySaltFinder.find(
            tokenFactory, TokenFactoryLike(tokenFactory).flapImplementation(), uint256(keccak256(bytes(tag)))
        );
        require(found, "vanity salt not found within budget");
    }

    function _artifactPath() internal view returns (string memory) {
        return string.concat("script/deployments/", vm.toString(block.chainid), "-presale-acceptance.json");
    }

    function _writeArtifact(Artifact memory artifact) internal {
        string memory key = "acceptance";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "token", artifact.token);
        vm.serializeAddress(key, "presale", artifact.presale);
        vm.serializeAddress(key, "vault", artifact.vault);
        vm.serializeAddress(key, "pair", artifact.pair);
        vm.serializeAddress(key, "dividend", artifact.dividend);
        string memory json = vm.serializeAddress(key, "taxProcessor", artifact.taxProcessor);
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
        artifact.dividend = vm.parseJsonAddress(json, ".dividend");
        artifact.taxProcessor = vm.parseJsonAddress(json, ".taxProcessor");
    }
}

interface TokenFactoryLike {
    function flapImplementation() external view returns (address);
}

interface PendingTaxLike {
    function pendingTaxTokens() external view returns (uint256);
    function totalDividendTokenSent() external view returns (uint256);
}

interface DividendLike {
    function withdrawableDividends(address user) external view returns (uint256);
    function withdrawDividendsFor(address user) external returns (bool);
    function totalShares() external view returns (uint256);
    function userInfo(address user) external view returns (uint256 share, uint256 rewardDebt, uint256 pendingBalance);
}
