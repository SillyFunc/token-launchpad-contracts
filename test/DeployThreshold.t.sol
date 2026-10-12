// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "script/Deploy.s.sol";
import {Clones} from "src/Clones.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";

/// @dev Deployment only reads WETH(); no AMM pricing is mocked by these tests.
contract ThresholdDeploymentRouter {
    function WETH() external pure returns (address) {
        return address(0xBEEF);
    }
}

/// @dev Actually pulls queued tokens, preserving the token-side transfer and balance semantics.
contract ThresholdQueueProcessor {
    address public immutable token;
    uint256 public queued;
    uint256 public calls;

    constructor(address token_) {
        token = token_;
    }

    function processTaxTokens(uint256 amount) external returns (int8) {
        require(msg.sender == token, "only token");
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transfer failed");
        queued += IERC20(token).balanceOf(address(this)) - beforeBalance;
        calls++;
        return 0;
    }
}

contract DeployThresholdTest is Test {
    FlapTaxTokenV3 private implementation;
    FlapTaxTokenV3 private token;
    ThresholdQueueProcessor private processor;
    address private constant PAIR = address(0xCAFE);

    function setUp() public {
        // Exercise the real deployment script without touching the BSC deployment records.
        vm.chainId(3133712);
        string memory artifact = "script/deployments/3133712.json";
        assertFalse(vm.exists(artifact), "test deployment artifact already exists");
        string memory previousKeeper = vm.envOr("KEEPER_ADDRESS", string(""));
        string memory previousRouter = vm.envOr("ROUTER_ADDRESS", string(""));
        vm.setEnv("KEEPER_ADDRESS", vm.toString(address(0x1234)));
        vm.setEnv("ROUTER_ADDRESS", vm.toString(address(new ThresholdDeploymentRouter())));

        Deploy deployment = new Deploy();
        vm.recordLogs();
        deployment.run();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        vm.removeFile(artifact);
        vm.setEnv("KEEPER_ADDRESS", previousKeeper);
        vm.setEnv("ROUTER_ADDRESS", previousRouter);

        // Locate the implementation through its constructor event and public getter.
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != keccak256("Initialized(uint8)")) continue;
            try FlapTaxTokenV3(entries[i].emitter).START_LIQ_THRESHOLD() returns (uint256) {
                implementation = FlapTaxTokenV3(entries[i].emitter);
                break;
            } catch {}
        }
        assertTrue(address(implementation) != address(0), "deployed token implementation missing");

        token = FlapTaxTokenV3(Clones.clone(address(implementation)));
        processor = new ThresholdQueueProcessor(address(token));
        address[] memory pools = new address[](1);
        pools[0] = PAIR;
        token.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "Threshold Test",
                symbol: "THR",
                meta: "",
                buyTax: 1000,
                sellTax: 1000,
                taxProcessor: address(processor),
                dividendContract: address(0),
                quoteToken: address(0xBEEF),
                liqExpectedOutputAmount: 0,
                taxDuration: 365 days,
                pools: pools,
                v2Router: address(0),
                antiFarmerDuration: 0
            })
        );
        token.startMigration();
        token.finalizeMigration();
    }

    function test_DeploymentAndCloneUseApprovedThresholds() public view {
        assertEq(implementation.MIN_LIQ_THRESHOLD(), 50_000 ether);
        assertEq(implementation.START_LIQ_THRESHOLD(), 400_000 ether);
        assertEq(token.MIN_LIQ_THRESHOLD(), 50_000 ether);
        assertEq(token.initialLiquidationThreshold(), 400_000 ether);
        assertEq(token.liquidationThreshold(), 400_000 ether);
        assertEq(token.liqExpectedOutputAmount(), 0);
    }

    function test_QueuesAt400kOnNextSellAndWaitsBelowThreshold() public {
        token.transfer(PAIR, 3_999_999 ether);
        assertEq(token.balanceOf(address(token)), 399_999.9 ether);
        assertEq(processor.calls(), 0);

        // This sale reaches the boundary after the pre-transfer threshold check.
        token.transfer(PAIR, 1 ether);
        assertEq(token.balanceOf(address(token)), 400_000 ether);
        assertEq(processor.calls(), 0);

        token.transfer(PAIR, 1 ether);
        assertEq(processor.calls(), 1);
        assertEq(processor.queued(), 400_000 ether);
        assertEq(token.balanceOf(address(processor)), 400_000 ether);
        assertEq(token.balanceOf(address(token)), 0.1 ether);
        assertEq(token.liquidationThreshold(), 400_000 ether);
    }
}
