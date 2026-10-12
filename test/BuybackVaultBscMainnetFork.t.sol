// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BuybackVault, BuybackConfig, BuybackMode, TriggerMode} from "src/BuybackVault.sol";
import {BuybackVaultFactory} from "src/BuybackVaultFactory.sol";
import {IPancakeRouter02, IPancakeFactory} from "src/lib/interfaces/IPancakeRouter02.sol";

contract MainnetForkBuybackToken is ERC20 {
    constructor() ERC20("Mainnet Fork Buyback Token", "MFBT") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @notice BSC 主网 fork 验证:在真实 PancakeSwap V2 主网路由器上跑通回购金库的两种模式。
/// @dev 需要 `BSC_RPC_URL` 环境变量。未设置时测试被显式 skip(而非静默通过)。
///      fork 中的交易只在本地模拟,不会广播上链,`deal` 只为测试账户提供余额。
contract BuybackVaultBscMainnetForkTest is Test {
    /// @dev 与 broadcast/Deploy.s.sol/56 中 TokenFactory 的 router 参数一致(已核对)。
    address internal constant MAINNET_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant DEAD = address(0xdead);
    uint256 internal constant BSC_MAINNET_CHAIN_ID = 56;
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @dev 测试合约同时充当 keeper registry:BuybackVault 通过 hasRole 校验调用者。
    ///      只有本测试合约拥有 keeper 角色,与测试网版本语义一致。
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == KEEPER_ROLE && account == address(this);
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BSC_RPC_URL not set; mainnet fork test skipped");
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, BSC_MAINNET_CHAIN_ID, "fork must be BSC mainnet");
        assertGt(MAINNET_ROUTER.code.length, 0, "mainnet router must exist on fork");
    }

    function test_mainnetRouterWiringAndPairBuyback() public {
        IPancakeRouter02 router = IPancakeRouter02(MAINNET_ROUTER);
        address wbnb = router.WETH();
        assertGt(router.factory().code.length, 0, "factory must exist");

        MainnetForkBuybackToken token = new MainnetForkBuybackToken();
        vm.deal(address(this), 10 ether);
        token.approve(MAINNET_ROUTER, type(uint256).max);

        // 低 WBNB 底池:配置的单次上限 0.001 BNB 高于池储备 1%,
        // 因此金库应缩小实际输入,而不是永久阻塞。与测试网版本意图一致。
        router.addLiquidityETH{value: 0.05 ether}(
            address(token), 100_000 ether, 99_000 ether, 0.0495 ether, address(this), block.timestamp + 5 minutes
        );
        address pair = IPancakeFactory(router.factory()).getPair(address(token), wbnb);
        assertTrue(pair != address(0), "pair must be created by the mainnet router");

        BuybackVault implementation = new BuybackVault();
        BuybackVaultFactory factory = new BuybackVaultFactory(address(implementation), address(this));

        BuybackVault tokenVault = _createVault(factory, token, pair, wbnb, BuybackMode.TokenBurn);
        vm.deal(address(tokenVault), 0.01 ether);
        (uint256 tokenAmount,) = tokenVault.previewBuyback();
        assertLt(tokenAmount, tokenVault.buybackAmount(), "reserve cap must shrink the input");
        assertGe(tokenAmount, tokenVault.MIN_EXECUTION_AMOUNT());

        uint256 minTokenOut = (_quote(router, wbnb, address(token), tokenAmount) * 95) / 100;
        tokenVault.executeBuyback(tokenAmount, minTokenOut, 0, uint64(block.timestamp + 5 minutes));
        assertGt(token.balanceOf(DEAD), 0, "tokens must be burned on mainnet fork");

        BuybackVault lpVault = _createVault(factory, token, pair, wbnb, BuybackMode.LpBurn);
        vm.deal(address(lpVault), 0.01 ether);
        (uint256 lpAmount,) = lpVault.previewBuyback();
        assertLt(lpAmount, lpVault.buybackAmount());
        assertGe(lpAmount, lpVault.MIN_EXECUTION_AMOUNT());

        uint256 minFallbackOut = (_quote(router, wbnb, address(token), lpAmount) * 95) / 100;
        uint256 lpSwapAmount = (lpAmount * lpVault.LP_SWAP_BPS()) / lpVault.BPS_DENOMINATOR();
        uint256 minLpOut = (_quote(router, wbnb, address(token), lpSwapAmount) * 95) / 100;
        uint256 deadLpBefore = IERC20(pair).balanceOf(DEAD);
        lpVault.executeBuyback(lpAmount, minFallbackOut, minLpOut, uint64(block.timestamp + 5 minutes));

        assertGt(IERC20(pair).balanceOf(DEAD), deadLpBefore, "LP must be locked to dead address");
        assertGt(lpVault.totalLpBurned(), 0);
        assertLe(lpVault.totalBuybackBNB(), lpAmount);
    }

    function _createVault(
        BuybackVaultFactory factory,
        MainnetForkBuybackToken token,
        address pair,
        address wbnb,
        BuybackMode mode
    ) internal returns (BuybackVault vault) {
        address clone = factory.createVault();
        BuybackConfig memory config = BuybackConfig({
            mode: mode,
            trigger: TriggerMode.Balance,
            firstExecuteAt: 0,
            intervalSeconds: 1 minutes,
            triggerAmount: 0.001 ether,
            buybackAmount: 0.001 ether
        });
        factory.initializeVault(clone, address(token), pair, MAINNET_ROUTER, wbnb, config);
        vault = BuybackVault(payable(clone));
    }

    function _quote(IPancakeRouter02 router, address wbnb, address token, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = token;
        return router.getAmountsOut(amountIn, path)[1];
    }

    receive() external payable {}
}
