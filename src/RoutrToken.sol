// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Routr (ROUTR)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 ROUTR (18 decimals) is minted
/// once, in the constructor, to the deployer. There is no owner, no mint, no burn, no pause, no
/// blacklist and no transfer fee: after deployment the supply can never change and only a holder
/// (or a spender the holder approved) can move that holder's balance.
contract RoutrToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "Routr";
    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "ROUTR";
    /// @notice The fixed total supply in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
