// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IGauge {
    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);


    /**
     * @notice Claim available reward tokens for `_addr`
     * @param _addr Address to claim for
     * @param _receiver Address to transfer rewards to - if set to
     *                  ZERO_ADDRESS, uses the default reward receiver
     *                  for the caller
     */
    function claim_rewards(address _addr, address _receiver) external;

    // The address of the LP token that may be deposited into the gauge.
    function lp_token() external view returns (address);

    function rewarded_token() external returns (address);

    // Number of rewards tokens.
    function reward_count() external view returns (uint256);

    // Address of a reward token at a given index.
    function reward_tokens(uint256 index) external view returns (address);
}