// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CoordinatorFactory} from "src/CoordinatorFactory.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {TaxInfrastructureFactory} from "src/TaxInfrastructureFactory.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";

library TaxInfrastructureFixture {
    function configure(CoordinatorFactory coordinator, address wbnb)
        internal
        returns (TaxInfrastructureFactory factory)
    {
        TaxProcessor taxImpl = new TaxProcessor(address(coordinator));
        Dividend dividendImpl = new Dividend(wbnb, address(0xdead));
        factory = new TaxInfrastructureFactory(address(taxImpl), address(dividendImpl), address(coordinator));
        coordinator.setTaxInfrastructureFactory(address(factory));
    }
}
