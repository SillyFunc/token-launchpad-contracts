// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BuybackVault, BuybackConfig, BuybackMode, TriggerMode} from "src/BuybackVault.sol";
import {BuybackVaultFactory} from "src/BuybackVaultFactory.sol";
import {IPancakeRouter02, IPancakeFactory} from "src/lib/interfaces/IPancakeRouter02.sol";

contract ForkBuybackToken is ERC20 {
    constructor() ERC20("Fork Buyback Token", "FBT") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @notice 可选 BSC testnet fork 验证；普通本地测试链会直接跳过。
contract BuybackVaultBscForkTest is Test {
    address internal constant ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address internal constant DEAD = address(0xdead);
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == KEEPER_ROLE && account == address(this);
    }

    function test_realPancakeTokenAndLpBuyback() public {
        if (block.chainid != 97) return;

        IPancakeRouter02 router = IPancakeRouter02(ROUTER);
        address wbnb = router.WETH();
        ForkBuybackToken token = new ForkBuybackToken();
        vm.deal(address(this), 10 ether);

        token.approve(ROUTER, type(uint256).max);
        // 故意使用低 WBNB 底池：配置上限 0.001 BNB 会高于池储备的 1%，
        // 用真实 Pancake Pair 验证 Vault 会缩小实际输入而不是永久阻塞。
        router.addLiquidityETH{value: 0.05 ether}(
            address(token), 100_000 ether, 99_000 ether, 0.0495 ether, address(this), block.timestamp + 5 minutes
        );
        address pair = IPancakeFactory(router.factory()).getPair(address(token), wbnb);
        assertTrue(pair != address(0));

        BuybackVault implementation = new BuybackVault();
        BuybackVaultFactory factory = new BuybackVaultFactory(address(implementation), address(this));

        BuybackVault tokenVault = _createVault(factory, token, pair, wbnb, BuybackMode.TokenBurn);
        vm.deal(address(tokenVault), 0.01 ether);
        (uint256 tokenAmount,) = tokenVault.previewBuyback();
        assertLt(tokenAmount, tokenVault.buybackAmount());
        assertGe(tokenAmount, tokenVault.MIN_EXECUTION_AMOUNT());
        uint256 minTokenOut = (_quote(router, wbnb, address(token), tokenAmount) * 95) / 100;
        tokenVault.executeBuyback(tokenAmount, minTokenOut, 0, uint64(block.timestamp + 5 minutes));
        assertGt(token.balanceOf(DEAD), 0);

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

        assertGt(IERC20(pair).balanceOf(DEAD), deadLpBefore);
        assertGt(lpVault.totalLpBurned(), 0);
        assertLe(lpVault.totalBuybackBNB(), lpAmount);
    }

    function _createVault(
        BuybackVaultFactory factory,
        ForkBuybackToken token,
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
        factory.initializeVault(clone, address(token), pair, ROUTER, wbnb, config);
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
