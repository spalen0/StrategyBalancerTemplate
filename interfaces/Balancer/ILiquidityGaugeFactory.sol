// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface ILiquidityGaugeFactory {
    // Gets the gauge for a given pool.
    function getPoolGauge(address pool) external view returns (address);
}