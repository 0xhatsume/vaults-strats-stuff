// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

interface IGlpPricing {
    function setPrice(uint256 _glpPrice) external;

    function glpPrice(bool _buy) external view returns (uint256);

    function usdToGlp(uint256 usdAmount, bool maximise) external view returns (uint256);

    function glpToUsd(uint256 glpAmount, bool maximise) external view returns (uint256);
}