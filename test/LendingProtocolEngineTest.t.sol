// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LendingProtocolEngine} from "src/LendingProtocolEngine.sol";
import {LendingToken} from "src/LendingToken.sol";
import {HelperConfig, MockV3Aggregator} from "script/HelperConfig.s.sol";
import {DeployLendingProtocolEngine} from "script/DeployLendingProtocolEngine.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract LendingProtocolEngineTest is Test {
    LendingToken lendToken;
    LendingProtocolEngine engine;
    HelperConfig helperConfig;
    DeployLendingProtocolEngine deployer;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;

    address[] public tokenAddressesForTesting; // For testing
    address[] public priceFeedAddressesForTesting; // For testing

    address USER = makeAddr("user");
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DEPOSIT_VALUE = 1 ether;
    uint256 public constant BORROW_AMOUNT = 100 ether;
    uint256 public constant BORROW_AMOUNT_TO_BREAK_HEALTH_FACTOR = 900 ether;

    ///////////////
    // Modifiers //
    //////////////
    modifier depositTokenInEngine(uint256 value, address tokenAddr) {
        vm.startPrank(USER);
        ERC20Mock(tokenAddr).approve(address(engine), value);
        engine.depositCollateral(tokenAddr, value);
        vm.stopPrank();
        _;
    }

    modifier borrowTokenFromEngine(uint256 value) {
        vm.prank(USER);
        engine.borrow(value);
        _;
    }

    function setUp() public {
        deployer = new DeployLendingProtocolEngine();
        (engine, lendToken, helperConfig) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc) = helperConfig
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    function testConstructorRevertsIfTokenAddresesAndPriceFeedAddressesLengthAreNotSame()
        public
    {
        // Arrange
        tokenAddressesForTesting = [weth];
        priceFeedAddressesForTesting = [wethUsdPriceFeed, wbtcUsdPriceFeed];
        LendingProtocolEngine engineTesting;

        // Act, Assert
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__TokenAddressesAndPriceFeedAddressesShouldBeOfSameLength
                .selector
        );
        engineTesting = new LendingProtocolEngine(
            tokenAddressesForTesting, // tokenAddresses
            priceFeedAddressesForTesting, // priceFeedAddresses
            lendToken
        );
    }

    function testTokenAddressesAndPriceFeedAddressesCantHaveInvalidAddress()
        public
    {
        // Arrange
        tokenAddressesForTesting = [weth, address(0)];
        priceFeedAddressesForTesting = [wethUsdPriceFeed, wbtcUsdPriceFeed];
        LendingProtocolEngine engineTesting;

        // Act, Assert
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidTokenOrPriceFeed
                .selector
        );
        engineTesting = new LendingProtocolEngine(
            tokenAddressesForTesting, // tokenAddresses
            priceFeedAddressesForTesting, // priceFeedAddresses
            lendToken
        );
    }

    function testDepositCollateral() public {
        // Arrange
        uint256 value = 1 ether;
        address tokenAddr = weth;

        // Act
        vm.startPrank(USER);
        ERC20Mock(tokenAddr).approve(address(engine), value);
        engine.depositCollateral(tokenAddr, value);
        vm.stopPrank();

        // Assert
        uint256 valueOfToken = engine.getTokenValueFromCollateral(
            USER,
            tokenAddr
        );
        assertEq(valueOfToken, value);
    }

    function testDepositNotPossibleIfInvalidAddress() public {
        // Arrange
        uint256 value = 1 ether;
        address tokenAddr = weth;
        address invalidAddr = address(1); // This will be invalid because price feed will not have this address value so this will revert

        // Act
        vm.startPrank(USER);
        ERC20Mock(tokenAddr).approve(address(engine), value);

        // Assert
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidTokenOrPriceFeed
                .selector
        );
        engine.depositCollateral(invalidAddr, value);
        vm.stopPrank();
    }

    function testDepositNotPossibleWithZeroAmount() public {
        // Arrange
        uint256 value = 0;
        address tokenAddr = weth;

        // Act
        vm.startPrank(USER);
        ERC20Mock(tokenAddr).approve(address(engine), value);

        // Assert
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidDepositAmount
                .selector
        );
        engine.depositCollateral(tokenAddr, value);
        vm.stopPrank();
    }

    function testBorrow() public depositTokenInEngine(DEPOSIT_VALUE, weth) {
        // Arrange
        uint256 borrowAmount = 10 ether;

        // Act
        vm.prank(USER);
        engine.borrow(borrowAmount);

        // Assert
        (uint256 tokenMinted, ) = engine.getUserInfo(USER);
        assertEq(tokenMinted, borrowAmount);
    }

    function testBorrowNotPossibleWith0Amount() public {
        // Arrange
        uint256 invalidBorrowAmount = 0 ether;

        // Act, Asseet
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidBorrowAmount
                .selector
        );
        engine.borrow(invalidBorrowAmount);
    }

    function testBorrowNotPossibleWithHealthFactorBroken()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
    {
        // Arrange
        uint256 borrowAmountForBreakingHealthFactor = (1 ether) *
            uint(helperConfig.ETH_USD_PRICE());

        // Act, Asseet
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__HealthFactorBroken
                .selector
        );
        engine.borrow(borrowAmountForBreakingHealthFactor);
    }

    function testRepayWorking()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(BORROW_AMOUNT)
    {
        // Arrange
        uint256 repayAmount = 10 ether;

        // Act
        vm.prank(USER);
        engine.repay(repayAmount);

        // Assert
        (uint256 tokenMinted, ) = engine.getUserInfo(USER);
        assertEq(tokenMinted, BORROW_AMOUNT - repayAmount);
    }

    function testRepayNotPossibleWithInvalidAmount()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(BORROW_AMOUNT)
    {
        // Arrange
        uint256 invalidRepayAmount = 0 ether;

        // Act, Assert
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidRepayAmount
                .selector
        );
        engine.repay(invalidRepayAmount);
    }

    function testRepayNotPossibleIfThereIsNotBorrowedAmount()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
    {
        // Arrange
        uint256 repayAmount = 10 ether;

        // Act, Assert
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine.LendingProtocolEngine__NothingToPay.selector
        );
        engine.repay(repayAmount);
    }

    function testRepayNotPossibleMoreThanBorrowedAmount()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(BORROW_AMOUNT)
    {
        // Arrange
        uint256 repayAmountMoreThanBorrowed = 101 ether;

        // Act, Assert
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__RepayAmountCantExccedBorrowedAmount
                .selector
        );
        engine.repay(repayAmountMoreThanBorrowed);
    }

    function testRedeemWorking()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
    {
        // Arrange
        uint256 amount = 0.4 ether;
        uint256 balanceOfEngineBeforeRedeem = ERC20Mock(weth).balanceOf(
            address(engine)
        );

        // Act
        vm.prank(USER);
        engine.redeemCollateral(weth, amount);
        uint256 balanceOfEngineAfterRedeem = ERC20Mock(weth).balanceOf(
            address(engine)
        );

        // Assert
        uint256 valueLeft = engine.getTokenValueFromCollateral(USER, weth);
        assertEq(valueLeft, DEPOSIT_VALUE - amount);
        assertEq(
            balanceOfEngineBeforeRedeem,
            balanceOfEngineAfterRedeem + amount
        );
    }

    function testRedeemNotPossibleWithInvalidAmount()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
    {
        // Arrange
        uint256 invalidAmount = 0 ether;

        // Act, Assert
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidRedeemAmount
                .selector
        );
        engine.redeemCollateral(weth, invalidAmount);
    }

    function testRedeemNotPossibleForInvalidToken()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
    {
        // Arrange
        uint256 amount = 0.4 ether;
        address invalidAddress = address(1);

        // Act, Assert
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidTokenOrPriceFeed
                .selector
        );
        engine.redeemCollateral(invalidAddress, amount);
    }

    function testRedeemNotPossibleMoreThanDepositedAmount()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
    {
        // Arrange
        uint256 amountMoreThanDeposit = 10 ether;

        // Act, Assert
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__NotEnoughCollateral
                .selector
        );
        engine.redeemCollateral(weth, amountMoreThanDeposit);
    }

    function testRedeemNotPossibleIfHealthFactorBroked()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(
            BORROW_AMOUNT_TO_BREAK_HEALTH_FACTOR
        ) /** Here we borrowing more amount to break health factor  */
    {
        // Arrange
        uint256 amountToBreakHealthFactor = 0.6 ether;

        // Act, Assert
        vm.prank(USER);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__HealthFactorBroken
                .selector
        );
        engine.redeemCollateral(weth, amountToBreakHealthFactor);
    }

    function testLiquidateWorking()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(BORROW_AMOUNT_TO_BREAK_HEALTH_FACTOR)
    {
        // Arrange
        address liquidator = makeAddr("liquidator");
        uint256 liquidationAmount = 600 ether;

        // Mint lendTokens to liquidator so they can repay debt
        vm.prank(address(engine));
        lendToken.mint(liquidator, liquidationAmount);

        // Drop WETH price from 2000 to 1800
        int256 priceDrop = 1800e8; // 8 decimals, because MockV3Aggregator in HelperConfig uses DECIMALS = 8
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(priceDrop);

        // Act
        vm.startPrank(liquidator);
        lendToken.approve(address(engine), liquidationAmount);
        engine.liquidate(USER, liquidationAmount, weth);
        vm.stopPrank();

        // Assert
        (uint256 tokenMint, ) = engine.getUserInfo(USER);
        assertEq(
            tokenMint,
            BORROW_AMOUNT_TO_BREAK_HEALTH_FACTOR - liquidationAmount
        );
    }

    function testLiquidationNotPossibleIfHealthFactorIsOk()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(100 ether)
    {
        // Arrange
        address liquidator = makeAddr("liquidator");
        uint256 liquidationAmount = 600 ether;

        // Mint lendTokens to liquidator so they can repay debt
        vm.prank(address(engine));
        lendToken.mint(liquidator, liquidationAmount);

        // Act, Assert
        vm.startPrank(liquidator);
        lendToken.approve(address(engine), liquidationAmount);
        vm.expectRevert(
            LendingProtocolEngine.LendingProtocolEngine__HealthFactorOk.selector
        );
        engine.liquidate(USER, liquidationAmount, weth);
        vm.stopPrank();
    }

    function testUserCantLiquidateItsOwnPosition()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(BORROW_AMOUNT_TO_BREAK_HEALTH_FACTOR)
    {
        // Arrange
        address liquidator = makeAddr("liquidator");
        uint256 liquidationAmount = 600 ether;

        // Mint lendTokens to liquidator so they can repay debt
        vm.prank(address(engine));
        lendToken.mint(liquidator, liquidationAmount);

        // Drop WETH price from 2000 to 1800
        int256 priceDrop = 1800e8; // 8 decimals, because MockV3Aggregator in HelperConfig uses DECIMALS = 8
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(priceDrop);

        // Act, Assert
        vm.startPrank(USER);
        lendToken.approve(address(engine), liquidationAmount);
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__CantLiquidateYourOwnPosition
                .selector
        );
        engine.liquidate(USER, liquidationAmount, weth);
        vm.stopPrank();
    }

    function testLiquidateCantBeMorethanBorrowedAmount()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(BORROW_AMOUNT_TO_BREAK_HEALTH_FACTOR)
    {
        // Arrange
        address liquidator = makeAddr("liquidator");
        // liquidationAmountMoreThanBorrowed
        uint256 liquidationAmountMoreThanBorrowed = BORROW_AMOUNT_TO_BREAK_HEALTH_FACTOR +
                1 ether;

        // Mint lendTokens to liquidator so they can repay debt
        vm.prank(address(engine));
        lendToken.mint(liquidator, liquidationAmountMoreThanBorrowed);

        int256 priceDrop = 500e8; // 8 decimals, because MockV3Aggregator in HelperConfig uses DECIMALS = 8
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(priceDrop);

        // Act
        vm.startPrank(liquidator);
        lendToken.approve(address(engine), liquidationAmountMoreThanBorrowed);
        engine.liquidate(USER, liquidationAmountMoreThanBorrowed, weth);
        vm.stopPrank();

        // Assert
        (uint256 tokenMint, ) = engine.getUserInfo(USER);
        assertEq(tokenMint, 0);
    }

    function testAddNewTokenForCollateralInEngine() public {
        // Arrange
        address tokenAddressForAddingTest = address(1);
        address priceFeedAddressForAddingTest = address(2);

        // Act
        vm.prank(engine.owner());
        engine.addNewTokenForCollateralInEngine(
            tokenAddressForAddingTest,
            priceFeedAddressForAddingTest
        );
    }

    function testOwnerCantAddInvalidTokenInEngine() public {
        // Arrange
        address tokenAddressForAddingTest = address(0);
        address priceFeedAddressForAddingTest = address(2);

        // Act, Assert
        vm.prank(engine.owner());
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidTokenOrPriceFeed
                .selector
        );
        engine.addNewTokenForCollateralInEngine(
            tokenAddressForAddingTest,
            priceFeedAddressForAddingTest
        );
    }

    function testOwnerCantAddSameTokenInEngine() public {
        // Arrange, Act, Assert
        vm.prank(engine.owner());
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__TokenAlreadyInlist
                .selector
        );
        engine.addNewTokenForCollateralInEngine(weth, wethUsdPriceFeed);
    }

    function testGetHealthFactor()
        public
        depositTokenInEngine(DEPOSIT_VALUE, weth)
        borrowTokenFromEngine(BORROW_AMOUNT)
    {
        uint256 healthFactor = engine.getHealthFactor(USER);
        assert(healthFactor > 0);
    }

    function testGetUsdPriceOfToken() public view {
        uint256 tokenValue = engine.getUsdPriceOfToken(weth);
        uint256 decimals = 1e10; // aggregator price is in 8 decimals so to convert it in 18
        assertEq(tokenValue, uint(helperConfig.ETH_USD_PRICE()) * decimals);
    }

    function testGetUsdPriceOfTokenNotWorkForInvalidToken() public {
        // Arrange
        address invalidToken = address(0);

        // Act, Assert
        vm.expectRevert(
            LendingProtocolEngine
                .LendingProtocolEngine__InvalidTokenOrPriceFeed
                .selector
        );
        engine.getUsdPriceOfToken(invalidToken);
    }

    function testGetUsdPriceOfTokenRevertsIfPriceIsEqualToOrLessThanZero()
        public
    {
        // Arrange
        int256 tokenValue = 0;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(tokenValue);

        // Act, Assert
        vm.expectRevert(
            LendingProtocolEngine.LendingProtocolEngine__PriceBroken.selector
        );
        engine.getUsdPriceOfToken(weth);
    }

    function testGetUsdPriceOfTokenRevertsIfPriceIsStale() public {
        // Arrange
        uint256 increaseTime = 2 hours;
        vm.warp(increaseTime);

        // Act, Assert
        vm.expectRevert(
            LendingProtocolEngine.LendingProtocolEngine__StalePrice.selector
        );
        engine.getUsdPriceOfToken(weth);
    }


    /////////////////////////////
    // Mock Aggregator Testing //
    /////////////////////////////

    function testMockV3AggregatorGettersWork() public {
        // Arrange
        MockV3Aggregator mock = new MockV3Aggregator(8, 2000e8);

        // Act
        uint8 decimals = mock.decimals();
        string memory description = mock.description();
        uint256 version = mock.version();

        // Assert
        assertEq(decimals, 8);
        assertEq(description, "v0.6/tests/MockV3Aggregator.sol");
        assertEq(version, 0);
    }

    function testMockV3AggregatorUpdateAnswerUpdatesValue() public {
        MockV3Aggregator mock = new MockV3Aggregator(8, 2000e8);

        mock.updateAnswer(1500e8);

        (, int256 price, , , ) = mock.latestRoundData();
        assertEq(price, 1500e8);
    }

    function testMockV3AggregatorUpdateRoundDataUpdatesValues() public {
        MockV3Aggregator mock = new MockV3Aggregator(8, 2000e8);
        mock.updateRoundData(1, 1234e8, 100, 200);

        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = mock.latestRoundData();

        assertEq(roundId, 1);
        assertEq(price, 1234e8);
        assertEq(answeredInRound, 1);
    }
}
