// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {PRESALE} from "src/Presale.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";
import {BuybackVault} from "src/BuybackVault.sol";
import {BuybackVaultFactory} from "src/BuybackVaultFactory.sol";

// PancakeSwap V2 Router — BSC mainnet.
address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // FlapTaxTokenV3 实现：MIN=0.5% 供应量(5e6 ether)，START=1%(1e7 ether) — 主网口径（总量 1e9）
        FlapTaxTokenV3 flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);

        // 工厂与 Coordinator 存在循环引用：先建工厂（coordinator 占位 0），建好 Coordinator 后授权
        TokenFactory tokenFactory = new TokenFactory(address(flapImpl), ROUTER, address(0));

        PRESALE presaleTemplate = new PRESALE();
        PresaleFactory presaleFactory = new PresaleFactory(address(presaleTemplate), address(0));

        CoordinatorFactory coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), ROUTER);

        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        BuybackVault buybackImpl = new BuybackVault();
        BuybackVaultFactory buybackFactory = new BuybackVaultFactory(address(buybackImpl), address(coordinator));
        coordinator.setBuybackVaultFactory(address(buybackFactory));

        console2.log("FlapTaxTokenV3 impl:", address(flapImpl));
        console2.log("TokenFactory:", address(tokenFactory));
        console2.log("PRESALE template:", address(presaleTemplate));
        console2.log("PresaleFactory:", address(presaleFactory));
        console2.log("CoordinatorFactory:", address(coordinator));
        console2.log("BuybackVault impl:", address(buybackImpl));
        console2.log("BuybackVaultFactory:", address(buybackFactory));

        vm.stopBroadcast();

        string memory deploymentKey = "deployment";
        vm.serializeUint(deploymentKey, "chainId", block.chainid);
        vm.serializeAddress(deploymentKey, "flapTaxTokenImplementation", address(flapImpl));
        vm.serializeAddress(deploymentKey, "tokenFactory", address(tokenFactory));
        vm.serializeAddress(deploymentKey, "presaleImplementation", address(presaleTemplate));
        vm.serializeAddress(deploymentKey, "presaleFactory", address(presaleFactory));
        vm.serializeAddress(deploymentKey, "buybackVaultImplementation", address(buybackImpl));
        vm.serializeAddress(deploymentKey, "buybackVaultFactory", address(buybackFactory));
        string memory deploymentJson = vm.serializeAddress(deploymentKey, "coordinatorFactory", address(coordinator));

        string memory deploymentDirectory = "script/deployments";
        vm.createDir(deploymentDirectory, true);
        string memory deploymentPath = string.concat(deploymentDirectory, "/", vm.toString(block.chainid), ".json");
        vm.writeJson(deploymentJson, deploymentPath);
    }
}
