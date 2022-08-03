// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
//                                                                            //
//                              #@@@@@@@@@@@@&,                               //
//                      .@@@@@   .@@@@@@@@@@@@@@@@@@@*                        //
//                  %@@@,    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@                    //
//               @@@@     @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@                 //
//             @@@@     @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@               //
//           *@@@#    .@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@             //
//          *@@@%    &@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@            //
//          @@@@     @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@           //
//          @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@           //
//                                                                            //
//          (@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@,           //
//          (@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@,           //
//                                                                            //
//               @@   @@     @   @      @       @   @       @                 //
//               @@   @@    @@@ @@@    @_@     @@@ @@@     @@@                //
//                &@@@@   @@  @@  @@ @@ ^ @@  @@  @@  @@   @@@                //
//                                                                            //
//          @@@@@      @@@%    *@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@           //
//          @@@@@      @@@@    %@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@           //
//          .@@@@      @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@            //
//            @@@@@  &@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@             //
//                (&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&(                 //
//                                                                            //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { VaultStorage } from "../storage/VaultStorage.sol";
import { BaseVault } from "../base/BaseVault.sol";
import { ISwapRouter } from "../interfaces/ISwapRouter.sol";
import { IStakingRewards } from "../interfaces/IStakingRewards.sol";
import { IPoolCommitter } from "../interfaces/IPoolCommitter.sol";
import { IGlpManager } from "../interfaces/IGlpManager.sol";
import { IRewardRouterV2 } from "../interfaces/IRewardRouterV2.sol";
import { IGlpPricing } from "../interfaces/IGlpPricing.sol";
import { ITcrPricing } from "../interfaces/ITcrPricing.sol";
import { ITcrStrategy } from "../interfaces/ITcrStrategy.sol";
import { IChainlinkWrapper } from "../interfaces/IChainlinkWrapper.sol";
import { Vault } from "../libraries/Vault.sol";
import { ShareMath } from "../libraries/ShareMath.sol";
import { L2Encoder } from "../lib/L2Encoder.sol";

/// @title Delta Minimised GLP-USDC Vault
/// @author 0xtoki
contract GlpUSDCVault is BaseVault, VaultStorage {
    using SafeERC20 for IERC20;

    /************************************************
     *  STORAGE
     ***********************************************/

    /// @notice the timestamp migration window
    uint256 public migrationTimestamp;

    /// @notice slippage amount for closing a glp position
    uint256 public glpCloseSlippage;

    /// @notice tcr staking active
    bool public hedgeStakingActive;

    /// @notice contract library used for pricing glp
    address public glpPricing;

    /// @notice contract library address used for pricing the tcr hedges
    address public hedgePricing;

    /// @notice tcr emission strategy
    address public tcrStrategy;

    /// @notice glp reward router
    uint256 public swapSlippage;

    /// @notice GLP_MANAGER is used for managing GMX Liquidity
    /// https://github.com/gmx-io/gmx-contracts/blob/master/contracts/core/GlpManager.sol
    address public GLP_MANAGER;

    /// @notice GLP_REWARD_ROUTER is used for minting, burning and handling GLP and rewards earnt
    /// https://github.com/gmx-io/gmx-contracts/blob/master/contracts/staking/RewardRouterV2.sol
    address public GLP_REWARD_ROUTER;

    /// @notice tcr token
    address public TCR = 0xA72159FC390f0E3C6D415e658264c7c4051E9b87;

    /// @notice wrapper for the chainlink oracle used for swap pricing
    IChainlinkWrapper public chainlinkOracle;

    /// @notice shortMint commit type for minting shorts in Tracer Finance
    IPoolCommitter.CommitType public shortMint = IPoolCommitter.CommitType.ShortMint;

    /// @notice shortBurn commit type for burning shorts in Tracer Finance
    IPoolCommitter.CommitType public shortBurn = IPoolCommitter.CommitType.ShortBurn;

    /// @notice Tracer Finance encoder used for encoding paramsfor short burns/mints
    /// https://github.com/tracer-protocol/perpetual-pools-contracts/blob/pools-v2/contracts/implementation/L2Encoder.sol
    L2Encoder public encoder;

    /// @notice UniV3 router for calling swaps
    /// https://github.com/Uniswap/v3-periphery/blob/main/contracts/SwapRouter.sol
    ISwapRouter public router;

    /// @notice hedge actions for rebalancing
    enum HedgeAction {
        increase,
        decrease,
        flat
    }

    /// @dev MAX INT
    uint256 public constant MAX_INT = 2**256 - 1;

    /************************************************
     *  EVENTS
     ***********************************************/

    event UpdatePricePerShare(uint104 _round, uint256 _pricePerShare);

    event CommitAndClose(
        uint104 _round,
        uint256 _timestamp,
        uint256 _profitAmount,
        uint256 _glpAllocation,
        uint256 _sbtcAllocation,
        uint256 _sethAllocation
    );

    event RollToNextPosition(uint256 _lockedInStrategy, uint256 _queuedWithdrawAmount);

    event TracerOpen(uint256 _sbtcAllocation, uint256 _sethAllocation);

    event TracerClose(uint256 _sbtcAllocation, uint256 _sethAllocation);

    event InitiateVaultMigration(uint256 _timestamp, uint256 _migrationActiveTimestamp);

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    /**
     * @notice Consttuctor
     * @param _asset is the underlying asset deposited to the vault
     * @param _feeRecipient is the recipient of the fees generated by the vault
     * @param _keeper the vault keeper
     * @param _managementFee vault management fee
     * @param _performanceFee performance fee
     * @param _depositFee deposit fee
     * @param _vaultParams vault params
     * @param _glpRouter glp reward router
     * @param _glpManager glp manager
     * @param _uniswapRouter uniV3 router
     */
    constructor(
        address _asset,
        address _feeRecipient,
        address _keeper,
        uint256 _managementFee,
        uint256 _performanceFee,
        uint256 _depositFee,
        uint104 _vaultRound,
        Vault.VaultParams memory _vaultParams,
        address _glpRouter,
        address _glpManager,
        address _uniswapRouter
    )
        BaseVault(
            _asset,
            _feeRecipient,
            _keeper,
            _managementFee,
            _performanceFee,
            _depositFee,
            _vaultRound,
            _vaultParams,
            "glpUSDC",
            "glpUSDC"
        )
    {
        require(_glpManager != address(0), "!_glpManager");
        require(_glpRouter != address(0), "!_glpRouter");
        require(_uniswapRouter != address(0), "!_uniswapRouter");
        require(_vaultParams.hedgePricing != address(0), "!hedgePricing");
        require(_vaultParams.glpPricing != address(0), "!glpPricing");

        encoder = new L2Encoder();
        roundPricePerShare[_vaultRound] = ShareMath.pricePerShare(
            totalSupply(),
            IERC20(_vaultParams.asset).balanceOf(address(this)),
            _vaultParams.decimals
        );

        GLP_MANAGER = _glpManager;
        GLP_REWARD_ROUTER = _glpRouter;
        router = ISwapRouter(_uniswapRouter);
        hedgePricing = _vaultParams.hedgePricing;
        glpPricing = _vaultParams.glpPricing;
        hedgeStakingActive = false;
        swapSlippage = 100; // 10%
        glpCloseSlippage = 3; // 0.3%
        migrationTimestamp = MAX_INT;
    }

    /************************************************
     *  VAULT OPERATIONS
     ***********************************************/

    /**
     * @notice Completes a scheduled withdrawal from a past round. Uses finalized pps for the round
     */
    function completeWithdraw() external nonReentrant {
        uint256 withdrawAmount = _completeWithdraw();
        lastQueuedWithdrawAmount = uint128(uint256(lastQueuedWithdrawAmount) - withdrawAmount);
    }

    /**
     * @notice Marks the close of the existing vault round and sets the allocations for the next round.
     * This function will, if required to accomadate the new hedge sizing, close some of the GLP position to USDC.
     * @param nextSbtcAllocation the allocation to sbtc for the next epoch in usdc
     * @param nextSethAllocation the allocation to seth for the next epoch in usdc
     * @param nextGlpAllocation the allocation to glp for the next epoch in usdc
     * @param _settlePositions whether the vault should settle positions this epoch
     * @param _handleTcrEmissions whether the vault should handle the tcr emissions this epoch
     * @return profit the profit amount made from claiming rewards
     */
    function commitAndClose(
        uint112 nextSbtcAllocation,
        uint112 nextSethAllocation,
        uint112 nextGlpAllocation,
        bool _settlePositions,
        bool _handleTcrEmissions
    ) external nonReentrant onlyKeeper returns (uint256) {
        // get the existing glp balance and allocation in USDC
        uint256 glpBal = IERC20(vaultParams.stakedGlp).balanceOf(address(this));
        uint256 existingGlpAllocation = IGlpPricing(glpPricing).glpToUsd(glpBal, false);

        // set next allocations
        strategyState.nextSbtcAllocation = nextSbtcAllocation;
        strategyState.nextSethAllocation = nextSethAllocation;
        strategyState.nextGlpAllocation = nextGlpAllocation;

        vaultState.lastLockedAmount = uint104(lockedInStrategy);
        uint256 profitAmount = 0;

        // unstake tracer hedges and handle emissions
        if (
            (strategyState.activeSbtcAllocation > 0 || strategyState.activeSethAllocation > 0) &&
            hedgeStakingActive &&
            _handleTcrEmissions
        ) {
            profitAmount += collectTcrEmissions();
        }

        // start late withdrawal period
        lateWithdrawPeriod = true;

        // settle glp
        if (_settlePositions) {
            if (existingGlpAllocation > nextGlpAllocation) {
                profitAmount += settleGlpPosition(existingGlpAllocation - nextGlpAllocation);
                strategyState.activeGlpAllocation = nextGlpAllocation;
            } else {
                profitAmount += handleGlpRewards();
            }
        }
        uint256 sEthVal = ITcrPricing(hedgePricing).sEthToUsd(totalSethBalance());
        uint256 sBtcVal = ITcrPricing(hedgePricing).sBtcToUsd(totalSbtcBalance());

        emit CommitAndClose(
            vaultState.round,
            block.timestamp,
            profitAmount,
            IGlpPricing(glpPricing).glpToUsd(glpBal, false),
            sBtcVal,
            sEthVal
        );
        return profitAmount;
    }

    /**
     * @notice Rolls the vault's funds into a new strategy position.
     * Same decimals as `asset` this function should be called immediatly after the short positions have been committed and minted
     */
    function rollToNextPosition() external onlyKeeper nonReentrant {
        // claim short tokens
        claimShorts();
        // stake tracer hedge
        if (hedgeStakingActive) stakeHedges();
        // get the next glp allocation
        uint256 nextGlpAllocation = strategyState.nextGlpAllocation;

        // get the vaults next round params
        (uint256 lockedBalance, uint256 queuedWithdrawAmount) = _rollToNextEpoch(
            uint256(lastQueuedWithdrawAmount),
            uint256(roundQueuedWithdrawalShares[vaultState.round]),
            totalAssets()
        );

        // get new queued withdrawal shares before rollover
        uint256 newQueuedWithdrawShares = uint256(vaultState.queuedWithdrawShares) +
            roundQueuedWithdrawalShares[vaultState.round - 1];

        ShareMath.assertUint128(newQueuedWithdrawShares);

        vaultState.queuedWithdrawShares = uint128(newQueuedWithdrawShares);

        // set globals
        lastQueuedWithdrawAmount = uint128(queuedWithdrawAmount);
        lockedInStrategy = lockedBalance;

        uint256 sbtcAllocation = strategyState.activeSbtcAllocation;
        uint256 sethAllocation = strategyState.activeSethAllocation;
        uint256 existingGlpPosition = IGlpPricing(glpPricing).glpToUsd(
            IERC20(vaultParams.stakedGlp).balanceOf(address(this)),
            false
        );

        uint256 totalUtilised = sbtcAllocation + sethAllocation + nextGlpAllocation + lastQueuedWithdrawAmount;
        require(totalUtilised <= totalAssets(), "TCRGMX: !allocation");

        if (nextGlpAllocation > existingGlpPosition) openGlpPosition(nextGlpAllocation - existingGlpPosition);

        emit RollToNextPosition(lockedInStrategy, lastQueuedWithdrawAmount);
    }

    /**
     * @notice withdraws funds from GMX in GLP, claiming the rewards and executing any swaps. 
     * This is done in the case some capital is needed to open new hedges or cover next round withdrawals.
     * @param glpAllocation value in usdc to be settled in glp
     * @return amount of asset received in profit at the end of the epoch
     */
    function settleGlpPosition(uint256 glpAllocation) internal returns (uint256) {
        // usd to glp at current price
        uint256 glpAmount = IGlpPricing(glpPricing).usdToGlp(glpAllocation, false);

        // subtract 0.3% buffer for onchain mispricing
        glpAmount -= (glpAmount * glpCloseSlippage) / SCALE;

        // burn glp amount
        IRewardRouterV2(GLP_REWARD_ROUTER).unstakeAndRedeemGlp(vaultParams.asset, glpAmount, 0, address(this));

        // handle glp rewards and return profit in usdc, add tcr yield when built
        return handleGlpRewards();
    }

    /**
     * @notice deposits and stakes glpAllocation in GLP
     * @param glpAllocation value in usdc to mint GLP
     */
    function openGlpPosition(uint256 glpAllocation) public onlyKeeper {
        IERC20(vaultParams.asset).safeIncreaseAllowance(GLP_MANAGER, glpAllocation);
        uint256 amountWithSlippage = getSlippageAdjustedAmount(glpAllocation, 10);
        IRewardRouterV2(GLP_REWARD_ROUTER).mintAndStakeGlp(vaultParams.asset, glpAllocation, amountWithSlippage, 0);
    }

    /**
     * @notice uses the allocations passed in or the vault state to queue a rebalance of the tracer hedges
     * @param sbtcAllocation usdc allocation for sbtc
     * @param sethAllocation usdc allocation for seth
     * @param sethAction action to rebalance seth
     * @param sbtcAction action to rebalance sbtc
     */
    function queueHedgeRebalance(
        uint256 sbtcAllocation,
        uint256 sethAllocation,
        HedgeAction sethAction,
        HedgeAction sbtcAction
    ) external onlyKeeper nonReentrant {
        uint256 sEthChange;
        uint256 sBtcChange;
        (, uint256 queuedWithdrawAmount) = getNextLockedQueued();
        uint256 availableBal = IERC20(vaultParams.asset).balanceOf(address(this)) - queuedWithdrawAmount;

        uint256 sEthVal = ITcrPricing(hedgePricing).sEthToUsd(totalSethBalance());
        uint256 sBtcVal = ITcrPricing(hedgePricing).sBtcToUsd(totalSbtcBalance());

        if (sethAction == HedgeAction.increase) {
            require(sethAllocation >= sEthVal, "TCRGMX: !allocation");
            sEthChange = sethAllocation - sEthVal;
            require(availableBal > sEthChange, "TCRGMX: Over allocation");
            strategyState.activeSethAllocation = sethAllocation;
            queueTracerOpen(0, sEthChange);
        } else if (sethAction == HedgeAction.decrease) {
            require(sethAllocation <= sEthVal, "TCRGMX: !allocation");
            sEthChange = sEthVal - sethAllocation;
            uint256 sEthAmount = ITcrPricing(hedgePricing).usdToSeth(sEthChange);
            strategyState.activeSethAllocation = sethAllocation;
            if (hedgeStakingActive) unstakePartialHedges(0, sEthAmount);
            queueTracerClose(0, sEthAmount);
        }

        if (sbtcAction == HedgeAction.increase) {
            require(sbtcAllocation >= sBtcVal, "TCRGMX: !allocation");
            sBtcChange = sbtcAllocation - sBtcVal;
            availableBal = IERC20(vaultParams.asset).balanceOf(address(this)) - queuedWithdrawAmount;
            require(availableBal > sBtcChange, "TCRGMX: Over allocation");
            strategyState.activeSbtcAllocation = sbtcAllocation;
            queueTracerOpen(sBtcChange, 0);
        } else if (sbtcAction == HedgeAction.decrease) {
            require(sbtcAllocation <= sBtcVal, "TCRGMX: !allocation");
            sBtcChange = sBtcVal - sbtcAllocation;
            uint256 sBtcAmount = ITcrPricing(hedgePricing).usdToSbtc(sBtcChange);
            strategyState.activeSbtcAllocation = sbtcAllocation;
            if (hedgeStakingActive) unstakePartialHedges(sBtcAmount, 0);
            queueTracerClose(sBtcAmount, 0);
        }
    }

    /**
     * @notice This function withdraws tracer shorts from staking and queues them for closing on the next rebalance
     * @param sbtcAllocation amount of sbtc tokens to burn
     * @param sethAllocation amount of seth tokens to burn
     */
    function queueTracerClose(uint256 sbtcAllocation, uint256 sethAllocation) public onlyKeeper {
        uint256 ethLeverageindex = strategyState.activeEthLeverageIndex;
        uint256 btcLeverageIndex = strategyState.activeBtcLeverageIndex;
        uint256 sEthBal = IERC20(ethLeverageSets[ethLeverageindex].token).balanceOf(address(this));
        uint256 sBtcBal = IERC20(btcLeverageSets[btcLeverageIndex].token).balanceOf(address(this));
        require(sBtcBal >= sbtcAllocation, "TCRGMX: !available sbtc balance");
        require(sEthBal >= sethAllocation, "TCRGMX: !available seth balance");

        if (sbtcAllocation != 0) {
            IERC20(btcLeverageSets[btcLeverageIndex].token).safeIncreaseAllowance(
                btcLeverageSets[btcLeverageIndex].leveragePool,
                sbtcAllocation
            );
            IPoolCommitter(btcLeverageSets[btcLeverageIndex].poolCommitter).commit(
                encoder.encodeCommitParams(sbtcAllocation, shortBurn, false, false)
            );
        }
        if (sethAllocation != 0) {
            IERC20(ethLeverageSets[ethLeverageindex].token).safeIncreaseAllowance(
                ethLeverageSets[ethLeverageindex].leveragePool,
                sethAllocation
            );
            IPoolCommitter(ethLeverageSets[ethLeverageindex].poolCommitter).commit(
                encoder.encodeCommitParams(sethAllocation, shortBurn, false, false)
            );
        }

        emit TracerClose(sbtcAllocation, sethAllocation);
    }

    /**
     * @notice This function withdraws tracer shorts from staking and queues them for closing on the next rebalance
     * @param sbtcAllocation usdc amount to open in sbtc
     * @param sethAllocation usdc amount to open in seth
     */
    function queueTracerOpen(uint256 sbtcAllocation, uint256 sethAllocation) public onlyKeeper {
        uint256 usdcBal = IERC20(vaultParams.asset).balanceOf(address(this)) - lastQueuedWithdrawAmount;
        require(sethAllocation + sbtcAllocation <= usdcBal, "TCRGMX: !available balance");
        uint256 ethLeverageindex = strategyState.activeEthLeverageIndex;
        uint256 btcLeverageIndex = strategyState.activeBtcLeverageIndex;

        // mint hedges
        if (sbtcAllocation != 0) {
            IERC20(vaultParams.asset).safeIncreaseAllowance(btcLeverageSets[btcLeverageIndex].leveragePool, sbtcAllocation);
            IPoolCommitter(btcLeverageSets[btcLeverageIndex].poolCommitter).commit(
                encoder.encodeCommitParams(sbtcAllocation, shortMint, false, false)
            );
        }
        if (sethAllocation != 0) {
            IERC20(vaultParams.asset).safeIncreaseAllowance(ethLeverageSets[ethLeverageindex].leveragePool, sethAllocation);
            IPoolCommitter(ethLeverageSets[ethLeverageindex].poolCommitter).commit(
                encoder.encodeCommitParams(sethAllocation, shortMint, false, false)
            );
        }
        emit TracerOpen(sbtcAllocation, sethAllocation);
    }

    /**
     * @notice Handle the GLP rewards according to the strategy. Claim esGMX + multiplier points and stake.
     * Claim WETH and swap to USDC paid as profit to the vault
     * @return profit the amount of USDC recieved in exchange for the WETH claimed
     */
    function handleGlpRewards() internal returns (uint256) {
        IRewardRouterV2(GLP_REWARD_ROUTER).handleRewards(true, true, true, true, true, true, false);
        return swapToStable();
    }

    /**
     * @notice Swaps the WETH claimed from the strategy to USDC
     * @return recieved amount of USDC recieved
     */
    function swapToStable() internal returns (uint256) {
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        if (wethBalance > 0) {
            uint256 ethPrice = chainlinkOracle.getCurrentPrice(WETH);
            uint256 minOut = (ethPrice * wethBalance) / 1e30; // USDC decimals convertion
            IERC20(WETH).safeIncreaseAllowance(address(router), wethBalance);
            uint24 poolFee = 500;
            bytes memory route = abi.encodePacked(WETH, poolFee, vaultParams.asset);
            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                path: route,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wethBalance,
                amountOutMinimum: getSlippageAdjustedAmount(minOut, swapSlippage)
            });
            return router.exactInput(params);
        }
        return 0;
    }

    /**
     * @notice Total asset value in the vault. Valued in USDC. This call will under report assets held in the vault
     * when commits to Tracer Finance are pending
     * @return totalBal the total balance of the assets held
     */
    function totalAssets() public view returns (uint256 totalBal) {
        uint256 usdcBal = IERC20(vaultParams.asset).balanceOf(address(this));
        uint256 glpBal = IERC20(vaultParams.stakedGlp).balanceOf(address(this));
        uint256 sEthBal = totalSethBalance();
        uint256 sBtcBal = totalSbtcBalance();
        totalBal =
            usdcBal +
            IGlpPricing(glpPricing).glpToUsd(glpBal, false) +
            ITcrPricing(hedgePricing).sEthToUsd(sEthBal) +
            ITcrPricing(hedgePricing).sBtcToUsd(sBtcBal);
    }

    /**
     * @notice Returns the total balance of seth held by the vault
     * @return balance of seth
     */
    function totalSethBalance() public view returns (uint256) {
        uint256 sEthBal = IERC20(ethLeverageSets[strategyState.activeEthLeverageIndex].token).balanceOf(address(this));
        if (hedgeStakingActive) {
            return sEthBal + IStakingRewards(vaultParams.sethStake).balanceOf(address(this));
        }
        return sEthBal;
    }

    /**
     * @notice Returns the total balance of sbtc held by the vault
     * @return balance of sbtc
     */
    function totalSbtcBalance() public view returns (uint256) {
        uint256 sBtcBal = IERC20(btcLeverageSets[strategyState.activeBtcLeverageIndex].token).balanceOf(address(this));
        if (hedgeStakingActive) {
            return sBtcBal + IStakingRewards(vaultParams.sbtcStake).balanceOf(address(this));
        }
        return sBtcBal;
    }

    /**
     * @notice Returns a slippage adjusted amount for calculations where slippage is accounted
     * @param amount of the asset
     * @param slippage %
     * @return value of the slippage adjusted amount
     */
    function getSlippageAdjustedAmount(uint256 amount, uint256 slippage) internal view returns (uint256) {
        return (amount * (1 * SCALE - slippage)) / SCALE;
    }

    /**
     * @notice Returns the next locked and withdrawal amount queued
     * @return lockedBalance that is available for use in the strategy next epoch
     * @return queuedWithdrawAmount next withdrawal amount queued
     */
    function getNextLockedQueued() public view returns (uint256 lockedBalance, uint256 queuedWithdrawAmount) {
        (lockedBalance, queuedWithdrawAmount) = previewNextBalances(
            uint256(lastQueuedWithdrawAmount),
            roundQueuedWithdrawalShares[vaultState.round],
            totalAssets()
        );
    }

    /**
     * @notice Sets the active leverage index to be used if configured for a different leverage multiplier
     * @param _btcLeverageSet the index for btc leverage set
     * @param _ethLeverageSet the index for eth leverage set
     */
    function setLeverageSetIndex(uint256 _btcLeverageSet, uint256 _ethLeverageSet) external onlyAdmin {
        require(btcLeverageSets[_btcLeverageSet].poolCommitter != address(0), "TCRGMX: btc leverage set");
        require(ethLeverageSets[_ethLeverageSet].poolCommitter != address(0), "TCRGMX: eth leverage set");
        strategyState.activeBtcLeverageIndex = _btcLeverageSet;
        strategyState.activeEthLeverageIndex = _ethLeverageSet;
    }

    /**
     * @notice Updates the slippage tolerance for swapping rewards to USDC
     * @param _newSlippage the new slippage tolerance
     */
    function updateSwapSlippage(uint256 _newSlippage) external onlyAdmin {
        require(_newSlippage != 0, "TCRGMX: ! _newSlippage is zero");
        swapSlippage = _newSlippage;
    }

    /**
     * @notice Updates the chainlink oracle wrapper implementation
     * @param _chainlinkWrapper the address of the new implementation
     */
    function updateChainlinkWrapper(address _chainlinkWrapper) external onlyAdmin {
        require(_chainlinkWrapper != address(0), "TCRGMX: ! chainlinkWrapper address");
        chainlinkOracle = IChainlinkWrapper(_chainlinkWrapper);
    }

    /**
     * @notice Updates the hedge pricing implementation for Tracer Finance
     * @param _hedgePricing the address of the new implementation
     */
    function updateHedgePricing(address _hedgePricing) external onlyAdmin {
        require(_hedgePricing != address(0), "TCRGMX: ! hedgePricing address");
        hedgePricing = _hedgePricing;
    }

    /**
     * @notice Updates the GLP pricing implementation
     * @param _glpPricing the address of the new implementation
     */
    function updateGlpPricing(address _glpPricing) external onlyAdmin {
        require(_glpPricing != address(0), "TCRGMX: ! glpPricing address");
        glpPricing = _glpPricing;
    }

    /**
     * @notice Updates the seth staking contract address for TCR emissions
     * @param _sethStaking the new staking contract
     */
    function updateSethStaking(address _sethStaking) external onlyAdmin {
        require(_sethStaking != address(0), "TCRGMX: ! seth address");
        vaultParams.sethStake = _sethStaking;
    }

    /**
     * @notice Updates the sbtc staking contract address for TCR emissions
     * @param _sbtcStaking the new staking contract
     */
    function updateSbtcStaking(address _sbtcStaking) external onlyAdmin {
        require(_sbtcStaking != address(0), "TCRGMX: ! sbtc address");
        vaultParams.sbtcStake = _sbtcStaking;
    }

    /**
     * @notice Updates the TCR emissions token strategy for how the vault should handle emissions
     * @param _tcrStrategy the new strategy address
     */
    function setTcrStrategy(address _tcrStrategy) external onlyAdmin {
        tcrStrategy = _tcrStrategy;
    }

    /**
     * @notice Sets the Tracer Finance hedge staking
     * @param _stakingActive the value to set it to
     */
    function setHedgeStakingActive(bool _stakingActive) external onlyAdmin {
        hedgeStakingActive = _stakingActive;
    }

    /**
     * @notice Claims the short tokens from Tracer Finance
     */
    function claimShorts() public onlyKeeper {
        uint256 ethLeverageindex = strategyState.activeEthLeverageIndex;
        uint256 btcLeverageindex = strategyState.activeBtcLeverageIndex;
        IPoolCommitter(ethLeverageSets[ethLeverageindex].poolCommitter).claim(address(this));
        IPoolCommitter(btcLeverageSets[btcLeverageindex].poolCommitter).claim(address(this));
    }

    /**
     * @notice Stakes the short tokens in the emissions contract
     */
    function stakeHedges() internal {
        uint256 ethLeverageindex = strategyState.activeEthLeverageIndex;
        uint256 btcLeverageindex = strategyState.activeBtcLeverageIndex;
        uint256 sEthBal = IERC20(ethLeverageSets[ethLeverageindex].token).balanceOf(address(this));
        uint256 sBtcBal = IERC20(btcLeverageSets[btcLeverageindex].token).balanceOf(address(this));

        if (sEthBal > 0) {
            IERC20(ethLeverageSets[ethLeverageindex].token).safeIncreaseAllowance(vaultParams.sethStake, sEthBal);
            IStakingRewards(vaultParams.sethStake).stake(sEthBal);
        }
        if (sBtcBal > 0) {
            IERC20(btcLeverageSets[btcLeverageindex].token).safeIncreaseAllowance(vaultParams.sbtcStake, sBtcBal);
            IStakingRewards(vaultParams.sbtcStake).stake(sBtcBal);
        }
    }

    /**
     * @notice Collect Tcr emissions from the staking contract
     * @return profit in USDC recieved from TCR emissions
     */
    function collectTcrEmissions() internal returns (uint256) {
        IStakingRewards(vaultParams.sbtcStake).getReward();
        IStakingRewards(vaultParams.sethStake).getReward();
        uint256 tcrBalance = IERC20(TCR).balanceOf(address(this));
        if (tcrStrategy != address(0) && tcrBalance > 0) {
            IERC20(TCR).safeIncreaseAllowance(tcrStrategy, tcrBalance);
            return ITcrStrategy(tcrStrategy).handleTcr(tcrBalance);
        }
        return 0;
    }

    /**
     * @notice Unstakes the short tokens from the emissions contract
     */
    function unstakePartialHedges(uint256 _sbtcAmount, uint256 _sethAmount) public onlyKeeper {
        if (_sbtcAmount > 0) IStakingRewards(vaultParams.sbtcStake).withdraw(_sbtcAmount);
        if (_sethAmount > 0) IStakingRewards(vaultParams.sethStake).withdraw(_sethAmount);
    }

    /**
     * @notice Unstakes the short tokens from the emissions contract
     */
    function unstakeAllHedges() public onlyKeeper {
        IStakingRewards(vaultParams.sbtcStake).exit();
        IStakingRewards(vaultParams.sethStake).exit();
    }

    /**
     * @notice Initiates the vault migration of multiplier points and esGMX to a new vault
     * a 14 day grace period is given to warn users this has been triggered
     */
    function initiateMigration() public onlyAdmin {
        require(migrationTimestamp == MAX_INT, "already initiated");
        migrationTimestamp = block.timestamp + 14 days;
        emit InitiateVaultMigration(block.timestamp, migrationTimestamp);
    }

    /**
     * @notice Calls the migration of the esGMX and multiplier points to a new vault
     * @param _receiver the address to migrate to
     */
    function migrateVault(address _receiver) public onlyAdmin {
        require(tx.origin == msg.sender, "onlyEOA");
        require(block.timestamp > migrationTimestamp, "migration not ready");
        IRewardRouterV2(GLP_REWARD_ROUTER).signalTransfer(_receiver);
    }

    /**
     * @notice Revoke allowances to all external contracts
     */
    function revokeAllowances() public onlyAdmin {
        uint256 ethLeverageindex = strategyState.activeEthLeverageIndex;
        uint256 btcLeverageindex = strategyState.activeBtcLeverageIndex;
        IERC20(ethLeverageSets[ethLeverageindex].token).approve(vaultParams.sethStake, 0);
        IERC20(btcLeverageSets[btcLeverageindex].token).approve(vaultParams.sbtcStake, 0);
        IERC20(vaultParams.asset).approve(btcLeverageSets[btcLeverageindex].leveragePool, 0);
        IERC20(vaultParams.asset).approve(ethLeverageSets[ethLeverageindex].leveragePool, 0);
        IERC20(WETH).approve(address(router), 0);
        IERC20(vaultParams.asset).approve(GLP_MANAGER, 0);
    }
}