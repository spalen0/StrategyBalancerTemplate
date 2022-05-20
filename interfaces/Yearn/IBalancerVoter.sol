// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;


interface IBalancerVoter {
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bool, bytes memory);

    function increaseAmountMax(bool) external;
    function increaseAmountExact(uint256, bool) external;
}