// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

interface IChainlinkWrapper {
    function getExternalPrice(address _token) external view returns (uint256);

    function getLastPrice(address _token) external view returns (uint256);

    function getCurrentPrice(address _token) external view returns (uint256);
}