// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

interface ITcrPricing {
    function setSEthPrice(uint256 _price) external;

    function setSbtcPrice(uint256 _price) external;

    function sEthPrice() external view returns (uint256);

    function sBtcPrice() external view returns (uint256);

    function sEthToUsd(uint256 sethAmount) external view returns (uint256);

    function sBtcToUsd(uint256 sbtcAmount) external view returns (uint256);

    function usdToSeth(uint256 usd) external view returns (uint256);

    function usdToSbtc(uint256 usd) external view returns (uint256);
}