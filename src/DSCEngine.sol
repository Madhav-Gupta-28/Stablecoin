// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;


import {DSCoin} from "./DSCoin.sol";
import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { OracleLib, AggregatorV3Interface } from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Madhav Gupta
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */


contract DSCEngine  is ReentrancyGuard{


    ////////////        STATE VARIABLES        /////////////////////////////////

    DSCoin  private immutable  i_DSC;

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    // Mapping of token address to pricefeed address
    mapping(address token  => address pricefeed) public s_pricefeeds;

    // Amount of collateral deposited by user
    mapping(address user => mapping(address token => uint256 amount)) public s_userCollateral;

    // Amount of DSC minted by user
    mapping(address user => uint256 amountdscMinted) public s_userDSCMinted;

    /// @dev If we know exactly how many tokens we have, we could make this immutable!
    address[] private s_collateralTokens;



    //////////////            ERRORS        /////////////////////////////////
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__CollateralTokenNotAllowed();
    error DSCEngine_TokenAddressAndPricefeedLengthMismatch();
    error DSCEngine__ZeroAddress();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsBroken();
    error DSCEngine__HealthFactorIsOkay();
    error DSCEngine__HealthFactorIsNotImproved();


    //////////////           MODIFIERS        ///////////////////////////////// 

    modifier AmountMorethanZero(uint256 amount) {
        if(amount <= 0) {
            revert DSCEngine__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if(s_pricefeeds[token] == address(0)) {
            revert DSCEngine__CollateralTokenNotAllowed();
        }

        _;
    }


    ///////////////////       EVENTS        /////////////////////////////////
    event UserDepositedCollateral(address indexed user , address indexed  token , uint256 indexed amount);
    event UserRedeemedCollateral(address indexed user, address indexed token, uint256 indexed amount);



    //////////////           FUNCTIONS        /////////////////////////////////

    constructor(address[] memory tokenAddress , address[] memory pricefeeds , address dsc) {

        if(tokenAddress.length != pricefeeds.length) {
            revert DSCEngine_TokenAddressAndPricefeedLengthMismatch();
        }

        if(dsc == address(0)) {
            revert DSCEngine__ZeroAddress();
        }


        for(uint256 i = 0 ; i < tokenAddress.length ; i++){
            s_pricefeeds[tokenAddress[i]] = pricefeeds[i];
        }

        // Initialzing the DSC contract 
        i_DSC = DSCoin(dsc);


    }


    ///////////////       EXTERNAL FUNCTIONS        ////////////////////////////

    /**
     * @param token = Address of the token to deposit as collateral
     * @param amount = Amount of the token to deposit as collateral
     * @param amountDSCtoMint = Amount of DSC to mint
     * @notice This function will deposit the collateral and mint the DSC in one function call
     */
    function depositCollateralAndMintDSC(address token , uint256 amount , uint256 amountDSCtoMint) external {

        depositCollateral(token , amount , msg.sender);
        mintDSC(amountDSCtoMint);


    }


    
    /** 
    @param tokenCollateralAddress = Address of token in which user wants to deposit collateral in like Eth  , wetth , wbtc
    @param amount = Amount of token user wants to deposit as collateral
     */
    function depositCollateral(address tokenCollateralAddress , uint256 amount , address user) 
        public
        AmountMorethanZero(amount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant 
        
        {
         // Approve the contract to spend the token
        IERC20(tokenCollateralAddress).approve(address(this) , amount);

         // Transfer Token from users to the contract
        bool success = IERC20(tokenCollateralAddress).transferFrom(user , address(this) , amount);

        if(!success) {
            revert DSCEngine__TransferFailed();
        }

        // Updating the User collteral Mapping
        s_userCollateral[user][tokenCollateralAddress] += amount;

        emit UserDepositedCollateral(user , tokenCollateralAddress , amount);
    }



    function redeemCollateralForDSC(address tokenCollateralAddress , uint256 amountCollateral , uint256 amountDSCtoBurn) external AmountMorethanZero(amountCollateral) 
    isAllowedToken(tokenCollateralAddress)
    {


        // 1. Burn DSC
        _burnDSC(amountDSCtoBurn, msg.sender, msg.sender);
        // 2. Withdraw Collateral
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        // Revert if Health Factor is Broken
        _revertIfHealthFactorIsBroken(msg.sender);
    }



    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
        )
            external
            AmountMorethanZero(amountCollateral)
            nonReentrant
            isAllowedToken(tokenCollateralAddress)
        {
            _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
            _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(address tokenCollateralAddress , uint256 amountCollateral , address from , address to) private {

        s_userCollateral[from][tokenCollateralAddress] -= amountCollateral;

       emit UserRedeemedCollateral(to , tokenCollateralAddress , amountCollateral);

       bool success = IERC20(tokenCollateralAddress).transfer(to , amountCollateral);
       if(success =! true){
        revert DSCEngine__TransferFailed();
       }

    }



    function burnDSC(uint256 amountDSCtoBurn) private AmountMorethanZero(amountDSCtoBurn) {
        _burnDSC( amountDSCtoBurn , msg.sender , msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);


    }



    function _burnDSC(uint256 amountDSCtoBurn , address onbehalfOf , address dscFrom) private {
        s_userDSCMinted[onbehalfOf] -= amountDSCtoBurn;

        bool success = i_DSC.transferFrom(dscFrom , address(this) , amountDSCtoBurn);

        if(success =! true){
            revert DSCEngine__TransferFailed(); 
        }

        i_DSC.burn(amountDSCtoBurn);
    }



    /**
     * 
     * @param amountDSCtoMint = Amount of DSC to mint
     * @notice They must have more collateral value that the dsc to mint 
     */
    function mintDSC(uint256 amountDSCtoMint)
     public
     AmountMorethanZero(amountDSCtoMint)
     nonReentrant
     
    {
        s_userDSCMinted[msg.sender] += amountDSCtoMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_DSC.mint(msg.sender , amountDSCtoMint);

        if(minted != true){
            revert DSCEngine__MintFailed();
        }


    }
    
      /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * you DSC but keep your collateral in.
     */
    function burnDsc(uint256 amount) external AmountMorethanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    function liquidate(address collateral ,address user  , uint256 debtToCover) external AmountMorethanZero(debtToCover) nonReentrant {


        // First of all chechking that If the User Health Factor is Okay or Not If Okay then we can't liquidate the user
        uint256 startingUserHealthFactor = _healthFactor(user);

        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorIsOkay();
        }

        // Now we will calculate the amount of collateral to be redeemed
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral , debtToCover);

        // Now we will calculate the bonus collateral to be given to the liquidator
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * (LIQUIDATION_BONUS)) / LIQUIDATION_PRECISION;

        // Now we will redeem the collateral
        _redeemCollateral(collateral , tokenAmountFromDebtCovered +  bonusCollateral , user , msg.sender);

        // Now we will burn the DSC
        _burnDSC(debtToCover , user , msg.sender);

        // Now we will check that the health factor is improved or not
        uint256 endingUserHealthFactor = _healthFactor(user);

        // If not improved then we will revert
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealthFactorIsNotImproved();
        }

        _revertIfHealthFactorIsBroken(user);
    }


    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    
    function getAccountCollateralValueinUSD(address user) public view returns(uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_userCollateral[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
        
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    )
        public
        view
        returns (uint256)
    {
        return _getUsdValue(token, amount);
    }



    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_userCollateral[user][token];
    }

    ////////////// PRIVATE AND INTERNAL FUNCTIONS ////////////////////////////



    function _getAccountInformation(address user) private view returns(uint256 totalDScMinted ,uint256 totalCollateralValue){

        // Get total DSC minted by user
        totalDScMinted = s_userDSCMinted[user];

        // Get total collateral value
        totalCollateralValue = getAccountCollateralValueinUSD(user);

        return (totalDScMinted , totalCollateralValue);
    }


    function _healthFactor(address user) private view returns(uint256) {

        (uint256 totalDScMinted , uint256 totalCollateralValue) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDScMinted , totalCollateralValue);
    }   



    function _calculateHealthFactor(uint256 totalDscMinted , uint256 totalCollateralValue) internal pure returns(uint256) {

        if(totalDscMinted == 0 ) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (totalCollateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

    }

    function _revertIfHealthFactorIsBroken(address user) internal view {

        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken();
        }

    }


    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_pricefeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }


    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_pricefeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }


        function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }



}
