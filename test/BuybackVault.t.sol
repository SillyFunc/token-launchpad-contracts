// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "src/Clones.sol";
import {
    BuybackVault,
    BuybackConfig,
    BuybackMode,
    TriggerMode,
    AlreadyInitialized,
    ZeroAddress,
    InvalidInterval,
    InvalidStartDelay,
    InvalidTriggerAmount,
    InvalidBuybackAmount,
    InvalidCallerReward,
    InsufficientBalance,
    TooEarly,
    OnlySelf
} from "src/BuybackVault.sol";
import {BuybackVaultFactory, ZeroImplementation, UnknownVault} from "src/BuybackVaultFactory.sol";
import {
    CoordinatorFactory,
    BuybackVaultFactoryNotSet,
    ZeroBuybackVaultFactory,
    AlreadyConfigured
} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {PRESALE} from "src/Presale.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {ITaxProcessor} from "src/lib/interfaces/ITaxProcessor.sol";
import {VanitySaltFinder} from "./TokenReservation.t.sol";

contract MockVaultERC20 {
    string public name = "TKN";
    string public symbol = "TKN";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint16 public buyTaxRate;
    uint16 public sellTaxRate;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setTax(uint16 buy_, uint16 sell_) external {
        buyTaxRate = buy_;
        sellTaxRate = sell_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockBuybackRouter {
    address public weth;
    address public pairFactory;
    bool public failSwap;
    bool public failAddLiquidity;

    constructor(address _weth) {
        weth = _weth;
    }

    function setPairFactory(address f) external {
        pairFactory = f;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function factory() external view returns (address) {
        return pairFactory;
    }

    function setFailSwap(bool v) external {
        failSwap = v;
    }

    function setFailAddLiquidity(bool v) external {
        failAddLiquidity = v;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata path, address to, uint256)
        external
        payable
    {
        if (failSwap) revert("mock: swap failed");
        MockVaultERC20(path[path.length - 1]).mint(to, msg.value);
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        if (failAddLiquidity) revert("mock: addLiquidity failed");
        MockVaultERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = 1e18;
        MockVaultERC20(token).mint(to, 0); // no-op touch
        to;
    }
}

contract BuybackVaultTest is Test {
    address constant DEAD = address(0xdead);

    BuybackVault impl;
    BuybackVaultFactory vaultFactory;
    MockVaultERC20 token;
    MockBuybackRouter router;
    address pair = address(0x1111);
    address wbnb = address(0xBEEB);

    address coordinator = address(this);
    address caller = address(0xCA11);

    function setUp() public {
        impl = new BuybackVault();
        vaultFactory = new BuybackVaultFactory(address(impl), coordinator);
        token = new MockVaultERC20();
        router = new MockBuybackRouter(wbnb);
        vm.deal(caller, 10 ether);
    }

    function _timeConfig() internal pure returns (BuybackConfig memory) {
        return BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Time,
            startDelayMinutes: 1,
            intervalMinutes: 1,
            triggerAmount: 0,
            buybackAmount: 0.01 ether,
            callerReward: 0.001 ether
        });
    }

    function _cloneInit(BuybackConfig memory cfg) internal returns (BuybackVault vault) {
        address clone = vaultFactory.createVault();
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);
        vault = BuybackVault(payable(clone));
    }

    function test_implementationLocked() public {
        vm.expectRevert(AlreadyInitialized.selector);
        impl.initialize(address(token), pair, address(router), wbnb, _timeConfig());
    }

    function test_zeroImplementationFactoryReverts() public {
        vm.expectRevert(ZeroImplementation.selector);
        new BuybackVaultFactory(address(0), coordinator);
    }

    function test_initializeVaultUnknownReverts() public {
        vm.expectRevert(UnknownVault.selector);
        vaultFactory.initializeVault(address(0x1234), address(token), pair, address(router), wbnb, _timeConfig());
    }

    function test_invalidConfigs() public {
        BuybackConfig memory cfg = _timeConfig();
        cfg.intervalMinutes = 0;
        address clone = vaultFactory.createVault();
        vm.expectRevert(InvalidInterval.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.buybackAmount = 0.0015 ether; // not 0.001 aligned
        vm.expectRevert(InvalidBuybackAmount.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.triggerAmount = 1 ether; // time mode must be 0
        vm.expectRevert(InvalidTriggerAmount.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.startDelayMinutes = 0;
        vm.expectRevert(InvalidStartDelay.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);

        clone = vaultFactory.createVault();
        cfg = _timeConfig();
        cfg.callerReward = 0.01 ether;
        cfg.buybackAmount = 0.01 ether; // reward >= amount
        vm.expectRevert(InvalidCallerReward.selector);
        vaultFactory.initializeVault(clone, address(token), pair, address(router), wbnb, cfg);
    }

    function test_timeTrigger_tooEarlyThenExecute() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 0.05 ether);

        assertFalse(vault.canExecuteBuyback());
        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback();

        vm.warp(block.timestamp + 60);
        assertTrue(vault.canExecuteBuyback());

        uint256 callerBefore = caller.balance;
        vm.prank(caller);
        vault.executeBuyback();

        assertEq(caller.balance, callerBefore + 0.001 ether);
        assertEq(token.balanceOf(DEAD), 0.01 ether);
        assertEq(vault.buybackCount(), 1);
        assertEq(vault.totalBuybackBNB(), 0.01 ether);
        assertEq(address(vault).balance, 0.05 ether - 0.01 ether - 0.001 ether);

        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback();
    }

    function test_timeTrigger_missedWindowExecutesOnce() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.deal(address(vault), 1 ether);
        vm.warp(block.timestamp + 10 days);
        vm.prank(caller);
        vault.executeBuyback();
        assertEq(vault.buybackCount(), 1);
        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback();
    }

    function test_balanceTrigger() public {
        BuybackConfig memory cfg = BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Balance,
            startDelayMinutes: 0,
            intervalMinutes: 1,
            triggerAmount: 1 ether,
            buybackAmount: 0.01 ether,
            callerReward: 0
        });
        BuybackVault vault = _cloneInit(cfg);

        vm.deal(address(vault), 0.5 ether);
        vm.prank(caller);
        vm.expectRevert(InsufficientBalance.selector);
        vault.executeBuyback();

        vm.deal(address(vault), 1 ether);
        vm.prank(caller);
        vault.executeBuyback();
        assertEq(vault.buybackCount(), 1);
        assertEq(address(vault).balance, 0.99 ether);
    }

    function test_timeAndBalance() public {
        BuybackConfig memory cfg = BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.TimeAndBalance,
            startDelayMinutes: 1,
            intervalMinutes: 1,
            triggerAmount: 1 ether,
            buybackAmount: 0.01 ether,
            callerReward: 0
        });
        BuybackVault vault = _cloneInit(cfg);
        vm.deal(address(vault), 1 ether);

        vm.prank(caller);
        vm.expectRevert(TooEarly.selector);
        vault.executeBuyback();

        vm.warp(block.timestamp + 60);
        vm.prank(caller);
        vault.executeBuyback();
        assertEq(vault.buybackCount(), 1);
    }

    function test_receiveDoesNotBuyback() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.warp(block.timestamp + 60);
        (bool ok,) = address(vault).call{value: 0.05 ether}("");
        assertTrue(ok);
        assertEq(vault.buybackCount(), 0);
        assertTrue(vault.canExecuteBuyback());
    }

    function test_lpFallbackToTokenBurn() public {
        BuybackConfig memory cfg = _timeConfig();
        cfg.mode = BuybackMode.LpBurn;
        cfg.callerReward = 0;
        BuybackVault vault = _cloneInit(cfg);
        router.setFailAddLiquidity(true);
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        vm.prank(caller);
        vault.executeBuyback();

        assertEq(token.balanceOf(DEAD), 0.01 ether);
        assertEq(vault.totalLpBurned(), 0);
        assertEq(vault.totalBurnedToken(), 0.01 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_lpSuccessBurnsLpNotTokenInventory() public {
        BuybackConfig memory cfg = _timeConfig();
        cfg.mode = BuybackMode.LpBurn;
        cfg.callerReward = 0;
        BuybackVault vault = _cloneInit(cfg);
        vm.deal(address(vault), 0.05 ether);
        vm.warp(block.timestamp + 60);

        vm.prank(caller);
        vault.executeBuyback();

        assertEq(vault.totalLpBurned(), 1e18);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalBuybackBNB(), 0.01 ether);
    }

    function test_lpBuybackAndBurnOnlySelf() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.expectRevert(OnlySelf.selector);
        vault.lpBuybackAndBurn(0.01 ether);
    }

    function test_insufficientBalance() public {
        BuybackVault vault = _cloneInit(_timeConfig());
        vm.warp(block.timestamp + 60);
        vm.prank(caller);
        vm.expectRevert(InsufficientBalance.selector);
        vault.executeBuyback();
    }

    function test_zeroAddressesOnInit() public {
        address clone = vaultFactory.createVault();
        vm.expectRevert(ZeroAddress.selector);
        vaultFactory.initializeVault(clone, address(0), pair, address(router), wbnb, _timeConfig());
    }
}

contract BuybackVaultCoordinatorTest is Test {
    uint256 constant SUPPLY = 1e9 ether;

    FlapTaxTokenV3 flapImpl;
    TokenFactory tokenFactory;
    PresaleFactory presaleFactory;
    CoordinatorFactory coordinator;
    BuybackVaultFactory vaultFactory;
    MockBuybackRouter router;
    address wbnb = address(0xAABB);
    address pair = address(0x1111);
    address creator = address(0xB0B);
    address feeReceiver = address(0xfee1);

    function setUp() public {
        flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        MockPairFactoryStub pairFactory = new MockPairFactoryStub();
        pairFactory.setPair(pair);
        router = new MockBuybackRouter(wbnb);
        router.setPairFactory(address(pairFactory));

        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE template = new PRESALE();
        presaleFactory = new PresaleFactory(address(template), address(0));
        coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));
        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        BuybackVault impl = new BuybackVault();
        vaultFactory = new BuybackVaultFactory(address(impl), address(coordinator));
        coordinator.setBuybackVaultFactory(address(vaultFactory));

        vm.deal(creator, 100 ether);
    }

    function _tokenConfig() internal view returns (TokenConfig memory) {
        return TokenConfig({
            name: "T",
            symbol: "T",
            meta: "",
            buyTax: 200,
            sellTax: 300,
            feeRecipient: feeReceiver,
            taxDuration: 365 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }

    function _vanitySalt(string memory tag) internal view returns (bytes32 salt) {
        (salt,) = VanitySaltFinder.find(address(tokenFactory), address(flapImpl), uint256(keccak256(bytes(tag))));
        require(salt != bytes32(0), "salt");
    }

    function _buyback() internal pure returns (BuybackConfig memory) {
        return BuybackConfig({
            mode: BuybackMode.TokenBurn,
            trigger: TriggerMode.Time,
            startDelayMinutes: 1,
            intervalMinutes: 1,
            triggerAmount: 0,
            buybackAmount: 0.01 ether,
            callerReward: 0
        });
    }

    function test_createTokenStillPaysFeeRecipient() public {
        bytes32 salt = _vanitySalt("wallet-mode");
        vm.prank(creator);
        (address token,) = coordinator.createToken{value: 1 ether}(_tokenConfig(), salt);
        assertEq(coordinator.tokenVaults(token), address(0));
    }

    function test_createTokenWithVaultWiresFeeReceiver() public {
        bytes32 salt = _vanitySalt("vault-mode");
        TokenConfig memory cfg = _tokenConfig();
        vm.prank(creator);
        (address token, address presale, address vault) =
            coordinator.createTokenWithVault{value: 1 ether}(cfg, salt, _buyback());

        assertEq(presale, coordinator.tokenPresales(token));
        assertEq(coordinator.tokenVaults(token), vault);
        assertEq(BuybackVault(payable(vault)).token(), token);
        assertEq(BuybackVault(payable(vault)).pair(), pair);

        address taxProcessor = FlapTaxTokenV3(token).taxProcessor();
        assertEq(ITaxProcessor(taxProcessor).feeReceiver(), vault);
    }

    function test_createTokenWithVaultRequiresFactory() public {
        CoordinatorFactory bare =
            new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));
        vm.expectRevert(BuybackVaultFactoryNotSet.selector);
        vm.prank(creator);
        bare.createTokenWithVault{value: 1 ether}(_tokenConfig(), _vanitySalt("nofactory"), _buyback());
    }

    function test_setBuybackVaultFactoryOnce() public {
        vm.expectRevert(AlreadyConfigured.selector);
        coordinator.setBuybackVaultFactory(address(0x1234));

        CoordinatorFactory bare =
            new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));
        vm.expectRevert(ZeroBuybackVaultFactory.selector);
        bare.setBuybackVaultFactory(address(0));
    }
}

contract MockPairFactoryStub {
    address public pair;

    function setPair(address p) external {
        pair = p;
    }

    function getPair(address, address) external view returns (address) {
        return pair;
    }

    function createPair(address, address) external view returns (address) {
        return pair;
    }
}
