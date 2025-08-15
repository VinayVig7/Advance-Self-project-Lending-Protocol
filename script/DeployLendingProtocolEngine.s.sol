// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LendingProtocolEngine} from "src/LendingProtocolEngine.sol";
import {LendingToken} from "src/LendingToken.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployLendingProtocolEngine is Script {
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function run()
        public
        returns (LendingProtocolEngine, LendingToken, HelperConfig)
    {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!

        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc
        ) = helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast();
        LendingToken lendToken = new LendingToken();
        LendingProtocolEngine engine = new LendingProtocolEngine(
            tokenAddresses,
            priceFeedAddresses,
            lendToken
        );
        lendToken.transferOwnership(address(engine));
        vm.stopBroadcast();
        return (engine, lendToken, helperConfig);
    }
}
