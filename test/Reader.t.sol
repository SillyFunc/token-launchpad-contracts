// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BuybackVaultCoordinatorTest, MockBuybackPair} from "./BuybackVault.t.sol";
import {BuybackVault} from "src/BuybackVault.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {TokenConfig} from "src/TokenFactory.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {Reader, ReaderUnknownToken, InvalidReaderCoordinator, ReaderInvalidPair} from "src/Reader.sol";

contract ReaderTest is BuybackVaultCoordinatorTest {
    function test_readerReturnsRegisteredTokenSnapshot() public {
        (address token, address vault) = _readerToken("reader-snapshot");
        Reader reader = new Reader(address(coordinator));
        Reader.Snapshot memory snapshot = reader.getTokenSnapshot(token);
        assertEq(address(reader.coordinator()), address(coordinator));
        assertEq(snapshot.schemaVersion, 1);
        assertEq(snapshot.blockNumber, block.number);
        assertEq(snapshot.blockTimestamp, block.timestamp);
        assertEq(snapshot.contracts.token, token);
        assertEq(snapshot.contracts.vault, vault);
        assertEq(snapshot.contracts.taxProcessor, coordinator.tokenTaxProcessors(token));
        assertEq(snapshot.contracts.pair, IFlapTaxTokenV3(token).mainPool());
        assertEq(snapshot.contracts.wbnb, wbnb);
        assertEq(snapshot.controls.executionFlags, 7);
        assertEq(snapshot.pool.reserveToken, 1_000_000 ether);
        assertEq(snapshot.pool.reserveWbnb, 0.001 ether);
        assertEq(snapshot.pool.totalSupply, 1 ether);
        TaxProcessor processor = TaxProcessor(payable(snapshot.contracts.taxProcessor));
        assertEq(snapshot.tax.pendingAmount, processor.pendingTaxTokens());
        assertEq(snapshot.tax.feeConfig.marketBps, 10_000);
        assertEq(snapshot.tax.feeConfig.dividendToken, wbnb);
        assertEq(snapshot.liquidity.pendingToken, processor.lpTokenBalance());
        assertEq(snapshot.liquidity.pendingWbnb, processor.lpQuoteBalance());
        assertEq(snapshot.buyback.balance, vault.balance);
        assertEq(snapshot.buyback.nextExecuteTime, BuybackVault(payable(vault)).nextExecuteTime());
    }

    function test_readerReflectsLiveControlsAndReadiness() public {
        (address token, address vault) = _readerToken("reader-controls");
        Reader reader = new Reader(address(coordinator));
        vm.deal(vault, 0.00001 ether);
        vm.warp(BuybackVault(payable(vault)).nextExecuteTime());
        Reader.Snapshot memory ready = reader.getTokenSnapshot(token);
        assertEq(ready.buyback.executableAmount, 0.00001 ether);
        assertEq(ready.buyback.readiness, 0);
        coordinator.setExecutionControls(true, true, false);
        Reader.Snapshot memory paused = reader.getTokenSnapshot(token);
        assertEq(paused.controls.executionFlags, 3);
        assertEq(paused.buyback.executableAmount, 0);
        assertEq(paused.buyback.readiness, 6);
        assertEq(paused.buyback.balance, ready.buyback.balance);
    }

    function test_readerReflectsOriginalCreatorWithdrawal() public {
        (address token, address vault) = _readerToken("reader-withdrawal");
        Reader reader = new Reader(address(coordinator));
        vm.deal(vault, 0.00001 ether);
        vm.warp(BuybackVault(payable(vault)).nextExecuteTime());
        BuybackVault instance = BuybackVault(payable(vault));
        assertEq(instance.creator(), creator);
        address payable recipient = payable(address(0xBEEF));
        vm.prank(creator);
        instance.withdrawAll(recipient);
        Reader.Snapshot memory snapshot = reader.getTokenSnapshot(token);
        assertEq(snapshot.buyback.balance, 0);
        assertEq(snapshot.buyback.executableAmount, 0);
        assertEq(snapshot.buyback.readiness, 1);
        assertEq(recipient.balance, 0.00001 ether);
        assertEq(instance.totalWithdrawnBNB(), 0.00001 ether);
        assertEq(instance.buybackCount(), 0);
    }

    function test_processorExitPreservesDividendClaimsAndAvoidsRawTokenInVault() public {
        TokenConfig memory config = _tokenConfig();
        config.marketBps = 2_500;
        config.deflationBps = 2_500;
        config.lpBps = 2_500;
        config.dividendBps = 2_500;
        config.minimumShareBalance = 1 ether;
        bytes32 salt = _vanitySalt("processor-exit-dividend");
        vm.prank(creator);
        (address token, address presale, address vault) =
            coordinator.createTokenWithVault{value: 1 ether}(config, salt, _buyback());
        _seedReaderPair(token);
        FlapTaxTokenV3 asset = FlapTaxTokenV3(token);
        TaxProcessor processor = TaxProcessor(payable(coordinator.tokenTaxProcessors(token)));
        Dividend dividend = Dividend(payable(asset.dividendContract()));
        address holder = address(0xA11CE);
        address recipient = address(0xBEEF);
        vm.prank(presale);
        asset.transfer(holder, 1_000 ether);
        vm.prank(presale);
        asset.transfer(address(processor), 400 ether);

        vm.deal(address(this), 2 ether);
        wbnbToken.deposit{value: 1 ether}();
        wbnbToken.approve(address(dividend), 1 ether);
        assertTrue(dividend.deposit(1 ether));
        uint256 claimBefore = dividend.withdrawableDividendOf(holder);
        assertGt(claimBefore, 0);
        wbnbToken.deposit{value: 0.001 ether}();
        wbnbToken.transfer(address(processor), 0.001 ether);
        coordinator.setExecutionControls(false, false, false);

        vm.prank(creator);
        processor.withdrawAll(recipient);
        assertEq(asset.balanceOf(recipient), 300 ether);
        assertEq(asset.balanceOf(address(0xdead)), 100 ether);
        assertEq(asset.balanceOf(vault), 0, "raw market tokens bypass the registered vault");
        assertEq(wbnbToken.balanceOf(vault), 0.001 ether, "quote still follows its fixed recipient");
        assertEq(dividend.withdrawableDividendOf(holder), claimBefore);
        assertEq(dividend.withdrawableDividendOf(recipient), 0, "new shares cannot claim past dividends");
        assertEq(processor.totalDividendTokenSent(), 0);
        assertEq(processor.totalQuoteAddedToLiquidity(), 0);
        assertEq(processor.totalTaxTokenBurned(), 100 ether);

        Reader.Snapshot memory snapshot = new Reader(address(coordinator)).getTokenSnapshot(token);
        assertEq(snapshot.tax.pendingAmount, 0);
        assertEq(snapshot.liquidity.pendingToken, 0);
        assertEq(snapshot.liquidity.pendingWbnb, 0);
        assertTrue(dividend.withdrawDividendsFor(holder, false));
        assertEq(wbnbToken.balanceOf(holder), claimBefore);
    }

    function test_readerCoreFailureDoesNotBecomeZeroBalance() public {
        (address token,) = _readerToken("reader-core-failure");
        Reader reader = new Reader(address(coordinator));
        bytes memory reason = abi.encodeWithSignature("Error(string)", "unavailable");
        vm.mockCallRevert(coordinator.tokenTaxProcessors(token), abi.encodeWithSignature("pendingTaxTokens()"), reason);
        vm.expectRevert(reason);
        reader.getTokenSnapshot(token);
    }

    function test_readerRejectsUnknownTokenAndCoordinator() public {
        Reader reader = new Reader(address(coordinator));
        vm.expectRevert(abi.encodeWithSelector(ReaderUnknownToken.selector, address(123)));
        reader.getTokenSnapshot(address(123));
        vm.expectRevert(InvalidReaderCoordinator.selector);
        new Reader(address(0));
        vm.expectRevert();
        new Reader(address(router));
    }

    function test_readerRejectsMismatchedPool() public {
        (address token,) = _readerToken("reader-invalid-pool");
        Reader reader = new Reader(address(coordinator));
        address pair = IFlapTaxTokenV3(token).mainPool();
        vm.mockCall(pair, abi.encodeWithSignature("token0()"), abi.encode(address(123)));
        vm.expectRevert(ReaderInvalidPair.selector);
        reader.getTokenSnapshot(token);
    }

    function test_readerHandlesTokenWithoutVault() public {
        bytes32 salt = _vanitySalt("reader-no-vault");
        vm.prank(creator);
        (address token,) = coordinator.createToken{value: 1 ether}(_tokenConfig(), salt);
        _seedReaderPair(token);
        Reader reader = new Reader(address(coordinator));
        Reader.Snapshot memory snapshot = reader.getTokenSnapshot(token);
        assertEq(snapshot.contracts.vault, address(0));
        assertEq(snapshot.buyback.executableAmount, 0);
    }

    function _readerToken(string memory tag) internal returns (address token, address vault) {
        bytes32 salt = _vanitySalt(tag);
        vm.prank(creator);
        (token,, vault) = coordinator.createTokenWithVault{value: 1 ether}(_tokenConfig(), salt, _buyback());
        _seedReaderPair(token);
    }

    function _seedReaderPair(address token) internal {
        address pair = IFlapTaxTokenV3(token).mainPool();
        // This fixture validates reads only; real AMM execution is covered by the BSC fork suite.
        vm.mockCall(pair, abi.encodeWithSignature("totalSupply()"), abi.encode(1 ether));
        MockBuybackPair(pair).setReservesForTest(uint112(1_000_000 ether), uint112(0.001 ether));
    }
}
