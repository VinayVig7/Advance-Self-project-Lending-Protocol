// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {LendingToken} from "./LendingToken.sol";

contract LendingProtocolEngine {
    ////////////
    // Errors //
    ///////////
    error LendingProtocolEngine__TokenAddressesAndPriceFeedAddressesShouldBeOfSameLength();
    error LendingProtocolEngine__InvalidTokenOrPriceFeed();
    error LendingProtocolEngine__InvalidDepositAmount();
    error LendingProtocolEngine__StalePrice();
    error LendingProtocolEngine__PriceBroken();

    /////////////////////
    // State Variables //
    ////////////////////
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountLendTokenMinted)
        private s_lendTokenMinted;
    address[] private s_collateralTokens;
    LendingToken immutable i_lendToken;

    ////////////
    // Events //
    ///////////
    event Deposited(
        address indexed token,
        address indexed user,
        uint256 indexed amount
    );
    event Borrowed(
        address indexed tokenDeposited,
        address indexed tokenBorrowed,
        uint256 indexed amountBorrowed
    );
    event Repay(address indexed tokenRepaid, uint256 indexed amountRepaid);
    event Redeemed(address indexed user, uint256 indexed amount);
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        uint256 indexed amount
    );

    ///////////////
    // Modifiers //
    //////////////

    ///////////////
    // Functions //
    //////////////
    /**
     * @notice Initializes the lending protocol with supported collateral tokens, their price feeds, and the lending token.
     * @dev
     * - Validates that the `tokenAddresses` and `priceFeedAddresses` arrays are the same length.
     * - Checks that no token or price feed address is the zero address.
     * - Maps each collateral token to its corresponding price feed and stores the token in the collateral list.
     * - Sets the lending token used for borrow/repay operations.
     * @param tokenAddresses Array of ERC20 token addresses that will be accepted as collateral.
     * @param priceFeedAddresses Array of Chainlink price feed contract addresses corresponding to each collateral token.
     * @param lendToken The address of the lending token contract.
     * @custom:reverts LendingProtocolEngine__TokenAddressesAndPriceFeedAddressesShouldBeOfSameLength if the input arrays have mismatched lengths.
     * @custom:reverts LendingProtocolEngine__InvalidTokenOrPriceFeed if any provided token or price feed address is zero.
     */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        LendingToken lendToken
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert LendingProtocolEngine__TokenAddressesAndPriceFeedAddressesShouldBeOfSameLength();
        }
        for (uint i = 0; i < tokenAddresses.length; i++) {
            if (
                tokenAddresses[i] == address(0) ||
                priceFeedAddresses[i] == address(0)
            ) {
                revert LendingProtocolEngine__InvalidTokenOrPriceFeed();
            }
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_lendToken = lendToken;
    }

    /**
     * @notice Allows a user to deposit an approved collateral token into the lending protocol.
     * @dev
     * - Validates that the token address is nonzero and supported (has a registered price feed).
     * - Reverts if the deposit amount is zero.
     * - Transfers the specified `amount` of the token from the user to the protocol.
     * - Updates the user's collateral balance for the given token.
     * - Emits a {Deposited} event on success.
     * @param tokenAddress The address of the ERC20 token being deposited as collateral.
     * @param amount The amount of the token to deposit (in the token's smallest unit).
     * @custom:reverts LendingProtocolEngine__InvalidTokenOrPriceFeed if the token is not supported or has an invalid address.
     * @custom:reverts LendingProtocolEngine__InvalidDepositAmount if the `amount` is zero.
     * @custom:requirements The caller must have approved this contract to spend at least `amount` of the given token.
     */
    function depositCollateral(address tokenAddress, uint256 amount) public {
        if (
            tokenAddress == address(0) ||
            s_priceFeeds[tokenAddress] == address(0)
        ) {
            revert LendingProtocolEngine__InvalidTokenOrPriceFeed();
        }
        if (amount == 0) {
            revert LendingProtocolEngine__InvalidDepositAmount();
        }

        // Depositing Tokens to engine
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);

        s_collateralDeposited[msg.sender][tokenAddress] += amount;

        emit Deposited(tokenAddress, msg.sender, amount);
    }

    function borrow(uint256 amount) public {}

    function repay() public {}

    function redeemCollateral() public {}

    function liquidate() public {}

    function addNewTokenForCollateralInEngine() public {}

    ////////////////////////
    // Internal Functions //
    ///////////////////////
    function getUserInformation(
        address user
    )
        internal
        view
        returns (
            uint256 _tokenMinted,
            uint256 _totalValueOfDepositedTokensInUsd
        )
    {
        uint256 tokenMinted = s_lendTokenMinted[user];
        uint256 totalValueOfDepositedTokensInUsd;

        for (uint i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount == 0) continue; // Skip if no deposit for this token

            uint256 priceInUsd = getUsdPriceOfToken(token); // normalized to 1e18
            uint8 decimals = IERC20Metadata(token).decimals();

            // Convert token amount to USD value with proper decimals handling
            uint256 valueInUsd = (amount * priceInUsd) / (10 ** decimals);

            totalValueOfDepositedTokensInUsd += valueInUsd;
        }

        return (tokenMinted, totalValueOfDepositedTokensInUsd);
    }

    ///////////////////////
    // Private Functions //
    //////////////////////
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 tokenMinted,
            uint256 totalValueOfDepositedTokensInUsd
        ) = getUserInformation(user);

        uint256 collateralAdjustedForThreshold = (totalValueOfDepositedTokensInUsd *
                LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        if (tokenMinted == 0) {
            // User has no debt, so they're not at risk
            return type(uint256).max;
        }

        //Simple Maths Understand the logic. Do hit and trial method for better understanding
        return (collateralAdjustedForThreshold * PRECISION) / tokenMinted;
    }

    /////////////
    // Getters //
    ////////////
    /**
     * @notice Fetches the latest USD price for a given token from its Chainlink price feed.
     * @dev
     * - Ensures the token has a registered price feed.
     * - Checks that the price returned is positive.
     * - Verifies the data is not stale.
     * - Normalizes the price to 18 decimals for consistent math across the protocol.
     * @param token The address of the ERC20 token to fetch the price for.
     * @return priceInUsd The latest token price in USD, normalized to 18 decimals.
     */
    function getUsdPriceOfToken(
        address token
    ) public view returns (uint256 priceInUsd) {
        address priceFeedAddr = s_priceFeeds[token];
        if (priceFeedAddr == address(0)) {
            revert LendingProtocolEngine__InvalidTokenOrPriceFeed();
        }

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddr);

        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        // Check for negative or zero price
        if (price <= 0) {
            revert LendingProtocolEngine__PriceBroken();
        }

        // check staleness (example: > 1 hour old is invalid)
        if (block.timestamp - updatedAt > 1 hours) {
            revert LendingProtocolEngine__StalePrice();
        }

        uint8 decimals = priceFeed.decimals();

        // Normalize to 18 decimals
        // Example: if feed has 8 decimals, multiply by 1e10
        if (decimals <= 18) {
            priceInUsd = uint256(price) * (10 ** (18 - decimals));
        } else {
            priceInUsd = uint256(price) / (10 ** (decimals - 18));
        }
    }
}
