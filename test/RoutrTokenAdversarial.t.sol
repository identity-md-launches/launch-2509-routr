// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RoutrToken} from "src/RoutrToken.sol";

/// @dev Deploy and forward in one transaction, as a factory would. No privileged token hooks.
contract RoutrDeploymentProbe {
    function deployAndForward(bytes32 salt, address recipient, uint256 amount) external returns (RoutrToken token) {
        token = new RoutrToken{salt: salt}();
        require(token.transfer(recipient, amount), "forward failed");
    }
}

/// @notice Boundary, authorization, rollback, and algebraic properties supplement the original suite.
/// forge-config: default.fuzz.runs = 1000
contract RoutrTokenAdversarialTest is Test {
    // Independent specification: do not derive the expected supply from the implementation.
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    RoutrToken internal token;
    address internal deployer = makeAddr("adversarial deployer");
    address internal alice = makeAddr("adversarial alice");
    address internal bob = makeAddr("adversarial bob");
    address internal carol = makeAddr("adversarial carol");

    function setUp() public {
        vm.prank(deployer);
        token = new RoutrToken();
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(alice);
        RoutrToken fresh = new RoutrToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "constructor must mint once");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
        assertEq(fresh.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(deployer), SUPPLY, "deployments have independent storage");
    }

    function testFuzz_factoryMintsToImmediateDeployerAndForwardsExactly(bytes32 salt, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        RoutrDeploymentProbe factory = new RoutrDeploymentProbe();
        vm.recordLogs();
        vm.prank(alice, alice);
        RoutrToken fresh = factory.deployAndForward(salt, bob, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(factory)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(fresh.balanceOf(bob), amount);
        assertEq(fresh.balanceOf(alice), 0, "tx.origin must not receive the mint");
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_fullSupplyCanMoveRepeatedlyAndCannotBeSpentTwice() public {
        _transfer(deployer, alice, SUPPLY);
        _transfer(alice, bob, SUPPLY);
        _expectBalanceFailure(alice, bob, 0, 1);
        _transfer(bob, deployer, SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_oneWeiRoundTrip() public {
        _transfer(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
        assertEq(token.balanceOf(alice), 1);
        _transfer(alice, deployer, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_zeroTransferFromNeedsNoAllowanceButEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(carol);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, carol), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSelfTransferFromEmptyHolderEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, alice, 0);
        _transfer(alice, alice, 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_fullSupplySelfTransferPreservesBalanceAndAllowance() public {
        _approve(deployer, alice, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, deployer, SUPPLY);
        _transfer(deployer, deployer, SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferStillRequiresSufficientBalance() public {
        _transfer(deployer, alice, 1);
        _expectBalanceFailure(alice, alice, 1, 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_uint256MaxTransferRevertsWithoutChangingBalances() public {
        _expectBalanceFailure(deployer, alice, SUPPLY, type(uint256).max);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroRecipientRejectsEvenZeroTransfer() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalDoesNotRequireBalanceAndCanBeRevoked() public {
        _approve(alice, bob, type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        _transfer(deployer, alice, 2);
        _pull(bob, alice, carol, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(alice, bob, 0);
        _approve(alice, bob, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, carol, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(carol), 1);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_replacingInfiniteAllowanceWithFiniteAllowanceEnforcesNewLimit() public {
        _approve(deployer, alice, type(uint256).max);
        _approve(deployer, alice, 1);
        _pull(alice, deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
    }

    function test_maxMinusOneAllowanceIsFinite() public {
        _approve(deployer, alice, type(uint256).max - 1);
        _pull(alice, deployer, bob, SUPPLY);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 1 - SUPPLY);
        assertEq(token.balanceOf(bob), SUPPLY);
    }

    function test_infiniteAllowanceSurvivesRepeatedSpending() public {
        _approve(deployer, alice, type(uint256).max);
        _pull(alice, deployer, bob, 1);
        _pull(alice, deployer, bob, SUPPLY - 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_spenderCannotUseAnotherSpendersApproval() public {
        _approve(deployer, alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), SUPPLY);
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_deployerHasNoPrivilegeOverDistributedTokens() public {
        _transfer(deployer, alice, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10);
        _transfer(alice, bob, 10);
        assertEq(token.balanceOf(bob), 10);
    }

    function test_approvalCannotBeBorrowedFromAnotherOwner() public {
        _transfer(deployer, alice, 10);
        _approve(deployer, bob, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, carol, 1);
        assertEq(token.allowance(deployer, bob), SUPPLY);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(carol), 0);
    }

    function test_transferFromToOwnerConsumesAllowanceWithoutChangingBalance() public {
        _approve(deployer, alice, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, deployer, SUPPLY);
        _pull(alice, deployer, deployer, SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ownerCallingTransferFromStillRequiresSelfApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
        _approve(deployer, deployer, 1);
        _pull(deployer, deployer, alice, 1);
        assertEq(token.allowance(deployer, deployer), 0);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_failedTransferFromToZeroRestoresFiniteAllowance() public {
        _approve(deployer, alice, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(deployer, address(0), 10);
        assertEq(token.allowance(deployer, alice), 10);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
        _pull(alice, deployer, bob, 10);
        assertEq(token.balanceOf(bob), 10, "failed call must not consume spending capacity");
    }

    function test_failedTransferFromForBalanceRestoresFiniteAllowance() public {
        _transfer(deployer, alice, 1);
        _approve(alice, bob, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(bob);
        token.transferFrom(alice, carol, 2);
        assertEq(token.allowance(alice, bob), 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(carol), 0);
        _transfer(deployer, alice, 1);
        _pull(bob, alice, carol, 2);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(carol), 2);
    }

    function test_uint256MaxTransferFromCannotOverflowOrMint() public {
        _approve(deployer, alice, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(alice);
        token.transferFrom(deployer, bob, type(uint256).max);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSpenderRejectsZeroApprovalAndPreservesOtherApprovals() public {
        _approve(deployer, alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 0);
        assertEq(token.allowance(deployer, address(0)), 0);
        assertEq(token.allowance(deployer, alice), 1);
    }

    function testFuzz_transferRoundTripRestoresBothPreexistingBalances(uint256 initial, uint256 amount) public {
        initial = bound(initial, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY - initial);
        _transfer(deployer, alice, initial);
        _transfer(deployer, alice, amount);
        assertEq(token.balanceOf(alice), initial + amount);
        assertEq(token.balanceOf(deployer), SUPPLY - initial - amount);
        _transfer(alice, deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY - initial);
        assertEq(token.balanceOf(alice), initial);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_selfTransferIsAnIdentity(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, 0, balance);
        _transfer(deployer, alice, balance);
        _transfer(alice, alice, amount);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(deployer), SUPPLY - balance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approveReplacesRatherThanAddsAndIsIdempotent(uint256 first, uint256 second) public {
        _approve(deployer, alice, first);
        assertEq(token.allowance(deployer, alice), first);
        _approve(deployer, alice, second);
        assertEq(token.allowance(deployer, alice), second);
        _approve(deployer, alice, second);
        assertEq(token.allowance(deployer, alice), second);
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.allowance(alice, deployer), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitSpendingExhaustsExactlyTheApprovedAmount(uint256 approved, uint256 first) public {
        approved = bound(approved, 1, SUPPLY);
        first = bound(first, 0, approved);
        _approve(deployer, alice, approved);
        _pull(alice, deployer, bob, first);
        assertEq(token.allowance(deployer, alice), approved - first);
        _pull(alice, deployer, bob, approved - first);
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(bob), approved);
        assertEq(token.balanceOf(deployer), SUPPLY - approved);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(bob), approved);
        assertEq(token.balanceOf(deployer), SUPPLY - approved);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_overBalanceTransferIsAtomic(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        _transfer(deployer, alice, balance);
        _expectBalanceFailure(alice, bob, balance, amount);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY - balance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_overAllowanceTransferFromIsAtomic(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        _approve(deployer, alice, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, approved, amount)
        );
        vm.prank(alice);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), approved);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
    }

    function _pull(address spender, address from, address to, uint256 amount) internal {
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
    }

    function _expectBalanceFailure(address from, address to, uint256 balance, uint256 amount) internal {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
    }
}
