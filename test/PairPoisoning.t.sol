// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {PRESALE, EscrowDrained} from "src/Presale.sol";

interface IERC20Lite {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev 极简 WBNB：仅覆盖 PoC 所需（deposit 包装 / transfer / balanceOf）
contract MockWBNB {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }
}

/// @dev 忠实复刻 PancakeV2Pair 的储备语义子集：sync() 将储备刷新为实际余额
///      （投毒攻击的关键入口——任何人可捐入 WBNB 后强制同步储备）。
///      token0 经 setToken 两段式注入：pair 需先于 token 存在（token 初始化要登记
///      pools[]），而 pair 构造又需 token 地址——测试夹具用一次性 setter 破环
contract MockV2Pair {
    address public token0; // FlapTaxTokenV3（两段式注入）
    address public immutable token1; // WBNB
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address _wbnb) {
        token1 = _wbnb;
    }

    function setToken(address _token) external {
        require(token0 == address(0), "mock: token already set");
        token0 = _token;
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    /// @notice 与 PancakeV2Pair.sync() 同义：reserves := 实际持仓（无权限限制）
    function sync() external {
        reserve0 = uint112(IERC20Lite(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Lite(token1).balanceOf(address(this)));
    }
}

/// @dev 忠实复刻 PancakeRouter02._addLiquidity 的报价数学（命中本 PoC 的分支）：
///      储备 (0,0) 走 (desired, msg.value)；否则按储备比求最优侧。
///      被投毒储备 (token=0, bnb>0) 时 amountTokenDesired * bnbReserve / 0
///      → Panic(0x12)（除零），launch() 整笔回滚。
///      简化项（不影响本 PoC 结论）：LP 凭证恒返回 1e18 不实际铸造；
///      储备数学、INSUFFICIENT_* 检查、找零退款与真实路由一致。
contract MockV2Router {
    MockV2Pair public immutable pair;
    MockWBNB public immutable wbnb;

    constructor(MockV2Pair _pair, MockWBNB _wbnb) {
        pair = _pair;
        wbnb = _wbnb;
    }

    function WETH() external view returns (address) {
        return address(wbnb);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address,
        uint256
    ) external payable returns (uint256 amountToken, uint256 amountBNB, uint256 liquidity) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 tokenReserve, uint256 bnbReserve) =
            token == pair.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // --- PancakeRouter._addLiquidity 报价分支（逐行同义复刻） ---
        if (tokenReserve == 0 && bnbReserve == 0) {
            (amountToken, amountBNB) = (amountTokenDesired, msg.value);
        } else {
            // 投毒形态 (tokenReserve=0, bnbReserve>0)：除零 Panic(0x12)
            uint256 bnbOptimal = (amountTokenDesired * bnbReserve) / tokenReserve;
            if (bnbOptimal <= msg.value) {
                (amountToken, amountBNB) = (amountTokenDesired, bnbOptimal);
            } else {
                uint256 tokenOptimal = (msg.value * tokenReserve) / bnbReserve;
                (amountToken, amountBNB) = (tokenOptimal, msg.value);
            }
        }
        require(amountToken >= amountTokenMin, "PancakeRouter: INSUFFICIENT_TOKEN_AMOUNT");
        require(amountBNB >= amountBNBMin, "PancakeRouter: INSUFFICIENT_BNB_AMOUNT");

        IERC20Lite(token).transferFrom(msg.sender, address(pair), amountToken);
        wbnb.deposit{value: msg.value}();
        wbnb.transfer(address(pair), amountBNB);
        pair.sync();

        if (msg.value > amountBNB) {
            (bool ok,) = msg.sender.call{value: msg.value - amountBNB}("");
            require(ok, "mock: refund failed");
        }
        liquidity = 1e18;
    }
}

contract DummyTaxProcessor {}

/// @title Pair 预投毒 griefing PoC：launch DoS 是可退出的，不是资金锁死
/// @dev 攻击面（V2 launchpad 通用类风险，非本分支引入）：
///      createToken 即 createPair（储备 (0,0)）。任何人可向 pair 直捐 WBNB + sync()，
///      令储备变为 (token=0, bnb>0)；此后 launch() 的 addLiquidityETH 在报价分支除零
///      Panic(0x12) 恒 revert。攻击者需真实付出捐出的 WBNB（无资金被窃，纯 griefing）。
///
///      本文件固化的是安全属性（而非待修 bug）：
///      1) DoS 持续性：投毒后任意时刻 launch 均 revert，无自愈；
///      2) 状态机封闭性：状态 2 卡 72h 后任何人 enforceLaunchDeadline 翻 FAILED，
///         散户 refund 精确全额退出，创建者 reclaimTokens 全量回收代币（内嵌迁移+renounce）；
///      3) 双出口互斥：回收后 relaunchPresale 被 EscrowDrained 封死；
///      4) 对照组：健康 pair 下同一 mock 路由 launch 成功——证明 revert 归因于投毒而非 mock 缺陷。
contract PairPoisoningTest is Test {
    uint256 constant SUPPLY = 1e9 ether;
    uint256 constant POISON = 0.5 ether;

    // Panic(0x12)（除零）的编码：selector("Panic(uint256)") ++ abi.encode(0x12)
    bytes constant DIV_BY_ZERO = bytes.concat(hex"4e487b71", bytes32(uint256(0x12)));

    MockWBNB wbnb;
    MockV2Pair pair;
    MockV2Router router;
    FlapTaxTokenV3 token;
    PRESALE presale;

    address alice = address(0xA11CE); // 散户
    address bob = address(0xB0B); // 攻击者
    uint256 creatorShare = (SUPPLY * 30) / 100;
    uint256 poolShare = (SUPPLY * 20) / 100;
    uint256 presaleShare = (SUPPLY * 50) / 100;

    function setUp() public {
        vm.deal(address(this), 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        // 部署顺序：wbnb → pair（token0 待注入）→ router → token（登记 pair）→ 注入 token0
        wbnb = new MockWBNB();
        pair = new MockV2Pair(address(wbnb));
        router = new MockV2Router(pair, wbnb);
        token = _freshToken();
        pair.setToken(address(token));

        presale = new PRESALE();
        presale.initialize(address(this), address(router));
        presale.configureLaunch(true, address(this), creatorShare, poolShare, presaleShare);
        // softCap == minLiquidity == 0.1 BNB；hardcap 0（不限）
        presale.setPresaleTerms(1e15, presaleShare, 1e8 ether, 0, 0.1 ether, 0, 1 days);
        presale.setVestingConfig(7 days, 10);
        presale.setSoftCap(0.1 ether);
        presale.setCoinAndPair(address(token), address(pair));

        // 模拟 Coordinator：全量代币入仓 + token 所有权移交
        token.transfer(address(presale), SUPPLY);
        token.transferOwnership(address(presale));

        // 推进到状态 2（开认购 → 达 softCap → endPresale）
        presale.openPresale();
        vm.prank(alice);
        presale.subscribe{value: 0.1 ether}();
        presale.endPresale();
        assertEq(presale.presaleStatus(), 2, "fixture: awaiting launch");
    }

    // ---------------------------------------------------------------------------
    // 攻击：直捐 WBNB + sync 投毒储备
    // ---------------------------------------------------------------------------

    function _poisonPair() internal {
        vm.startPrank(bob);
        wbnb.deposit{value: POISON}();
        wbnb.transfer(address(pair), POISON);
        pair.sync();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // 0) 对照组：健康 pair 下 launch 成功（证明 mock 路由数学正确）
    // ---------------------------------------------------------------------------

    function test_HealthyPair_LaunchSucceeds_Control() public {
        presale.launch();

        assertEq(presale.presaleStatus(), 3, "launched");
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0), poolShare, "token reserve = pool share");
        assertEq(uint256(r1), 0.1 ether, "bnb reserve = full raise");
        assertTrue(presale.liquidityAdded());
    }

    // ---------------------------------------------------------------------------
    // 1) 投毒：launch 恒 revert（Panic 0x12），无自愈，状态与代币态不变
    // ---------------------------------------------------------------------------

    function test_PoisonedPair_BlocksLaunch_Persistently() public {
        _poisonPair();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0), 0, "poisoned: token reserve = 0");
        assertEq(uint256(r1), POISON, "poisoned: bnb reserve = donated");

        vm.expectRevert(DIV_BY_ZERO);
        presale.launch();

        // 无自愈：任意等待后依旧（本次 revert 未改变任何状态）
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(DIV_BY_ZERO);
        presale.launch();

        assertEq(presale.presaleStatus(), 2, "status untouched by failed launch");
        assertEq(presale.accumulatedBNB(), 0.1 ether, "raise intact");
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.BondingCurve), "migration rolled back");
    }

    // ---------------------------------------------------------------------------
    // 2) 救援闭环：72h 兜底 → 散户全额退款 → 创建者全量回收 → relaunch 封死
    // ---------------------------------------------------------------------------

    function test_PoisonedPair_72hDeadlineRescue_FullExit() public {
        _poisonPair();

        // 状态 2 卡满 72h：任何人（这里让攻击者本人执行，证明无需许可）翻 FAILED
        vm.warp(presale.endedAt() + presale.LAUNCH_DEADLINE() + 1);
        vm.prank(bob);
        presale.enforceLaunchDeadline();
        assertEq(presale.presaleStatus(), presale.STATUS_FAILED());

        // 散户精确全额退款（缴款账本口径，非合约余额）
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        presale.refund();
        assertEq(alice.balance, aliceBefore + 0.1 ether, "contributor made whole");
        assertEq(presale.subscribedTokens(alice), 0, "share voided");
        assertEq(presale.accumulatedBNB(), 0, "all refunded");

        // 创建者全量回收代币：同笔内嵌迁移 + renounce，结局即纯发币
        presale.reclaimTokens();
        assertEq(token.balanceOf(address(this)), SUPPLY, "creator made whole");
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer), "migrated");
        assertEq(token.owner(), address(0), "ownership renounced");

        // 双出口互斥：仓空后重开被封死
        vm.expectRevert(EscrowDrained.selector);
        presale.relaunchPresale();
    }

    // ---------------------------------------------------------------------------
    // 夹具
    // ---------------------------------------------------------------------------

    function _freshToken() internal returns (FlapTaxTokenV3) {
        // EIP-1167 克隆（构造函数不执行，initialize 可用）
        FlapTaxTokenV3 impl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        FlapTaxTokenV3 t = FlapTaxTokenV3(payable(_clone(address(impl))));

        address[] memory pools = new address[](1);
        pools[0] = address(pair);

        t.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "TestToken",
                symbol: "TT",
                meta: "",
                buyTax: 300,
                sellTax: 500,
                taxProcessor: address(new DummyTaxProcessor()),
                dividendContract: address(0),
                quoteToken: address(wbnb),
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
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, address(this)));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }

    receive() external payable {}
}
