// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vault } from "./Vault.sol";
import { ShareMath } from "./ShareMath.sol";

library VaultLifecycle {
    /**
     * @param decimals is the decimals of the asset
     * @param totalBalance is the total value held by the vault priced in USDC
     * @param currentShareSupply is the supply of the shares invoked with totalSupply()
     * @param lastQueuedWithdrawAmount is the amount queued for withdrawals from all rounds excluding the last
     * @param currentQueuedWithdrawShares is the amount queued for withdrawals from last round
     * @param performanceFee is the performance fee percent
     * @param managementFee is the management fee percent
     * @param epochsElapsed is the number of epochs elapsed measured by the duration
     */
    struct RolloverParams {
        uint256 decimals;
        uint256 totalBalance;
        uint256 currentShareSupply;
        uint256 lastQueuedWithdrawAmount;
        uint256 currentQueuedWithdrawShares;
        uint256 performanceFee;
        uint256 managementFee;
        uint256 epochsElapsed;
    }

    /**
     * @notice Calculate the new price per share and
      amount of funds to re-allocate as collateral for the new epoch
     * @param vaultState is the storage variable vaultState
     * @param params is the rollover parameters passed to compute the next state
     * @return newLockedAmount is the amount of funds to allocate for the new round
     * @return queuedWithdrawAmount is the amount of funds set aside for withdrawal
     * @return newPricePerShare is the price per share of the new round
     * @return performanceFeeInAsset is the performance fee charged by vault
     * @return totalVaultFee is the total amount of fee charged by vault
     */
    function rollover(Vault.VaultState storage vaultState, RolloverParams calldata params)
        external
        view
        returns (
            uint256 newLockedAmount,
            uint256 queuedWithdrawAmount,
            uint256 newPricePerShare,
            uint256 performanceFeeInAsset,
            uint256 totalVaultFee
        )
    {
        uint256 currentBalance = params.totalBalance;
        // Total amount of queued withdrawal shares from previous rounds (doesn't include the current round)
        uint256 lastQueuedWithdrawShares = vaultState.queuedWithdrawShares;
        uint256 epochManagementFee = params.epochsElapsed > 0 ? params.managementFee * params.epochsElapsed : params.managementFee;

        // Deduct older queued withdraws so we don't charge fees on them
        uint256 balanceForVaultFees = currentBalance - params.lastQueuedWithdrawAmount;

        {
            // no performance fee on first round
            balanceForVaultFees = vaultState.round == 1 ? vaultState.totalPending : balanceForVaultFees;

            (performanceFeeInAsset, , totalVaultFee) = VaultLifecycle.getVaultFees(
                balanceForVaultFees,
                vaultState.lastLockedAmount,
                vaultState.totalPending,
                params.performanceFee,
                epochManagementFee
            );
        }

        // Take into account the fee
        // so we can calculate the newPricePerShare
        currentBalance = currentBalance - totalVaultFee;

        {
            newPricePerShare = ShareMath.pricePerShare(
                params.currentShareSupply - lastQueuedWithdrawShares,
                currentBalance - params.lastQueuedWithdrawAmount,
                params.decimals
            );

            queuedWithdrawAmount =
                params.lastQueuedWithdrawAmount +
                ShareMath.sharesToAsset(params.currentQueuedWithdrawShares, newPricePerShare, params.decimals);
        }

        return (
            currentBalance - queuedWithdrawAmount, // new locked balance subtracts the queued withdrawals
            queuedWithdrawAmount,
            newPricePerShare,
            performanceFeeInAsset,
            totalVaultFee
        );
    }

    /**
     * @notice Calculates the performance and management fee for this round
     * @param currentBalance is the balance of funds held on the vault after closing short
     * @param lastLockedAmount is the amount of funds locked from the previous round
     * @param pendingAmount is the pending deposit amount
     * @param performanceFeePercent is the performance fee pct.
     * @param managementFeePercent is the management fee pct.
     * @return performanceFeeInAsset is the performance fee
     * @return managementFeeInAsset is the management fee
     * @return vaultFee is the total fees
     */
    function getVaultFees(
        uint256 currentBalance,
        uint256 lastLockedAmount,
        uint256 pendingAmount,
        uint256 performanceFeePercent,
        uint256 managementFeePercent
    )
        internal
        pure
        returns (
            uint256 performanceFeeInAsset,
            uint256 managementFeeInAsset,
            uint256 vaultFee
        )
    {
        // At the first round, currentBalance=0, pendingAmount>0
        // so we just do not charge anything on the first round
        uint256 lockedBalanceSansPending = currentBalance > pendingAmount ? currentBalance - pendingAmount : 0;

        uint256 _performanceFeeInAsset;
        uint256 _managementFeeInAsset;
        uint256 _vaultFee;

        // Take performance fee ONLY if difference between
        // last epoch and this epoch's vault deposits, taking into account pending
        // deposits and withdrawals, is positive. If it is negative, last round
        // was not profitable and the vault took a loss on assets
        if (lockedBalanceSansPending > lastLockedAmount) {
            _performanceFeeInAsset = performanceFeePercent > 0
                ? ((lockedBalanceSansPending - lastLockedAmount) * performanceFeePercent) / (100 * Vault.FEE_MULTIPLIER)
                : 0;
        }
        // Take management fee on each epoch
        _managementFeeInAsset = managementFeePercent > 0
            ? (lockedBalanceSansPending * managementFeePercent) / (100 * Vault.FEE_MULTIPLIER)
            : 0;

        _vaultFee = _performanceFeeInAsset + _managementFeeInAsset;

        return (_performanceFeeInAsset, _managementFeeInAsset, _vaultFee);
    }
}