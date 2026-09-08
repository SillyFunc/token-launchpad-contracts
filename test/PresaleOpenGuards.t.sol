// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {
    PRESALE,
    InvalidMaxPresaleTokens,
    SoftCapExceedsHardcap,
    InvalidPrice,
    InvalidDuration,
    AlreadyInitialized,
    InvalidMaxBuyPerWallet,
    ConfiguratorAlreadySet,
    ZeroAllocationShare
} from "src/Presale.sol";

contract MockRouter {
    address public weth;

    function WETH() external view returns (address) {
        return weth;
    }
}

contract DummyTaxProcessor {}

/// @title openPresale 终检补强 + 实现合约初始化锁 回归测试
/// @dev 覆盖面（对应 review 发现 M1/L1/L2/L3 的修复）：
///      1) M1 认购上限闸：maxPresaleTokens > presaleShare（超募→claim 缺口）与 0（死配置）拒开；
///         恰等 presaleShare 的边界放行（Coordinator 恒等写入路径不受影响）
///      2) L1 倒置闸：setSoftCap(hardcap=0) 先于 setPresaleTerms(小 hardcap) 的乱序配置
///         令 softCap > hardcap → 拒开；修复配置后可开；hardcap=0（不限）边界不做倒置校验
///      3) L2 条款完整性闸：条款未设置（price=0）拒开；duration=0（白盒注入）拒开
///      4) L3 实现锁：工厂构造即初始化模板本体，模板再 initialize 必 revert；
///         克隆实例不受模板锁定影响（重复创建两个克隆均正常初始化）
///      5) 多轮场景：第 1 轮失败 → relaunch 回配置期 → 第 2 轮终检依然生效，
///         修复配置后正常开盘认购（重复调用/跨轮一致性）
contract PresaleOpenGuardsTest is Test {
    using stdStorage for StdStorage;

    uint256 constant SUPPLY = 1e9 ether;

    MockRouter router;
    FlapTaxTokenV3 token;
    PRESALE presale;
    address pair = address(0x1111);
    address alice = address(0xA11CE);
    uint256 creatorShare = SUPPLY * 30 / 100;
    uint256 poolShare = SUPPLY * 20 / 100;
    uint256 presaleShare = SUPPLY * 50 / 100;

    uint256 constant PRICE = 1e15; // 0.001 BNB/token
    uint256 constant DURATION = 30 days;

    uint256 private _cloneNonce;

    event PresaleCreated(address indexed presale, address indexed creator);

    function setUp() public {
        router = new MockRouter();
        vm.deal(address(this), 1000 ether);
        vm.deal(alice, 1000 ether);
        token = _freshToken();

        presale = new PRESALE();
        presale.initialize(address(this), address(router));
        _configureValid();

        presale.setCoinAndPair(address(token), pair);
        token.transfer(address(presale), SUPPLY);
        token.transferOwnership(address(presale));
    }

    /// @dev 合法基线配置（各用例在此基础上做单项破坏）
    function _configureValid() internal {
        presale.configureLaunch(true, address(this), creatorShare, poolShare, presaleShare);
        presale.setPresaleTerms(PRICE, presaleShare, 1e8 ether, 0, 0.1 ether, 0, DURATION);
        presale.setVestingConfig(7 days, 10);
        presale.setSoftCap(0.1 ether);
    }

    // ---------------------------------------------------------------------------
    // 0) 基线：合法配置正常开盘
    // ---------------------------------------------------------------------------

    function test_OpensWithValidConfig() public {
        presale.openPresale();
        assertEq(presale.presaleStatus(), 1);
        assertEq(presale.endTime(), block.timestamp + DURATION);
    }

    // ---------------------------------------------------------------------------
    // 1) M1：认购上限闸
    // ---------------------------------------------------------------------------

    function test_RevertWhen_OpenWithMaxTokensExceedingShare() public {
        presale.setPresaleTerms(PRICE, presaleShare + 1, 1e8 ether, 0, 0.1 ether, 0, DURATION);
        vm.expectRevert(InvalidMaxPresaleTokens.selector);
        presale.openPresale();
    }

    /// @dev 边界：恰等预售份额放行（Coordinator 路径恒等写入，必须不受误伤）
    function test_MaxTokensEqualShareOpens() public {
        presale.setPresaleTerms(PRICE, presaleShare, 1e8 ether, 0, 0.1 ether, 0, DURATION);
        presale.openPresale();
        assertEq(presale.presaleStatus(), 1);
    }

    function test_RevertWhen_OpenWithZeroMaxTokens() public {
        presale.setPresaleTerms(PRICE, 0, 1e8 ether, 0, 0.1 ether, 0, DURATION);
        vm.expectRevert(InvalidMaxPresaleTokens.selector);
        presale.openPresale();
    }

    function test_RevertWhen_SetTermsWithZeroWalletLimit() public {
        vm.expectRevert(InvalidMaxBuyPerWallet.selector);
        presale.setPresaleTerms(PRICE, presaleShare, 0, 0, 0.1 ether, 0, DURATION);
    }

    /// @dev 修复链路：错误配置被拒后改正即可开盘，状态无残留
    function test_MaxTokensFixThenOpen() public {
        presale.setPresaleTerms(PRICE, presaleShare + 1, 1e8 ether, 0, 0.1 ether, 0, DURATION);
        vm.expectRevert(InvalidMaxPresaleTokens.selector);
        presale.openPresale();
        assertEq(presale.presaleStatus(), 0); // 拒绝不消耗状态

        presale.setPresaleTerms(PRICE, presaleShare, 1e8 ether, 0, 0.1 ether, 0, DURATION);
        presale.openPresale();
        assertEq(presale.presaleStatus(), 1);
    }

    // ---------------------------------------------------------------------------
    // 2) L1：softCap/hardcap 倒置闸
    // ---------------------------------------------------------------------------

    /// @dev 乱序攻击面复现：hardcap=0 时 setSoftCap 不查上限 → 再写入更小 hardcap → 倒置成立
    function test_RevertWhen_OpenWithInvertedSoftCapHardcap() public {
        presale.setSoftCap(1 ether); // hardcap=0（不限），校验通过
        presale.setPresaleTerms(PRICE, presaleShare, 1e8 ether, 0.5 ether, 0.1 ether, 0, DURATION); // 写入 hardcap 不复查 softCap
        assertGt(presale.softCap(), presale.hardcap()); // 倒置成立（1 > 0.5）

        vm.expectRevert(SoftCapExceedsHardcap.selector);
        presale.openPresale();
    }

    /// @dev 边界：softCap == hardcap 允许（恰达硬顶同笔结算即可达标）
    function test_SoftCapEqualHardcapOpens() public {
        presale.setPresaleTerms(PRICE, presaleShare, 1e8 ether, 0.5 ether, 0.1 ether, 0, DURATION);
        presale.setSoftCap(0.5 ether);
        presale.openPresale();
        assertEq(presale.presaleStatus(), 1);
    }

    /// @dev 边界：hardcap=0（不限）无倒置概念，任意合法 softCap 可开
    function test_HardcapZeroSkipsInversionCheck() public {
        presale.setSoftCap(1000 ether);
        presale.openPresale();
        assertEq(presale.presaleStatus(), 1);
    }

    /// @dev 修复链路：倒置被拒后调低 softCap 即可开盘
    function test_InversionFixThenOpen() public {
        presale.setSoftCap(1 ether);
        presale.setPresaleTerms(PRICE, presaleShare, 1e8 ether, 0.5 ether, 0.1 ether, 0, DURATION);
        vm.expectRevert(SoftCapExceedsHardcap.selector);
        presale.openPresale();

        presale.setSoftCap(0.4 ether); // ≥ minLiquidity 且 ≤ hardcap
        presale.openPresale();
        assertEq(presale.presaleStatus(), 1);
    }

    // ---------------------------------------------------------------------------
    // 3) L2：条款完整性闸
    // ---------------------------------------------------------------------------

    /// @dev 只 configureLaunch、从不 setPresaleTerms：price/duration 双 0 → 首个拦截为 InvalidPrice
    function test_RevertWhen_OpenWithTermsNeverSet() public {
        PRESALE p = new PRESALE();
        p.initialize(address(this), address(router));
        p.configureLaunch(true, address(this), creatorShare, poolShare, presaleShare);
        vm.expectRevert(InvalidPrice.selector);
        p.openPresale();
    }

    function test_RevertWhen_AllocationContainsZeroShare() public {
        PRESALE p = new PRESALE();
        p.initialize(address(this), address(router));

        vm.expectRevert(ZeroAllocationShare.selector);
        p.configureLaunch(true, address(this), creatorShare, 0, presaleShare + poolShare);
    }

    /// @dev 白盒注入 duration=0（公开 setter 恒 ≥ 1 分钟，构造唯一残留路径）：拒开
    function test_RevertWhen_OpenWithZeroDuration() public {
        stdstore.target(address(presale)).sig(presale.presaleDuration.selector).checked_write(uint256(0));
        assertEq(presale.presaleDuration(), 0);

        vm.expectRevert(InvalidDuration.selector);
        presale.openPresale();
    }

    // ---------------------------------------------------------------------------
    // 4) L3：实现合约初始化锁
    // ---------------------------------------------------------------------------

    function test_ImplementationLockedByFactory() public {
        PRESALE template = new PRESALE();
        new PresaleFactory(address(template), address(this)); // 构造即锁模板

        assertEq(template.owner(), address(1)); // 占位初始化已生效
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(AlreadyInitialized.selector);
        template.initialize(attacker, address(router));
    }

    /// @dev 重复调用：两个克隆互不影响且均正常初始化；模板锁状态不被克隆消耗
    function test_ClonesUnaffectedByLockedTemplate() public {
        PRESALE template = new PRESALE();
        PresaleFactory factory = new PresaleFactory(address(template), address(this));

        address clone1 = factory.createPresale(address(router), address(this));
        address clone2 = factory.createPresale(address(router), address(this));
        assertTrue(clone1 != clone2);

        // 克隆已初始化（owner = 调用方，工厂末尾移交），再初始化必拒
        assertEq(PRESALE(payable(clone1)).owner(), address(this));
        assertEq(PRESALE(payable(clone2)).owner(), address(this));
        assertEq(PRESALE(payable(clone1)).configurator(), address(this));
        vm.expectRevert(ConfiguratorAlreadySet.selector);
        PRESALE(payable(clone1)).setConfigurator(address(0xBEEF));
        vm.expectRevert(AlreadyInitialized.selector);
        PRESALE(payable(clone1)).initialize(address(this), address(router));

        // 模板锁依旧有效
        vm.expectRevert(AlreadyInitialized.selector);
        template.initialize(address(this), address(router));
    }

    function test_PresaleCreatedEventUsesActualCreator() public {
        PRESALE template = new PRESALE();
        PresaleFactory factory = new PresaleFactory(address(template), address(this));
        address creator = address(0xC1);

        vm.expectEmit(false, true, false, false, address(factory));
        emit PresaleCreated(address(0), creator);
        factory.createPresale(address(router), creator);
    }

    // ---------------------------------------------------------------------------
    // 5) 多轮场景：终检跨轮一致
    // ---------------------------------------------------------------------------

    function test_GuardsApplyAfterRelaunch() public {
        // 第 1 轮：未达 softCap 失败 → 退款 → 重开回配置期
        presale.openPresale();
        vm.prank(alice);
        presale.subscribe{value: 0.05 ether}(); // < softCap 0.1
        vm.warp(presale.endTime() + 1);
        presale.endPresale();
        assertEq(presale.presaleStatus(), 4);
        vm.prank(alice);
        presale.refund();
        presale.relaunchPresale();
        assertEq(presale.presaleStatus(), 0);

        // 第 2 轮：乱序造倒置 → 终检依然拦截
        presale.setSoftCap(1 ether);
        presale.setPresaleTerms(PRICE, presaleShare, 1e8 ether, 0.5 ether, 0.1 ether, 0, DURATION);
        vm.expectRevert(SoftCapExceedsHardcap.selector);
        presale.openPresale();

        // 修复后正常开盘、认购
        presale.setSoftCap(0.1 ether);
        presale.openPresale();
        assertEq(presale.presaleStatus(), 1);
        vm.prank(alice);
        presale.subscribe{value: 0.05 ether}();
        assertEq(presale.accumulatedBNB(), 0.05 ether);
    }

    // ---------------------------------------------------------------------------
    // 夹具
    // ---------------------------------------------------------------------------

    /// @dev 每用例独立新代币（与 PresaleDuration.t.sol 同款夹具）
    function _freshToken() internal returns (FlapTaxTokenV3) {
        FlapTaxTokenV3 impl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        FlapTaxTokenV3 t = FlapTaxTokenV3(payable(_clone(address(impl))));

        address[] memory pools = new address[](1);
        pools[0] = pair;

        t.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "TestToken",
                symbol: "TT",
                meta: "",
                buyTax: 300,
                sellTax: 500,
                taxProcessor: address(new DummyTaxProcessor()),
                dividendContract: address(0),
                quoteToken: address(router.weth()),
                liqExpectedOutputAmount: 0,
                taxDuration: 7 days,
                pools: pools,
                v2Router: address(router),
                antiFarmerDuration: 1 days
            })
        );
        return t;
    }

    function _clone(address implementation) internal returns (address instance) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, address(this), ++_cloneNonce));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }
}
