// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IStrategyVoterProxy {
    function balanceOf(address _gauge) external view returns (uint256);

    function withdraw(
        address _gauge,
        address _token,
        uint256 _amount
    ) external returns (uint256);

    function withdrawAll(address _gauge, address _token) external returns (uint256);

    function deposit(address _gauge, address _token) external;

    function harvest(address _gauge) external;
}