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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LendingProtocolEngine is ReentrancyGuard, Ownable {
    ////////////
    // Errors //
    ///////////
    error LendingProtocolEngine__TokenAddressesAndPriceFeedAddressesShouldBeOfSameLength();
    error LendingProtocolEngine__InvalidTokenOrPriceFeed();
    error LendingProtocolEngine__InvalidDepositAmount();
    error LendingProtocolEngine__StalePrice();
    error LendingProtocolEngine__PriceBroken();
    error LendingProtocolEngine__HealthFactorBroken();
    error LendingProtocolEngine__InvalidBorrowAmount();
    error LendingProtocolEngine__InvalidRepayAmount();
    error LendingProtocolEngine__NothingToPay();
    error LendingProtocolEngine__RepayAmountCantExccedBorrowedAmount();
    error LendingProtocolEngine__NotEnoughCollateral();
    error LendingProtocolEngine__InvalidRedeemAmount();
    error LendingProtocolEngine__TokenAlreadyInlist();
    error LendingProtocolEngine__CantLiquidateYourOwnPosition();
    error LendingProtocolEngine__HealthFactorOk();

    /////////////////////
    // State Variables //
    ////////////////////
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MINIMUM_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 1.1e18;

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
        address indexed tokenBorrowed,
        uint256 indexed amountBorrowed
    );
    event Repay(address indexed tokenRepaid, uint256 indexed amountRepaid);
    event Redeemed(
        address indexed user,
        address indexed tokenAddr,
        uint256 indexed amount
    );
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        uint256 indexed amount,
        address collateralToken
    );

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
    ) Ownable(msg.sender) {
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
    function depositCollateral(
        address tokenAddress,
        uint256 amount
    ) public nonReentrant {
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

    /**
     * @notice Allows a user to borrow protocol debt tokens (LendingToken) against their deposited collateral.
     * @dev
     * - Validates that the borrow `amount` is greater than zero.
     * - Calculates the user's simulated debt after borrowing and checks their health factor using `_healthFactorCheckPoint`.
     * - Reverts if the post-borrow health factor would fall below `MINIMUM_HEALTH_FACTOR`.
     * - Updates the stored debt amount for the user.
     * - Intended to mint the borrowed LendingToken to the user (mint call is currently commented out until LendingToken logic is complete).
     * @param amount The amount of LendingToken to borrow (in the token's smallest unit, typically 18 decimals).
     * @custom:reverts LendingProtocolEngine__InvalidBorrowAmount if `amount` is zero.
     * @custom:reverts LendingProtocolEngine__HealthFactorBroken if borrowing would break the minimum health factor.
     * @custom:requirements The caller must have sufficient collateral deposited to maintain a healthy position after borrowing.
     */
    function borrow(uint256 amount) public nonReentrant {
        if (amount == 0) revert LendingProtocolEngine__InvalidBorrowAmount();

        // Step 1: Simulate
        uint256 newDebt = s_lendTokenMinted[msg.sender] + amount;
        if (
            _healthFactorCheckPoint(msg.sender, newDebt, address(0), 0) <=
            MINIMUM_HEALTH_FACTOR
        ) revert LendingProtocolEngine__HealthFactorBroken();

        // Step 2: Commit
        s_lendTokenMinted[msg.sender] = newDebt;

        i_lendToken.mint(msg.sender, amount);
        emit Borrowed(address(i_lendToken), amount);
    }

    /**
     * @notice Allows a user to repay a portion or all of their borrowed LendingToken debt.
     * @dev
     * - Validates that the `amount` is greater than zero.
     * - Checks the user's current debt and reverts if there is no debt to repay.
     * - Reverts if the repayment amount exceeds the user's outstanding debt.
     * - Reduces the user's stored debt balance by the repayment amount.
     * - Intended to burn the repaid LendingToken from the user's balance (burn call is currently commented out until LendingToken logic is complete).
     * @param amount The amount of LendingToken to repay (in the token's smallest unit).
     * @custom:reverts LendingProtocolEngine__InvalidRepayAmount if `amount` is zero.
     * @custom:reverts LendingProtocolEngine__NothingToPay if the user has no outstanding debt.
     * @custom:reverts LendingProtocolEngine__RepayAmountCantExccedBorrowedAmount if repayment amount exceeds the borrowed amount.
     * @custom:requirements The caller must have approved this contract to spend at least `amount` of LendingToken.
     */
    function repay(uint256 amount) public nonReentrant {
        if (amount == 0) revert LendingProtocolEngine__InvalidRepayAmount();

        uint256 debt = s_lendTokenMinted[msg.sender];
        if (debt == 0) revert LendingProtocolEngine__NothingToPay();
        if (amount > debt)
            revert LendingProtocolEngine__RepayAmountCantExccedBorrowedAmount();

        s_lendTokenMinted[msg.sender] = debt - amount;

        i_lendToken.burn(msg.sender, amount);
        emit Repay(address(i_lendToken), amount);
    }

    /**
     * @notice Allows a user to withdraw a portion of their deposited collateral from the protocol.
     * @dev
     * - Validates that the token is supported (nonzero address and has an associated price feed).
     * - Reverts if the redemption amount is zero or exceeds the user's deposited collateral.
     * - Simulates the user's position after collateral withdrawal to ensure the health factor remains >= 1.0.
     * - Prevents withdrawals that would put the user's position at risk of liquidation.
     * - Updates the stored collateral balance only after all checks pass.
     * - Transfers the specified collateral tokens back to the user.
     * @param tokenAddress The address of the ERC20 token to redeem from collateral.
     * @param amount The amount of collateral to withdraw (in the token's smallest unit).
     * @custom:reverts LendingProtocolEngine__InvalidRedeemAmount if `amount` is zero.
     * @custom:reverts LendingProtocolEngine__InvalidTokenOrPriceFeed if `tokenAddress` is not supported or has no price feed.
     * @custom:reverts LendingProtocolEngine__NotEnoughCollateral if `amount` exceeds the user's deposited collateral for that token.
     * @custom:reverts LendingProtocolEngine__HealthFactorBroken if the withdrawal would cause the health factor to drop below 1e18
     */
    function redeemCollateral(
        address tokenAddress,
        uint256 amount
    ) public nonReentrant {
        // Basic checks
        if (amount == 0) revert LendingProtocolEngine__InvalidRedeemAmount();
        if (
            tokenAddress == address(0) ||
            s_priceFeeds[tokenAddress] == address(0)
        ) revert LendingProtocolEngine__InvalidTokenOrPriceFeed();

        uint256 depositedAmount = s_collateralDeposited[msg.sender][
            tokenAddress
        ];
        if (depositedAmount < amount)
            revert LendingProtocolEngine__NotEnoughCollateral();

        // Simulate new collateral amount for checkpoint check
        uint256 newCollateral = depositedAmount - amount;
        if (
            _healthFactorCheckPoint(
                msg.sender,
                s_lendTokenMinted[msg.sender],
                tokenAddress,
                newCollateral
            ) < MINIMUM_HEALTH_FACTOR
        ) {
            revert LendingProtocolEngine__HealthFactorBroken();
        }

        // Commit storage update only after check passes
        s_collateralDeposited[msg.sender][tokenAddress] = newCollateral;

        // Transfer tokens
        IERC20(tokenAddress).transfer(msg.sender, amount);
        emit Redeemed(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Allows a third-party liquidator to repay part or all of an undercollateralized borrower's debt
     *         in exchange for seizing a proportional amount of the borrower's collateral plus a liquidation bonus.
     * @dev
     * - Can only be called if the borrower's health factor is below the minimum threshold.
     * - Prevents a user from liquidating their own position.
     * - Caps the `debtToCover` so the liquidator cannot repay more than the borrower's total outstanding debt.
     * - Transfers and burns the liquidator's lendTokens equal to the `debtToCover` amount.
     * - Calculates the collateral amount to seize based on:
     *      collateralAmount = (debtToCover × LIQUIDATION_BONUS) ÷ collateralTokenPrice
     * - If the borrower has less of the chosen collateral token than the amount to seize, the liquidator receives all of it.
     * - Updates protocol storage by reducing the borrower's debt and collateral balances.
     * - Transfers the seized collateral directly to the liquidator.
     * @param user The address of the borrower whose position is being liquidated.
     * @param debtToCover The amount of debt (in lendTokens) that the liquidator will repay on behalf of the borrower.
     * @param collateralToken The address of the ERC20 collateral token the liquidator will receive.
     * @custom:reverts LendingProtocolEngine__HealthFactorOk if the borrower's health factor is above the minimum.
     * @custom:reverts LendingProtocolEngine__CantLiquidateYourOwnPosition if `msg.sender` is the same as `user`.
     * @custom:requirements Liquidator must have approved the protocol to transfer at least `debtToCover` amount of lendTokens.
     */
    function liquidate(
        address user,
        uint256 debtToCover, // in lendToken
        address collateralToken
    ) public nonReentrant {
        if (_healthFactor(user) > MINIMUM_HEALTH_FACTOR)
            revert LendingProtocolEngine__HealthFactorOk();
        if (msg.sender == user)
            revert LendingProtocolEngine__CantLiquidateYourOwnPosition();

        uint256 userDebt = s_lendTokenMinted[user];
        if (debtToCover > userDebt) {
            debtToCover = userDebt;
        }

        IERC20(address(i_lendToken)).transferFrom(
            msg.sender,
            address(this),
            debtToCover
        );
        i_lendToken.burn(address(this), debtToCover);

        uint256 priceInUsd = getUsdPriceOfToken(collateralToken);

        // Formula: collateral to seize = (debt repaid × bonus) ÷ price
        // LIQUIDATION_BONUS is a multiplier like 1.1e18 for 110%
        uint256 collateralAmount = (debtToCover * LIQUIDATION_BONUS) /
            priceInUsd;

        // If borrower doesn't have enough of this collateral, take only what's available
        uint256 userCollateral = s_collateralDeposited[user][collateralToken];
        if (collateralAmount > userCollateral) {
            collateralAmount = userCollateral;
        }

        s_lendTokenMinted[user] -= debtToCover; // Reduce borrower's debt
        s_collateralDeposited[user][collateralToken] -= collateralAmount; // Reduce borrower's collateral

        // Give the seized collateral to the liquidator
        IERC20(collateralToken).transfer(msg.sender, collateralAmount);
        emit Liquidated(msg.sender, user, debtToCover, collateralToken);
    }

    /**
     * @notice Adds a new ERC20 token to the list of approved collateral in the lending engine.
     * @dev
     * - Only callable by the contract owner.
     * - Reverts if either the token or price feed address is the zero address.
     * - Reverts if the token is already in the collateral token list.
     * - Associates the token with its Chainlink price feed in {s_priceFeeds}.
     * @param tokenAddress The address of the ERC20 token to be approved as collateral.
     * @param priceFeedAddress The address of the Chainlink price feed contract for this token.
     * @custom:reverts LendingProtocolEngine__InvalidTokenOrPriceFeed if `tokenAddress` or `priceFeedAddress` is zero.
     * @custom:reverts LendingProtocolEngine__TokenAlreadyInlist if the token is already approved as collateral.
     */
    function addNewTokenForCollateralInEngine(
        address tokenAddress,
        address priceFeedAddress
    ) public onlyOwner {
        if (tokenAddress == address(0) || priceFeedAddress == address(0))
            revert LendingProtocolEngine__InvalidTokenOrPriceFeed();
        for (uint i = 0; i < s_collateralTokens.length; i++) {
            if (tokenAddress == s_collateralTokens[i])
                revert LendingProtocolEngine__TokenAlreadyInlist();
        }
        s_collateralTokens.push(tokenAddress);
        s_priceFeeds[tokenAddress] = priceFeedAddress;
    }
    ////////////////////////
    // Internal Functions //
    ///////////////////////
    /**
     * @notice Retrieves a user's total borrowed amount and total collateral value (in USD).
     * @dev
     * - Iterates over all supported collateral tokens to calculate the USD value of each deposit.
     * - Uses Chainlink price feeds via {getUsdPriceOfToken} to normalize prices to 1e18 precision.
     * - Skips tokens with zero balance for efficiency.
     * - Handles token decimal differences by dividing by `10 ** decimals` after multiplying by price.
     * @param user The address of the account whose information is being queried.
     * @return _tokenMinted The total amount of lendTokens minted (borrowed) by the user.
     * @return _totalValueOfDepositedTokensInUsd The sum USD value of all collateral deposited by the user, normalized to 1e18.
     */
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
    /**
     * @notice Calculates the current health factor of a user's position.
     * @dev
     * - Health factor is a measure of how safe the user's loan is, relative to liquidation.
     * - Formula:
     *      healthFactor = (collateralValueInUsd × LIQUIDATION_THRESHOLD ÷ LIQUIDATION_PRECISION) × PRECISION ÷ totalDebt
     * - If `tokenMinted` (debt) is zero, returns `type(uint256).max` (effectively infinite health factor).
     * - Uses `getUserInformation` to fetch total debt and collateral value in USD.
     * @param user The address of the account whose health factor is being calculated.
     * @return uint256 The health factor value (scaled by `PRECISION`, e.g., 1e18 = safe threshold).
     * @custom:logic A health factor below `MINIMUM_HEALTH_FACTOR` means the position is eligible for liquidation.
     */
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

    /**
     * @notice Simulates a user's health factor after a hypothetical change in debt or collateral.
     * @dev
     * - This function is designed for **gas optimization**: it reads from storage but never writes,
     *   avoiding expensive state changes while still providing an accurate simulation.
     * - Useful for "what-if" checks before committing a transaction (e.g., borrowing, redeeming collateral).
     * - Loops over all supported collateral tokens and calculates total collateral value in USD,
     *   substituting `simulatedCollateralAmount` for `tokenToSimulate` instead of the stored value.
     * - Uses `simulatedDebt` instead of the actual debt in health factor calculation.
     * - Formula:
     *      healthFactor = (collateralValueInUsd × LIQUIDATION_THRESHOLD ÷ LIQUIDATION_PRECISION) × PRECISION ÷ simulatedDebt
     * - If `simulatedDebt` is zero, returns `type(uint256).max` (effectively infinite health factor).
     * @param user The address of the account to simulate.
     * @param simulatedDebt The hypothetical total debt to test against.
     * @param tokenToSimulate The collateral token whose balance should be replaced with the simulated amount.
     * @param simulatedCollateralAmount The hypothetical balance for `tokenToSimulate` (in token's smallest unit).
     * @return uint256 The simulated health factor (scaled by `PRECISION`).
     */
    function _healthFactorCheckPoint(
        address user,
        uint256 simulatedDebt,
        address tokenToSimulate,
        uint256 simulatedCollateralAmount
    ) private view returns (uint256) {
        uint256 totalValueOfDepositedTokensInUsd;

        for (uint i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount;

            if (token == tokenToSimulate) {
                amount = simulatedCollateralAmount; // use simulated value for this token
            } else {
                amount = s_collateralDeposited[user][token];
            }

            if (amount == 0) continue;

            uint256 priceInUsd = getUsdPriceOfToken(token);
            uint8 decimals = IERC20Metadata(token).decimals();

            uint256 valueInUsd = (amount * priceInUsd) / (10 ** decimals);
            totalValueOfDepositedTokensInUsd += valueInUsd;
        }

        uint256 collateralAdjustedForThreshold = (totalValueOfDepositedTokensInUsd *
                LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        if (simulatedDebt == 0) {
            return type(uint256).max;
        }

        return (collateralAdjustedForThreshold * PRECISION) / simulatedDebt;
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

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function getUserInfo(address user) public view returns (uint256, uint256) {
        (uint256 tokenMinted, uint256 collateralValue) = getUserInformation(
            user
        );
        return (tokenMinted, collateralValue);
    }

    function getTokenValueFromCollateral(
        address user,
        address token
    ) public view returns (uint256) {
        if (token == address(0) || s_priceFeeds[token] == address(0)) {
            revert LendingProtocolEngine__InvalidTokenOrPriceFeed();
        }
        return s_collateralDeposited[user][token];
    }
}
