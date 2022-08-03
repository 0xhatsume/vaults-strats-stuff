// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

import { Vault } from "../libraries/Vault.sol";

abstract contract VaultStorage {
    // usdc value locked in delta neutral strategy
    uint256 public lockedInStrategy;
    // Amount locked for scheduled withdrawals last week;
    uint128 public lastQueuedWithdrawAmount;
}