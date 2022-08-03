// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

library Vault {
    // Fees are 6-decimal places. For example: 20 * 10**6 = 20%
    uint256 internal constant FEE_MULTIPLIER = 10**6;

    // Placeholder uint value to prevent cold writes
    uint256 internal constant PLACEHOLDER_UINT = 1;

    struct VaultParams {
        // Token decimals for vault shares
        uint8 decimals;
        // Minimum supply of the vault shares issued, for ETH it's 10**10
        uint56 minimumSupply;
        // Vault cap
        uint104 cap;
        // Vault asset
        address asset;
        // staked glp
        address stakedGlp;
        // esGMX
        address esGMX;
        // glp pricing library
        address glpPricing;
        // tracer hedge pricing library
        address hedgePricing;
        // sbtc tcr emissions staking
        address sbtcStake;
        // seth tcr emissions staking
        address sethStake;
    }

    struct StrategyState {
        // the allocation of sbtc this epoch
        uint256 activeSbtcAllocation;
        // the allocation of seth this epoch
        uint256 activeSethAllocation;
        // the allocation of glp this epoch
        uint256 activeGlpAllocation;
        // The index of the leverage for btc shorts
        uint256 activeBtcLeverageIndex;
        // The index of the leverage for eth shorts
        uint256 activeEthLeverageIndex;
        // the allocation of sbtc next epoch
        uint256 nextSbtcAllocation;
        // the allocation of seth next epoch
        uint256 nextSethAllocation;
        // the allocation of glp next epoch
        uint256 nextGlpAllocation;
    }

    struct VaultState {
        // 32 byte slot 1
        //  Current round number. `round` represents the number of `period`s elapsed.
        uint104 round;
        // Amount that is currently locked for the strategy
        uint104 lockedAmount;
        // Amount that was locked for the strategy
        // used for calculating performance fee deduction
        uint104 lastLockedAmount;
        // 32 byte slot 2
        // Stores the total tally of how much of `asset` there is
        uint128 totalPending;
        // Total amount of queued withdrawal shares from previous rounds not including the current round
        uint128 queuedWithdrawShares;
        // Start time of the last epoch
        uint256 epochStart;
        // Epoch end time
        uint256 epochEnd;
    }

    struct LeverageSet {
        // The tokenised leverage position
        address token;
        // The committer for the leverage position
        address poolCommitter;
        // Leverage pool holding the deposit tokens
        address leveragePool;
    }

    struct Withdrawal {
        // Maximum of 65535 rounds. Assuming 1 round is 7 days, maximum is 1256 years.
        uint16 round;
        // Number of shares withdrawn
        uint128 shares;
    }
}