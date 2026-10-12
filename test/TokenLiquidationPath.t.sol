// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "src/Clones.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";

/// @dev 可编程的 TaxProcessor 桩。隔离代币侧的清算状态机:记录收到的数量,
///      按配置返回方向,或直接 revert 以触发代币的 try/catch 兜底。
///      真实 TaxProcessor 的兑换与分配由其他测试覆盖。
contract ScriptedTaxProcessor {
    FlapTaxTokenV3 public immutable token;
    int8 public nextDirection;
    bool public shouldRevert;
    uint256 public calls;
    uint256 public lastAmount;

    constructor(FlapTaxTokenV3 token_) {
        token = token_;
    }

    function setNextDirection(int8 d) external {
        nextDirection = d;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function processTaxTokens(uint256 amount) external returns (int8) {
        require(msg.sender == address(token), "only token");
        if (shouldRevert) revert("processor down");
        require(IERC20(address(token)).transferFrom(msg.sender, address(this), amount), "pull failed");
        calls++;
        lastAmount = amount;
        return nextDirection;
    }
}

/// @dev 探针 processor:在被调用的瞬间记录代币侧 notLiquidating 是否为 false。
///      代币在 initialize 时写入 processor 地址,因此探针需要自己的代币实例。
contract LiquidationProbe {
    FlapTaxTokenV3 public token;
    bool public sawLiquidating;
    uint256 public calls;

    function setToken(FlapTaxTokenV3 t) external {
        token = t;
    }

    function processTaxTokens(uint256 amount) external returns (int8) {
        require(msg.sender == address(token), "only token");
        calls++;
        (,,, bool notLiquidating,,,) = token.poolState();
        if (!notLiquidating) sawLiquidating = true;
        require(IERC20(address(token)).transferFrom(msg.sender, address(this), amount), "pull failed");
        return 0;
    }
}

contract TokenLiquidationPathTest is Test {
    uint256 internal constant MIN_THRESHOLD = 50_000 ether;
    uint256 internal constant START_THRESHOLD = 400_000 ether;
    uint256 internal constant TAX_DURATION = 365 days;
    uint256 internal constant ANTI_FARMER = 1 days;

    address internal constant POOL = address(0xCAFE);

    FlapTaxTokenV3 internal implementation;
    FlapTaxTokenV3 internal token;
    ScriptedTaxProcessor internal processor;

    function setUp() public {
        implementation = new FlapTaxTokenV3(MIN_THRESHOLD, START_THRESHOLD);
        // processor 需要代币地址,代币初始化又需要 processor 地址。
        // 先部署 processor 并绑定到代币,代币地址在克隆时即确定,因此顺序为:
        // 克隆代币 -> 部署 processor(绑定该代币) -> 初始化代币。
        token = FlapTaxTokenV3(Clones.clone(address(implementation)));
        processor = new ScriptedTaxProcessor(token);
        _initialize(token, address(processor));
    }

    /// @dev 克隆并初始化一套新代币。processor 必须已绑定到该代币的地址才能工作,
    ///      因此探针测试需要自行先克隆、再部署探针、再调用 _initialize。
    function _deployToken(address taxProcessor) internal returns (FlapTaxTokenV3 t) {
        t = FlapTaxTokenV3(Clones.clone(address(implementation)));
        _initialize(t, taxProcessor);
    }

    /// @dev 按与 Coordinator 相同的方式初始化代币并进入税期(TaxEnforcedAntiFarmer)。
    function _initialize(FlapTaxTokenV3 t, address taxProcessor) internal {
        address[] memory pools = new address[](1);
        pools[0] = POOL;
        t.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "Liq Path",
                symbol: "LIQ",
                meta: "",
                buyTax: 1000,
                sellTax: 1000,
                taxProcessor: taxProcessor,
                dividendContract: address(0),
                quoteToken: address(0xBEEF),
                liqExpectedOutputAmount: 0,
                taxDuration: TAX_DURATION,
                pools: pools,
                v2Router: address(0),
                antiFarmerDuration: ANTI_FARMER
            })
        );
        t.startMigration();
        t.finalizeMigration();
    }

    /// @dev 读取 poolState 的 notLiquidating 字段(位于元组第 4 位,对应 PackedPoolState 的声明顺序)。
    function _notLiquidating() internal view returns (bool nl) {
        (,,, nl,,,) = token.poolState();
    }

    /// @dev 卖税 10%:向池子转账 amount 会在代币合约累积 amount/10 的税。
    function _sellToPool(uint256 amount) internal {
        token.transfer(POOL, amount);
    }

    /// @dev 使代币合约累积税达到 taxAmount。
    function _accrueTax(uint256 taxAmount) internal {
        _sellToPool(taxAmount * 10);
    }

    // -----------------------------------------------------------------------
    // 1. 阈值与基本清算
    // -----------------------------------------------------------------------

    function test_BelowThreshold_NoLiquidation() public {
        _accrueTax(START_THRESHOLD - 1 ether);
        // 额外的转账仍低于阈值时不得清算。
        _sellToPool(1 ether);
        assertEq(processor.calls(), 0);
    }

    function test_ReachesThreshold_LiquidatesOnNextPoolTransfer() public {
        _accrueTax(START_THRESHOLD);
        assertEq(processor.calls(), 0, "accrual alone does not liquidate");
        _sellToPool(10 ether);
        assertEq(processor.calls(), 1);
        assertEq(processor.lastAmount(), START_THRESHOLD);
    }

    // -----------------------------------------------------------------------
    // 2. try/catch 兜底
    // -----------------------------------------------------------------------

    function test_ProcessorRevert_EmitsErrorAndSweepsTaxToProcessor() public {
        processor.setShouldRevert(true);
        _accrueTax(START_THRESHOLD);

        vm.expectEmit(false, false, false, false, address(token));
        emit IFlapTaxTokenV3.TaxLiquidationError(bytes(""));
        _sellToPool(10 ether);

        // 清算在本次转账的税计算之前执行(_transfer 先 _liquidateTax 再算税),因此合约中
        // 只剩触发这笔转账自身产生的 1 ether 税(10 ether 的 10%),其余累积税已被扫给 processor。
        assertEq(token.balanceOf(address(token)), 1 ether, "only the triggering transfer's own tax remains");
        assertEq(token.balanceOf(address(processor)), START_THRESHOLD, "accrued tax swept to processor");
        assertEq(processor.calls(), 0, "failed call must not be recorded");
    }

    function test_ProcessorRevert_RestoresLiquidationFlag() public {
        processor.setShouldRevert(true);
        _accrueTax(START_THRESHOLD);
        _sellToPool(10 ether);

        // 若 catch 之后未恢复 notLiquidating,后续转账会永久卡在清算中。
        assertTrue(_notLiquidating(), "flag must be restored after catch");
    }

    function test_ProcessorRevert_LaterTransfersStillWork() public {
        processor.setShouldRevert(true);
        _accrueTax(START_THRESHOLD);
        _sellToPool(10 ether);

        processor.setShouldRevert(false);
        uint256 before = token.balanceOf(POOL);
        _sellToPool(10 ether);
        assertEq(token.balanceOf(POOL) - before, 9 ether, "transfer still taxed normally after catch");
    }

    // -----------------------------------------------------------------------
    // 3. 方向棘轮:每次 ±1%,并被 MIN / initial 钳位
    // -----------------------------------------------------------------------

    function test_Direction_Negative_DecreasesThresholdByOnePercent() public {
        processor.setNextDirection(-1);
        _accrueTax(START_THRESHOLD);
        _sellToPool(10 ether);
        assertEq(token.liquidationThreshold(), (START_THRESHOLD * 99) / 100);
    }

    function test_Direction_Positive_AtInitial_StaysClamped() public {
        processor.setNextDirection(1);
        _accrueTax(START_THRESHOLD);
        _sellToPool(10 ether);
        assertEq(token.liquidationThreshold(), START_THRESHOLD, "cannot exceed initialLiquidationThreshold");
    }

    function test_Direction_Negative_ClampsAtMinimum() public {
        processor.setNextDirection(-1);
        uint256 guard;
        while (token.liquidationThreshold() > MIN_THRESHOLD && guard++ < 1000) {
            _accrueTax(token.liquidationThreshold());
            _sellToPool(1 ether);
        }
        assertEq(token.liquidationThreshold(), MIN_THRESHOLD, "must clamp at MIN_LIQ_THRESHOLD");

        _accrueTax(MIN_THRESHOLD);
        _sellToPool(1 ether);
        assertEq(token.liquidationThreshold(), MIN_THRESHOLD, "stays at MIN under further negatives");
    }

    function test_Direction_Recovery_ClampsAtInitial() public {
        processor.setNextDirection(-1);
        _accrueTax(START_THRESHOLD);
        _sellToPool(1 ether);
        assertLt(token.liquidationThreshold(), START_THRESHOLD);

        processor.setNextDirection(1);
        uint256 guard;
        while (token.liquidationThreshold() < START_THRESHOLD && guard++ < 1000) {
            _accrueTax(token.liquidationThreshold());
            _sellToPool(1 ether);
        }
        assertEq(token.liquidationThreshold(), START_THRESHOLD, "must clamp at initialLiquidationThreshold");
    }

    function test_DirectionZero_LeavesThresholdUnchanged() public {
        processor.setNextDirection(0);
        _accrueTax(START_THRESHOLD);
        _sellToPool(1 ether);
        assertEq(token.liquidationThreshold(), START_THRESHOLD);
    }

    // -----------------------------------------------------------------------
    // 4. 状态跃迁
    // -----------------------------------------------------------------------

    function test_AntiFarmerExpiry_TransitionsToTaxEnforced() public {
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));

        vm.warp(block.timestamp + ANTI_FARMER + 1);
        // 跃迁在指向池子的转账中触发。
        _sellToPool(1 ether);
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforced));
    }

    function test_TaxExpiry_TransitionsToTaxFree_AndZeroesRates() public {
        vm.warp(block.timestamp + TAX_DURATION + 1);
        _sellToPool(1 ether);
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxFree));
        assertEq(token.buyTaxRate(), 0);
        assertEq(token.sellTaxRate(), 0);
    }

    function test_TaxFree_TransfersAreUntaxed() public {
        vm.warp(block.timestamp + TAX_DURATION + 1);
        _sellToPool(1 ether);
        uint256 before = token.balanceOf(POOL);
        _sellToPool(100 ether);
        assertEq(token.balanceOf(POOL) - before, 100 ether, "no tax once TaxFree");
    }

    function test_TaxFree_FlushesResidualTaxBelowThreshold() public {
        _accrueTax(START_THRESHOLD / 2);
        assertEq(processor.calls(), 0, "below threshold while taxed");
        vm.warp(block.timestamp + TAX_DURATION + 1);
        _sellToPool(1 ether);
        assertEq(processor.calls(), 1, "TaxFree liquidates any residual tax");
    }

    // -----------------------------------------------------------------------
    // 5. 重入旗标
    // -----------------------------------------------------------------------

    function test_NotLiquidating_TrueAfterSuccessfulLiquidation() public {
        _accrueTax(START_THRESHOLD);
        _sellToPool(1 ether);
        assertTrue(_notLiquidating());
    }

    function test_NotLiquidating_FalseWhileProcessorRuns() public {
        LiquidationProbe probe = new LiquidationProbe();
        FlapTaxTokenV3 t2 = _deployToken(address(probe));
        probe.setToken(t2);

        t2.transfer(POOL, START_THRESHOLD * 10);
        t2.transfer(POOL, 1 ether);

        assertTrue(probe.calls() > 0, "probe must be invoked");
        assertTrue(probe.sawLiquidating(), "processor must observe notLiquidating == false");
    }
}
