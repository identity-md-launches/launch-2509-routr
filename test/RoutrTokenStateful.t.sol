// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RoutrToken} from "src/RoutrToken.sol";

/// @notice An independent ledger of authorized movements among four actors.
/// @dev Bounds come from the ledger, never from token balances that might already be wrong.
/// Approvals and spends are separate actions so revocations and old approvals survive between calls.
contract RoutrLedgerHandler is Test {
    RoutrToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public transfers;
    uint256 public pulls;
    uint256 public approvals;
    uint256 public rejectedCalls;

    constructor(RoutrToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = 1_000_000_000 * 10 ** 18;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer returned false");
        _move(from, to, amount);
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint256 mode) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount;
        mode %= 6;
        if (mode == 0) amount = 0;
        else if (mode == 1) amount = 1;
        else if (mode == 2) amount = type(uint256).max;
        else if (mode == 3) amount = type(uint256).max - 1;
        else if (mode == 4) amount = bound(amountSeed, 0, 1_000_000_000 * 10 ** 18);
        else amount = amountSeed;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "valid approval returned false");
        expectedAllowance[owner][spender] = amount;
        ++approvals;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = _amount(amountSeed, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "valid pull returned false");
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] = allowed - amount;
        _move(owner, to, amount);
        ++pulls;
    }

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(_actor(toSeed), amount);
        // Leave the ledger unchanged: the invariants check complete rollback after this call.
        ++rejectedCalls;
    }

    function transferFromOverLimit(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 limit = balance < allowed ? balance : allowed;
        // Exceed at least one limit, including finite approvals larger than the entire supply.
        uint256 amount = bound(amountSeed, limit + 1, type(uint256).max);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
        }
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), amount);
        ++rejectedCalls;
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++rejectedCalls;
    }

    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = _amount(amountSeed, limit);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        ++rejectedCalls;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(_actor(ownerSeed));
        token.approve(address(0), amount);
        ++rejectedCalls;
    }

    function _move(address from, address to, uint256 amount) internal {
        // Sequential updates also cover from == to without creating or destroying balance.
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 seed, uint256 limit) internal pure returns (uint256) {
        uint256 mode = seed % 4;
        if (mode == 0) return 0;
        if (mode == 1) return limit == 0 ? 0 : 1;
        if (mode == 2) return limit;
        return _bound(seed, 0, limit);
    }
}

/// @notice Expected failures are consumed in the handler; any unexpected revert fails the campaign.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RoutrTokenStatefulTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    RoutrToken internal token;
    RoutrLedgerHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        actors[0] = makeAddr("ledger deployer");
        actors[1] = makeAddr("ledger alice");
        actors[2] = makeAddr("ledger bob");
        actors[3] = makeAddr("ledger carol");
        vm.prank(actors[0]);
        token = new RoutrToken();
        handler = new RoutrLedgerHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.transferOverBalance.selector;
        selectors[4] = handler.transferFromOverLimit.selector;
        selectors[5] = handler.transferToZero.selector;
        selectors[6] = handler.transferFromToZero.selector;
        selectors[7] = handler.approveZeroSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyAndMetadataRemainAsSpecified() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.name(), "Routr");
        assertEq(token.symbol(), "ROUTR");
        assertEq(token.decimals(), 18);
    }

    function invariant_balancesMatchAuthorizedMovementsAndConserveSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedBalance(actors[i]), "unauthorized balance change");
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        // Every successful destination is an actor. These addresses never receive tokens.
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "wrong allowance or failed-call rollback"
                );
            }
            assertEq(token.allowance(actors[i], address(0)), 0);
            assertEq(token.allowance(address(0), actors[i]), 0);
        }
    }

    /// @dev All remaining holdings must still be transferable after every randomized sequence.
    function afterInvariant() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(i, 0, 2); // mode 2 selects the complete modeled balance
            assertEq(token.balanceOf(actors[i]), 0);
        }
        assertEq(token.balanceOf(actors[0]), SUPPLY);
        invariant_supplyAndMetadataRemainAsSpecified();
        invariant_balancesMatchAuthorizedMovementsAndConserveSupply();
        invariant_allowancesMatchApprovalsAndSuccessfulSpending();
    }

    /// @dev Deterministic reachability check: exercise nonzero spends, both rejection reasons,
    /// finite/infinite approvals, revocation, self-transfers, and every handler selector.
    function test_handlerExercisesPersistentApprovalsAndRollback() public {
        handler.transfer(0, 1, 2);
        handler.approve(1, 2, 10, 4);
        handler.transferFrom(1, 2, 3, 1);
        assertEq(token.balanceOf(actors[3]), 1);
        assertEq(token.allowance(actors[1], actors[2]), 9);
        handler.transferFromToZero(1, 2, 2);
        assertEq(token.allowance(actors[1], actors[2]), 9);
        handler.transferFromOverLimit(1, 2, 3, 10); // insufficient allowance
        handler.approve(1, 2, 0, 0); // revoke
        handler.transferFromOverLimit(1, 2, 3, 1);
        handler.approve(1, 2, 0, 3); // max - 1 is finite
        handler.transferFromOverLimit(1, 2, 3, SUPPLY); // balance failure after the allowance check
        handler.approve(1, 2, 0, 2); // infinite
        handler.transferFrom(1, 2, 3, 1);
        assertEq(token.allowance(actors[1], actors[2]), type(uint256).max);
        handler.transfer(1, 1, 2); // self-transfer
        handler.transferOverBalance(1, 3, type(uint256).max);
        handler.transferToZero(1, 2);
        handler.approveZeroSpender(1, type(uint256).max);

        assertEq(handler.transfers(), 2);
        assertEq(handler.pulls(), 2);
        assertEq(handler.approvals(), 4);
        assertEq(handler.rejectedCalls(), 7);
        invariant_supplyAndMetadataRemainAsSpecified();
        invariant_balancesMatchAuthorizedMovementsAndConserveSupply();
        invariant_allowancesMatchApprovalsAndSuccessfulSpending();
        afterInvariant();
    }
}
