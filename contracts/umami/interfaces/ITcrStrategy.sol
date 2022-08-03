// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

interface ITcrStrategy {
    function handleTcr(uint256 _amount) external returns (uint256);
}