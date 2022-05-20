// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {IUniswapV2Router02} from "./interfaces/uniswap.sol";
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {IStrategyVoterProxy} from "../interfaces/Yearn/IStrategyVoterProxy.sol";
import {IPriceFeed} from "../interfaces/Liquity/IPriceFeed.sol"; // Liquity happens to have a good ETH/USD oracle aggregator

import {IBalancerVault, IBalancerPool} from "../interfaces/Balancer/BalancerV2.sol";

interface ILiquidityGaugeFactory {
    function getPoolGauge(address pool) external view returns (address);
}

abstract contract StrategyBalancerBase is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.

    IStrategyVoterProxy public proxy;
    address immutable public voter; // We don't need to call it, but we need to send BAL to it
    address public gauge; // Gauge that voter stakes in to recieve BAL rewards 

    // keepBAL stuff
    uint256 public keepBAL = 1000; // the percentage of BAL that we re-lock for boost (in bips) 
    uint256 public constant BIPS_DENOMINATOR = 10000; // 10k bips in 100%

    IERC20 public constant BAL =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IBalancerVault public balancerVault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    ILiquidityGaugeFactory public liquidityGaugeFactory = ILiquidityGaugeFactory(0x4E7bBd911cf1EFa442BC1b2e9Ea01ffE785412EC);

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us

    string internal stratName; // set our strategy name here

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, address _proxy, address _voter) public BaseStrategy(_vault) {
        proxy = IStrategyVoterProxy(_proxy);
        voter = _voter;
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    function stakedBalance() public view returns (uint256) {
        return proxy.balanceOf(gauge);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(stakedBalance());
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    // these should stay the same across different wants.

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // Send all of our LP tokens to the proxy and deposit to the gauge if we have any
        uint256 _toInvest = balanceOfWant();
        if (_toInvest > 0) {
            want.safeTransfer(address(proxy), _toInvest);
            proxy.deposit(gauge, address(want));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBalance = balanceOfWant();
        if (_amountNeeded > _wantBalance) {
            // check if we have enough free funds to cover the withdrawal
            uint256 _stakedBalance = stakedBalance();
            if (_stakedBalance > 0) {
                proxy.withdraw(
                    gauge,
                    address(want),
                    Math.min(_stakedBalance, _amountNeeded.sub(_wantBalance))
                );
            }
            uint256 _withdrawnBalance = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBalance);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    // fire sale, get rid of it all!
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBalance = stakedBalance();
        if (_stakedBalance > 0) {
            // don't bother withdrawing zero
            proxy.withdraw(gauge, address(want), _stakedBalance);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBalance = stakedBalance();
        if (_stakedBalance > 0) {
            proxy.withdraw(gauge, address(want), _stakedBalance);
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /* ========== KEEP3RS ========== */

    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        return super.harvestTrigger(callCostinEth);
    }

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Use to update Yearn's StrategyProxy contract as needed in case of upgrades.
    function setProxy(address _proxy) external onlyGovernance {
        proxy = IStrategyVoterProxy(_proxy);
    }

    // Set the amount of BAL to be locked in Yearn's veBAL voter from each harvest. Default is 10%.
    function setKeepBAL(uint256 _keepBAL) external onlyAuthorized {
        require(_keepBAL <= 10_000);
        keepBAL = _keepBAL;
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }
}

contract StrategyBalancerBoostedPool is StrategyBalancerBase {

    // Chainlink ETH:USD with Tellor ETH:USD as fallback
    IPriceFeed internal constant priceFeed =
        IPriceFeed(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De);

    constructor(
        address _vault,
        string memory _name,
        address _proxy,
        address _voter
    ) public StrategyBalancerBase(_vault, _proxy, _voter) {
        require(address(want) == 0x7B50775383d3D6f0215A8F290f2C9e2eEBBEceb2, "!boosted_pool");
        maxReportDelay = 7 days; // 7 days in seconds
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // health.ychad.eth

        // these are our standard approvals. want = Balancer LP token
        want.approve(address(proxy), type(uint256).max);

        gauge = 0x68d019f64A7aa97e2D4e7363AEE42251D08124Fb;

        stratName = _name;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    // these will likely change across different wants.

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 _stakedBalance = stakedBalance();
        if (_stakedBalance > 0) {
            uint256 _balanceOfBalBeforeClaim = BAL.balanceOf(address(this));
            proxy.harvest(gauge);
            uint256 _balClaimed = BAL.balanceOf(address(this)).sub(_balanceOfBalBeforeClaim);

            if (_balClaimed > 0) {
                uint256 _sendToVoter = _balClaimed.mul(keepBAL).div(BIPS_DENOMINATOR);

                if (_sendToVoter > 0) {
                    BAL.safeTransfer(voter, _sendToVoter);
                }
            }
        }

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            uint256 _toWithdraw = _debtOutstanding.sub(balanceOfWant());
            if (_stakedBalance > 0) {
                // don't bother withdrawing if we don't have staked funds
                proxy.withdraw(
                    gauge,
                    address(want),
                    Math.min(_stakedBalance, _debtOutstanding)
                );
            }
            _debtPayment = Math.min(_debtOutstanding, balanceOfWant());
        }

        // serious loss should never happen, but if it does (for instance, if Balancer is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets.sub(debt);
            uint256 _wantBal = balanceOfWant();
            if (_profit.add(_debtPayment) > _wantBal) {
                // this should only be hit following donations to strategy
                liquidateAllPositions();
            }
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt.sub(assets);
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }


    /* ========== KEEP3RS ========== */

    // convert our keeper's eth cost into want
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {
        uint256 _amountInUSD = _ethAmount.mul(priceFeed.lastGoodPrice()).div(1e18);
        return _amountInUSD.mul(1e18).div(IBalancerPool(address(want)).getRate());
    }

}
