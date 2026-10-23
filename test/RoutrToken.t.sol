// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RoutrToken} from "../src/RoutrToken.sol";
import {DeployRoutr} from "../script/DeployRoutr.s.sol";

contract RoutrTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    RoutrToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new RoutrToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "Routr");
        assertEq(token.symbol(), "ROUTR");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        RoutrToken fresh = new RoutrToken();
        assertEq(fresh.balanceOf(alice), SUPPLY);
    }

    function test_deployScriptMintsToItsDeployingContract() public {
        DeployRoutr script = new DeployRoutr();
        RoutrToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    // ---------------------------------------------------------------- transfers

    function test_transfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, alice, 100 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 100 ether));
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferHasNoFee() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);
        vm.prank(alice);
        token.transfer(bob, 1_000 ether);
        assertEq(token.balanceOf(bob), 1_000 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferZeroAmount() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        vm.prank(alice);
        token.transfer(bob, 11 ether);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- allowances

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(deployer, alice, 50 ether);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 50 ether));
        assertEq(token.allowance(deployer, alice), 50 ether);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 20 ether));
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.allowance(deployer, alice), 30 ether);
    }

    function test_infiniteAllowanceIsNotDecreased() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 5 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 5 ether, 6 ether)
        );
        vm.prank(alice);
        token.transferFrom(deployer, bob, 6 ether);
    }

    function test_RevertWhen_transferFromExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        vm.prank(bob);
        token.transferFrom(alice, bob, 2 ether);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- no privileged powers

    function test_noMintOrAdminEntryPoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "owner()",
            "transferOwnership(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, uint256(1 ether)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhen_sendingEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.prank(alice);
        if (amount > allowance_) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance_, amount)
            );
            token.transferFrom(deployer, bob, amount);
            assertEq(token.balanceOf(bob), 0);
        } else {
            token.transferFrom(deployer, bob, amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, alice), allowance_ - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
