// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {RoutrToken} from "../src/RoutrToken.sol";

/// @notice Reviewable reference deployment. The production launch is performed by IMD's factory
/// (`ProjectFactory.launchCustom`), which deploys `RoutrToken` from its creation code with no
/// constructor arguments and so receives the whole supply. This script reads no environment and
/// takes no configuration: the token has none.
contract DeployRoutr is Script {
    /// @notice Deploys the token; the caller of this function's deploying context receives the supply.
    function deploy() public returns (RoutrToken token) {
        token = new RoutrToken();
    }

    function run() external returns (RoutrToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
