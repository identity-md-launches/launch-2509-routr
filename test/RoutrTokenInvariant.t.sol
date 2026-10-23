// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RoutrToken} from "../src/RoutrToken.sol";

/// @notice Moves tokens between a fixed set of actors with arbitrary transfers and approvals.
contract RoutrHandler is Test {
    RoutrToken public immutable token;
    address[] public actors;

    constructor(RoutrToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approveAndPull(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner_ = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(owner_));
        vm.prank(owner_);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(owner_, spender, amount);
    }
}

contract RoutrTokenInvariantTest is Test {
    RoutrToken internal token;
    RoutrHandler internal handler;

    function setUp() public {
        address[] memory actors = new address[](4);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        actors[3] = makeAddr("actor3");
        vm.prank(actors[0]);
        token = new RoutrToken();
        handler = new RoutrHandler(token, actors);
        targetContract(address(handler));
    }

    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }
}
