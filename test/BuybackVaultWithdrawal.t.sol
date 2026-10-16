// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "src/Clones.sol";
import {TransferHelper} from "src/TransferHelper.sol";
import {
    BuybackVault,
    BuybackConfig,
    BuybackMode,
    TriggerMode,
    BuybackReadiness,
    InsufficientBalance
} from "src/BuybackVault.sol";

interface IVaultWithdrawal {
    function creator() external view returns (address);
    function totalWithdrawnBNB() external view returns (uint256);
    function totalWithdrawnWBNB() external view returns (uint256);
    function withdrawAll(address payable recipient) external;
}

contract WithdrawalRegistry {
    mapping(address => address) public tokenCreators;
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    uint8 public executionFlags = 7;

    function registerCreator(address token, address creator) external {
        tokenCreators[token] = creator;
    }

    function setRole(bytes32 role, address account) external {
        hasRole[role][account] = true;
    }

    function setExecutionFlags(uint8 flags) external {
        executionFlags = flags;
    }
}

contract WithdrawalWBNB {
    mapping(address => uint256) public balanceOf;
    bool public returnFalse;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function setReturnFalse(bool value) external {
        returnFalse = value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return !returnFalse;
    }
}

contract WithdrawalPair {
    address public immutable token0;
    address public immutable token1;

    constructor(address token_, address wbnb_) {
        token0 = token_;
        token1 = wbnb_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (1_000_000 ether, 1 ether, uint32(block.timestamp));
    }
}

contract RejectWithdrawalBNB {
    receive() external payable {
        revert("recipient rejects BNB");
    }
}

contract ReentrantWithdrawalCreator {
    BuybackVault public vault;
    bytes public withdrawalFailure;
    bytes public buybackFailure;

    function withdrawFromVault(BuybackVault vault_) external {
        vault = vault_;
        IVaultWithdrawal(address(vault_)).withdrawAll(payable(address(this)));
    }

    receive() external payable {
        bool success;
        (success, withdrawalFailure) =
            address(vault).call(abi.encodeCall(IVaultWithdrawal.withdrawAll, (payable(address(this)))));
        require(!success, "reentrant withdrawal succeeded");
        (success, buybackFailure) = address(vault)
            .call(
                abi.encodeCall(BuybackVault.executeBuyback, (0.0001 ether, 1, 0, uint64(block.timestamp + 1 minutes)))
            );
        require(!success, "reentrant buyback succeeded");
    }
}

contract BuybackVaultWithdrawalTest is Test {
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    address constant TOKEN = address(0x1001);
    address constant CREATOR = address(0x1002);
    address constant KEEPER = address(0x1003);
    address constant ADMIN = address(0x1004);
    address constant PRESALE_OWNER = address(0x1005);
    address payable constant RECIPIENT = payable(address(0x1006));

    BuybackVault vault;
    IVaultWithdrawal withdrawal;
    WithdrawalRegistry registry;
    WithdrawalWBNB wrapped;

    event BNBWithdrawn(address indexed creator, address indexed recipient, uint256 amount);
    event WBNBWithdrawn(address indexed creator, address indexed recipient, uint256 amount);

    function setUp() public {
        vm.warp(1 days);
        registry = new WithdrawalRegistry();
        registry.registerCreator(TOKEN, CREATOR);
        registry.setRole(KEEPER_ROLE, KEEPER);
        registry.setRole(bytes32(0), ADMIN);
        wrapped = new WithdrawalWBNB();
        WithdrawalPair pair = new WithdrawalPair(TOKEN, address(wrapped));
        vault = BuybackVault(payable(Clones.clone(address(new BuybackVault()))));
        vault.initialize(
            TOKEN,
            address(pair),
            address(0x1007),
            address(wrapped),
            address(registry),
            BuybackConfig({
                mode: BuybackMode.TokenBurn,
                trigger: TriggerMode.Time,
                firstExecuteAt: uint64(block.timestamp + 1 minutes),
                intervalSeconds: 1 minutes,
                triggerAmount: 0,
                buybackAmount: 0.001 ether
            })
        );
        withdrawal = IVaultWithdrawal(address(vault));
        vm.deal(address(this), 10 ether);
        (bool success,) = address(vault).call{value: 0.001 ether}("");
        assertTrue(success);
        wrapped.deposit{value: 0.002 ether}();
        wrapped.transfer(address(vault), 0.002 ether);
        vm.warp(block.timestamp + 1 minutes);
    }

    function testCreatorAndWithdrawalAccounting() public view {
        assertEq(withdrawal.creator(), CREATOR);
        assertEq(withdrawal.totalWithdrawnBNB(), 0);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0);
    }

    function testWithdrawAllTransfersBothBalancesAndPreservesBuybackStats() public {
        uint64 nextTime = vault.nextExecuteTime();
        vm.expectEmit(true, true, false, true, address(vault));
        emit WBNBWithdrawn(CREATOR, RECIPIENT, 0.002 ether);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BNBWithdrawn(CREATOR, RECIPIENT, 0.001 ether);
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        assertEq(address(vault).balance, 0);
        assertEq(wrapped.balanceOf(address(vault)), 0);
        assertEq(RECIPIENT.balance, 0.001 ether);
        assertEq(wrapped.balanceOf(RECIPIENT), 0.002 ether);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.001 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0.002 ether);
        _assertUnchangedBuybackStats(nextTime);
    }

    function testCreatorCanWithdrawWithoutKeeperOrAdminRoles() public {
        assertFalse(registry.hasRole(KEEPER_ROLE, CREATOR));
        assertFalse(registry.hasRole(bytes32(0), CREATOR));
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.001 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0.002 ether);
    }

    function testWithdrawAllUsesCurrentBalancesAndAccumulatesLaterDeposits() public {
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);

        (bool success,) = address(vault).call{value: 0.0003 ether}("");
        assertTrue(success);
        wrapped.deposit{value: 0.0004 ether}();
        wrapped.transfer(address(vault), 0.0004 ether);
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);

        assertEq(address(vault).balance, 0);
        assertEq(wrapped.balanceOf(address(vault)), 0);
        assertEq(RECIPIENT.balance, 0.0013 ether);
        assertEq(wrapped.balanceOf(RECIPIENT), 0.0024 ether);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.0013 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0.0024 ether);
    }

    function testOnlyOriginalCreatorCanWithdrawAll() public {
        address[4] memory unauthorized = [address(this), KEEPER, ADMIN, PRESALE_OWNER];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.expectRevert(bytes4(keccak256("UnauthorizedCreator()")));
            vm.prank(unauthorized[i]);
            withdrawal.withdrawAll(RECIPIENT);
        }
        assertEq(address(vault).balance, 0.001 ether);
        assertEq(wrapped.balanceOf(address(vault)), 0.002 ether);
    }

    function testCreatorRegistryFailureDoesNotPermitWithdrawal() public {
        bytes memory failure = hex"deadbeef";
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("tokenCreators(address)", TOKEN), failure);
        vm.expectRevert(failure);
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        assertEq(withdrawal.totalWithdrawnBNB(), 0);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0);
        assertEq(address(vault).balance, 0.001 ether);
        assertEq(wrapped.balanceOf(address(vault)), 0.002 ether);
    }

    function testWithdrawalRemainsAvailableWhileMaintenancePaused() public {
        registry.setExecutionFlags(0);
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        assertEq(address(vault).balance, 0);
        assertEq(wrapped.balanceOf(address(vault)), 0);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.001 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0.002 ether);
        assertEq(vault.buybackCount(), 0);
    }

    function testWithdrawAllSkipsZeroWbnbBalance() public {
        uint64 nextTime = vault.nextExecuteTime();
        vm.prank(address(vault));
        wrapped.transfer(address(this), 0.002 ether);
        wrapped.setReturnFalse(true);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BNBWithdrawn(CREATOR, RECIPIENT, 0.001 ether);
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        assertEq(address(vault).balance, 0);
        assertEq(RECIPIENT.balance, 0.001 ether);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.001 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0);
        _assertUnchangedBuybackStats(nextTime);
    }

    function testWithdrawAllSkipsZeroBnbBalance() public {
        uint64 nextTime = vault.nextExecuteTime();
        vm.deal(address(vault), 0);
        RejectWithdrawalBNB rejector = new RejectWithdrawalBNB();
        vm.expectEmit(true, true, false, true, address(vault));
        emit WBNBWithdrawn(CREATOR, address(rejector), 0.002 ether);
        vm.prank(CREATOR);
        withdrawal.withdrawAll(payable(address(rejector)));
        assertEq(wrapped.balanceOf(address(vault)), 0);
        assertEq(wrapped.balanceOf(address(rejector)), 0.002 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0.002 ether);
        assertEq(withdrawal.totalWithdrawnBNB(), 0);
        assertEq(address(vault).balance, 0);
        _assertUnchangedBuybackStats(nextTime);
    }

    function testWithdrawRejectsZeroAndSelfRecipients() public {
        address[2] memory recipients = [address(0), address(vault)];
        for (uint256 i; i < recipients.length; ++i) {
            vm.expectRevert(bytes4(keccak256("InvalidWithdrawalRecipient()")));
            vm.prank(CREATOR);
            withdrawal.withdrawAll(payable(recipients[i]));
        }
    }

    function testWithdrawAllWithEmptyBalancesIsANoOp() public {
        vm.startPrank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        wrapped.setReturnFalse(true);
        RejectWithdrawalBNB rejector = new RejectWithdrawalBNB();
        vm.recordLogs();
        withdrawal.withdrawAll(payable(address(rejector)));
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.001 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0.002 ether);
    }

    function testRejectedNativeTransferRollsBackAccountingAndBalance() public {
        RejectWithdrawalBNB rejector = new RejectWithdrawalBNB();
        vm.expectRevert(abi.encodeWithSelector(TransferHelper.ETHTransferFailed.selector, address(rejector)));
        vm.prank(CREATOR);
        withdrawal.withdrawAll(payable(address(rejector)));
        assertEq(withdrawal.totalWithdrawnBNB(), 0);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0);
        assertEq(address(vault).balance, 0.001 ether);
        assertEq(wrapped.balanceOf(address(vault)), 0.002 ether);
        assertEq(address(rejector).balance, 0);
        assertEq(wrapped.balanceOf(address(rejector)), 0);
    }

    function testFalseTokenTransferRollsBackTokenAndWithdrawalAccounting() public {
        wrapped.setReturnFalse(true);
        vm.expectRevert(abi.encodeWithSelector(TransferHelper.TransferFailed.selector, address(wrapped), RECIPIENT));
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        assertEq(withdrawal.totalWithdrawnBNB(), 0);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0);
        assertEq(address(vault).balance, 0.001 ether);
        assertEq(RECIPIENT.balance, 0);
        assertEq(wrapped.balanceOf(address(vault)), 0.002 ether);
        assertEq(wrapped.balanceOf(RECIPIENT), 0);
    }

    function testWithdrawalAndBuybackShareReentrancyGuard() public {
        ReentrantWithdrawalCreator creatorContract = new ReentrantWithdrawalCreator();
        registry.registerCreator(TOKEN, address(creatorContract));
        registry.setRole(KEEPER_ROLE, address(creatorContract));
        creatorContract.withdrawFromVault(vault);
        bytes memory guardError = abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call");
        assertEq(creatorContract.withdrawalFailure(), guardError);
        assertEq(creatorContract.buybackFailure(), guardError);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.001 ether);
        assertEq(withdrawal.totalWithdrawnWBNB(), 0.002 ether);
        assertEq(address(vault).balance, 0);
        assertEq(wrapped.balanceOf(address(vault)), 0);
        assertEq(address(creatorContract).balance, 0.001 ether);
        assertEq(wrapped.balanceOf(address(creatorContract)), 0.002 ether);
        assertEq(vault.buybackCount(), 0);
    }

    function testWithdrawalInvalidatesOutstandingBuybackAmount() public {
        (uint256 quotedAmount,) = vault.previewBuyback();
        assertEq(quotedAmount, 0.001 ether);
        uint64 nextTime = vault.nextExecuteTime();
        vm.prank(CREATOR);
        withdrawal.withdrawAll(RECIPIENT);
        (uint256 updatedAmount, BuybackReadiness readiness) = vault.previewBuyback();
        assertEq(updatedAmount, 0);
        assertEq(uint8(readiness), uint8(BuybackReadiness.InsufficientBalance));
        vm.expectRevert(InsufficientBalance.selector);
        vm.prank(KEEPER);
        vault.executeBuyback(quotedAmount, 1, 0, uint64(block.timestamp + 1 minutes));
        _assertUnchangedBuybackStats(nextTime);
        assertEq(address(vault).balance, 0);
        assertEq(withdrawal.totalWithdrawnBNB(), 0.001 ether);
    }

    function _assertUnchangedBuybackStats(uint64 nextTime) private view {
        assertEq(vault.nextExecuteTime(), nextTime);
        assertEq(vault.lastExecuteTime(), 0);
        assertEq(vault.buybackCount(), 0);
        assertEq(vault.totalBuybackBNB(), 0);
        assertEq(vault.totalBurnedToken(), 0);
        assertEq(vault.totalLpBurned(), 0);
    }
}
