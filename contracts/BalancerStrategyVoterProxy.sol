// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {IBalancerVoter} from "../interfaces/Yearn/IBalancerVoter.sol";

import {IGauge} from "../interfaces/Balancer/IGauge.sol";

/**
 * @dev Yearn strategies which auto-compound BPT tokens communicate with the Yearn
 * Balancer voter through this contract. We use a proxy because the voter itself holds
 * veBAL, which are locked and prevent us from migrating / upgrading that contract.
 */
contract BalancerStrategyVoterProxy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using SafeVoter for IBalancerVoter;

    event VoterApproved(address voter);
    event VoterRevoked(address voter);
    event LockerApproved(address locker);
    event LockerRevoked(address locker);
    event StrategyApproved(address strategy);
    event StrategyRevoked(address strategy);
    event NewGovernance(address governance);

    IBalancerVoter public voter;

    address public constant balMinter =
        address(0x239e55F427D44C3cc793f49bFB507ebe76638a2b);
    address public constant bal =
        address(0xba100000625a3754423978a60c9317c58a424e3D);
    address public constant gauge =
        address(0xC128468b7Ce63eA702C1f104D55A2566b13D3ABD); // Gauge controller

    // gauge => strategies
    mapping(address => address) public strategies;
    mapping(address => bool) public voters;
    mapping(address => bool) public lockers;
    address public governance;

    constructor(address _voter) public {
        governance = msg.sender;
        voter = IBalancerVoter(_voter);
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
        emit NewGovernance(_governance);
    }

    function approveStrategy(address _gauge, address _strategy) external {
        require(msg.sender == governance, "!governance");
        strategies[_gauge] = _strategy;
        emit StrategyApproved(_strategy);
    }

    function revokeStrategy(address _gauge) external {
        require(msg.sender == governance, "!governance");
        require(strategies[_gauge] != address(0), "!exists");
        address _strategy = strategies[_gauge];
        strategies[_gauge] = address(0);
        emit StrategyRevoked(_strategy);
    }

    function approveVoter(address _voter) external {
        require(msg.sender == governance, "!governance");
        voters[_voter] = true;
        emit VoterApproved(_voter);
    }

    function revokeVoter(address _voter) external {
        require(msg.sender == governance, "!governance");
        voters[_voter] = false;
        emit VoterRevoked(_voter);
    }

    function approveLocker(address _locker) external {
        require(msg.sender == governance, "!governance");
        lockers[_locker] = true;
        emit LockerApproved(_locker);
    }

    function revokeLocker(address _locker) external {
        require(msg.sender == governance, "!governance");
        lockers[_locker] = false;
        emit LockerRevoked(_locker);
    }

    function lock() external {
        voter.increaseAmountMax(false); // Unprotected function shouldn't sell BAL
    }

    function convertAndLockMax() external {
        require(lockers[msg.sender], "!approved");
        voter.increaseAmountMax(true);
    }

    function convertAndLockExact(uint256 _amount) external {
        require(lockers[msg.sender], "!approved");
        if (_amount > 0) voter.increaseAmountExact(_amount, true);
    }

    function vote(address _gauge, uint256 _amount) public {
        require(voters[msg.sender], "!voter");
        voter.safeExecute(
            gauge,
            0,
            abi.encodeWithSignature(
                "vote_for_gauge_weights(address,uint256)",
                _gauge,
                _amount
            )
        );
    }

    function withdraw(
        address _gauge,
        address _token,
        uint256 _amount
    ) public returns (uint256) {
        require(strategies[_gauge] == msg.sender, "!strategy");
        uint256 _balance = IERC20(_token).balanceOf(address(voter));
        voter.safeExecute(
            _gauge,
            0,
            abi.encodeWithSignature("withdraw(uint256)", _amount)
        );
        _balance = IERC20(_token).balanceOf(address(voter)).sub(_balance);
        voter.safeExecute(
            _token,
            0,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                msg.sender,
                _balance
            )
        );
        return _balance;
    }

    function balanceOf(address _gauge) public view returns (uint256) {
        return IERC20(_gauge).balanceOf(address(voter));
    }

    function withdrawAll(address _gauge, address _token)
        external
        returns (uint256)
    {
        require(strategies[_gauge] == msg.sender, "!strategy");
        return withdraw(_gauge, _token, balanceOf(_gauge));
    }

    function deposit(address _gauge, address _token) external {
        require(strategies[_gauge] == msg.sender, "!strategy");
        uint256 _balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(address(voter), _balance);
        _balance = IERC20(_token).balanceOf(address(voter));

        voter.safeExecute(
            _token,
            0,
            abi.encodeWithSignature("approve(address,uint256)", _gauge, 0)
        );
        voter.safeExecute(
            _token,
            0,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                _gauge,
                _balance
            )
        );
        voter.safeExecute(
            _gauge,
            0,
            abi.encodeWithSignature("deposit(uint256)", _balance)
        );
    }

    function harvest(address _gauge) external {
        require(strategies[_gauge] == msg.sender, "!strategy");
        uint256 _balance = IERC20(bal).balanceOf(address(voter));
        voter.safeExecute(
            balMinter,
            0,
            abi.encodeWithSignature("mint(address)", _gauge)
        );
        _balance = (IERC20(bal).balanceOf(address(voter))).sub(_balance);
        voter.safeExecute(
            bal,
            0,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                msg.sender,
                _balance
            )
        );
    }

    function claimRewards(address _gauge, address _token) external {
        require(strategies[_gauge] == msg.sender, "!strategy");
        voter.safeExecute(
            _gauge,
            0,
            abi.encodeWithSelector(
                IGauge.claim_rewards.selector,
                address(voter),
                msg.sender // This should forward along all rewards to the strategy
            )
        );
    }
}

library SafeVoter {
    function safeExecute(
        IBalancerVoter voter,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        (bool success, ) = voter.execute(to, value, data);
        require(success);
    }
}
