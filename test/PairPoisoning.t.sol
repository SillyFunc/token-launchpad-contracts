// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {PRESALE} from "src/Presale.sol";

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
    uint256 public totalSupply;

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

    function mint(address) external returns (uint256 liquidity) {
        uint256 amount0 = IERC20Lite(token0).balanceOf(address(this)) - reserve0;
        uint256 amount1 = IERC20Lite(token1).balanceOf(address(this)) - reserve1;
        require(amount0 > 0 && amount1 > 0, "mock: insufficient mint amounts");
        liquidity = 1e18;
        totalSupply = liquidity;
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

/// @title Pair 预投毒 griefing 回归：单边储备不得阻断 launch
/// @dev 历史攻击面：
///      createToken 即 createPair（储备 (0,0)）。任何人可向 pair 直捐 WBNB + sync()，
///      令储备变为 (token=0, bnb>0)；此后 launch() 的 addLiquidityETH 在报价分支除零
///      Panic(0x12) 恒 revert。攻击者需真实付出捐出的 WBNB（无资金被窃，纯 griefing）。
///
///      修复后首次加池直接向 canonical pair 注入两侧资产并 mint，不经过 Router 的 reserve quote，
///      因此已同步的单边 WBNB 储备只会成为对 LP 的额外捐赠，不再造成除零 DoS。
contract PairPoisoningTest is Test {
    uint256 constant SUPPLY = 1e9 ether;
    uint256 constant POISON = 0.5 ether;

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
    // 1) 投毒：launch 仍成功，募集 BNB 与预定代币数量完整进入池中
    // ---------------------------------------------------------------------------

    function test_PoisonedPair_DoesNotBlockLaunch() public {
        _poisonPair();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0), 0, "poisoned: token reserve = 0");
        assertEq(uint256(r1), POISON, "poisoned: bnb reserve = donated");

        presale.launch();

        assertEq(presale.presaleStatus(), 3, "launched");
        assertEq(presale.accumulatedBNB(), 0, "raise consumed");
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));
        (r0, r1,) = pair.getReserves();
        assertEq(uint256(r0), poolShare, "token reserve = pool share");
        assertEq(uint256(r1), POISON + 0.1 ether, "donation plus full raise");
    }

    // ---------------------------------------------------------------------------
    // 2) 既有超时失败退款闭环继续由其他状态机测试覆盖
    // ---------------------------------------------------------------------------

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
