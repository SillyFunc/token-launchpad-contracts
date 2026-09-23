// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {PRESALE} from "src/Presale.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";
import {BuybackVault} from "src/BuybackVault.sol";
import {BuybackVaultFactory} from "src/BuybackVaultFactory.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {TaxInfrastructureFactory} from "src/TaxInfrastructureFactory.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";

contract Deploy is Script {
    function run() external {
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        require(keeper != address(0), "KEEPER_ADDRESS is zero");
        address router = vm.envAddress("ROUTER_ADDRESS");
        require(router != address(0) && router.code.length != 0, "ROUTER_ADDRESS is invalid");

        vm.startBroadcast();

        // FlapTaxTokenV3 实现：MIN=0.5% 供应量(5e6 ether)，START=1%(1e7 ether) — 主网口径（总量 1e9）
        FlapTaxTokenV3 flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);

        // 工厂与 Coordinator 存在循环引用：先建工厂（coordinator 占位 0），建好 Coordinator 后授权
        TokenFactory tokenFactory = new TokenFactory(address(flapImpl), router, address(0));

        PRESALE presaleTemplate = new PRESALE();
        PresaleFactory presaleFactory = new PresaleFactory(address(presaleTemplate), address(0));

        CoordinatorFactory coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), router);
        coordinator.grantRole(coordinator.KEEPER_ROLE(), keeper);

        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        address wbnb = IPancakeRouter02(router).WETH();
        TaxProcessor taxProcessorImpl = new TaxProcessor(address(coordinator));
        Dividend dividendImpl = new Dividend(wbnb, address(0xdead));
        TaxInfrastructureFactory taxInfrastructureFactory =
            new TaxInfrastructureFactory(address(taxProcessorImpl), address(dividendImpl), address(coordinator));
        coordinator.setTaxInfrastructureFactory(address(taxInfrastructureFactory));

        BuybackVault buybackImpl = new BuybackVault();
        BuybackVaultFactory buybackFactory = new BuybackVaultFactory(address(buybackImpl), address(coordinator));
        coordinator.setBuybackVaultFactory(address(buybackFactory));

        console2.log("FlapTaxTokenV3 impl:", address(flapImpl));
        console2.log("TokenFactory:", address(tokenFactory));
        console2.log("PRESALE template:", address(presaleTemplate));
        console2.log("PresaleFactory:", address(presaleFactory));
        console2.log("CoordinatorFactory:", address(coordinator));
        console2.log("PancakeSwap V2 Router:", router);
        console2.log("Keeper:", keeper);
        console2.log("TaxProcessor impl:", address(taxProcessorImpl));
        console2.log("Dividend impl:", address(dividendImpl));
        console2.log("TaxInfrastructureFactory:", address(taxInfrastructureFactory));
        console2.log("BuybackVault impl:", address(buybackImpl));
        console2.log("BuybackVaultFactory:", address(buybackFactory));

        vm.stopBroadcast();

        // Dry-run simulations must not create a deployment file that could be mistaken for a broadcast result.
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) return;

        string memory deploymentKey = "deployment";
        vm.serializeUint(deploymentKey, "chainId", block.chainid);
        vm.serializeAddress(deploymentKey, "flapTaxTokenImplementation", address(flapImpl));
        vm.serializeAddress(deploymentKey, "tokenFactory", address(tokenFactory));
        vm.serializeAddress(deploymentKey, "presaleImplementation", address(presaleTemplate));
        vm.serializeAddress(deploymentKey, "presaleFactory", address(presaleFactory));
        vm.serializeAddress(deploymentKey, "taxProcessorImplementation", address(taxProcessorImpl));
        vm.serializeAddress(deploymentKey, "dividendImplementation", address(dividendImpl));
        vm.serializeAddress(deploymentKey, "taxInfrastructureFactory", address(taxInfrastructureFactory));
        vm.serializeAddress(deploymentKey, "buybackVaultImplementation", address(buybackImpl));
        vm.serializeAddress(deploymentKey, "buybackVaultFactory", address(buybackFactory));
        string memory deploymentJson = vm.serializeAddress(deploymentKey, "coordinatorFactory", address(coordinator));

        string memory deploymentDirectory = "script/deployments";
        vm.createDir(deploymentDirectory, true);
        string memory deploymentPath = string.concat(deploymentDirectory, "/", vm.toString(block.chainid), ".json");
        vm.writeJson(deploymentJson, deploymentPath);
    }
}
