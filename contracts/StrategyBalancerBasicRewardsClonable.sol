// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/curve.sol";
import "./interfaces/yearn.sol";
import {IUniswapV2Router02} from "./interfaces/uniswap.sol";
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

interface IBalancerStrategyVoterProxy {
    function balanceOf(address _gauge) public view returns (uint256);

    function withdraw(
        address _gauge,
        address _token,
        uint256 _amount
    ) public returns (uint256);

    function withdrawAll(address _gauge, address _token) external returns (uint256);

    function deposit(address _gauge, address _token) external;
}

interface ILiquidityGaugeFactory {
    function getPoolGauge(address pool) external view returns (address);
}

abstract contract StrategyBalancerBase is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.

    IBalancerStrategyVoterProxy public proxy;
    address public gauge; // Gauge that voter stakes in to recieve BAL rewards 

    // keepBAL stuff
    uint256 public keepBAL = 1000; // the percentage of CRV we re-lock for boost (in basis points)
    uint256 public constant FEE_DENOMINATOR = 10000; // this means all of our fee values are in bips
    address public constant voter = 0xF147b8125d2ef93FB6965Db97D6746952a133934; // TODO: set this

    IERC20 public constant BAL =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IBalancerVault public balancerVault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    ILiquidityGaugeFactory public liquidityGaugeFactory = ILiquidityGaugeFactory(0x4E7bBd911cf1EFa442BC1b2e9Ea01ffE785412EC);

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us

    string internal stratName; // set our strategy name here

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) public BaseStrategy(_vault) {}

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
        if (_stakedBal > 0) {
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
        proxy = IBalancerStrategyProxy(_proxy);
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
    /* ========== STATE VARIABLES ========== */
    // these will likely change across different wants.

    IERC20 public constant usdt =
        IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 public constant usdc =
        IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public constant dai =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        string memory _name
    ) public StrategyBalancerBase(_vault) {
        maxReportDelay = 7 days; // 7 days in seconds
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // health.ychad.eth

        // these are our standard approvals. want = Curve LP token
        want.approve(address(proxy), type(uint256).max);
        BAL.approve(sushiswap, type(uint256).max);

        // set our curve gauge contract
        gauge = 0x68d019f64A7aa97e2D4e7363AEE42251D08124Fb;

        // set our strategy's name
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
        // if we have anything in the gauge, then harvest CRV from the gauge
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            proxy.harvest(gauge);
            uint256 _crvBalance = crv.balanceOf(address(this));
            // if we claimed any CRV, then sell it
            if (_crvBalance > 0) {
                // keep some of our CRV to increase our boost
                uint256 _sendToVoter =
                    _crvBalance.mul(keepCRV).div(FEE_DENOMINATOR);
                if (keepCRV > 0) {
                    crv.safeTransfer(voter, _sendToVoter);
                }
                uint256 _crvRemainder = _crvBalance.sub(_sendToVoter);

                // sell the rest of our CRV
                if (_crvRemainder > 0) {
                    _sell(_crvRemainder);
                }

                if (hasRewards) {
                    proxy.claimRewards(gauge, address(rewardsToken));
                    uint256 _rewardsBalance =
                        rewardsToken.balanceOf(address(this));
                    if (_rewardsBalance > 0) {
                        _sellRewards(_rewardsBalance);
                    }
                }

                // deposit our balance to Curve if we have any
                if (optimal == 0) {
                    uint256 daiBalance = dai.balanceOf(address(this));
                    zapContract.add_liquidity(curve, [0, daiBalance, 0, 0], 0);
                } else if (optimal == 1) {
                    uint256 usdcBalance = usdc.balanceOf(address(this));
                    zapContract.add_liquidity(curve, [0, 0, usdcBalance, 0], 0);
                } else {
                    uint256 usdtBalance = usdt.balanceOf(address(this));
                    zapContract.add_liquidity(curve, [0, 0, 0, usdtBalance], 0);
                }
            }
        }

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            if (_stakedBal > 0) {
                // don't bother withdrawing if we don't have staked funds
                proxy.withdraw(
                    gauge,
                    address(want),
                    Math.min(_stakedBal, _debtOutstanding)
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
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

    // Sells our harvested CRV into the selected output.
    function _sell(uint256 _amount) internal {
        IUniswapV2Router02(sushiswap).swapExactTokensForTokens(
            _amount,
            uint256(0),
            crvPath,
            address(this),
            block.timestamp
        );
    }

    // Sells our harvested reward token into the selected output.
    function _sellRewards(uint256 _amount) internal {
        IUniswapV2Router02(sushiswap).swapExactTokensForTokens(
            _amount,
            uint256(0),
            rewardsPath,
            address(this),
            block.timestamp
        );
    }

    /* ========== KEEP3RS ========== */

    // convert our keeper's eth cost into want
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {
        uint256 callCostInWant;
        if (_ethAmount > 0) {
            address[] memory ethPath = new address[](2);
            ethPath[0] = address(weth);
            ethPath[1] = address(dai);

            uint256[] memory _callCostInDaiTuple =
                IUniswapV2Router02(sushiswap).getAmountsOut(
                    _ethAmount,
                    ethPath
                );

            uint256 _callCostInDai =
                _callCostInDaiTuple[_callCostInDaiTuple.length - 1];
            callCostInWant = zapContract.calc_token_amount(
                curve,
                [0, _callCostInDai, 0, 0],
                true
            );
        }
        return callCostInWant;
    }

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Use to add or update rewards
    function updateRewards(address _rewardsToken) external onlyGovernance {
        // reset allowance to zero for our previous token if we had one
        if (address(rewardsToken) != address(0)) {
            rewardsToken.approve(sushiswap, uint256(0));
        }
        // update with our new token, use dai as default
        rewardsToken = IERC20(_rewardsToken);
        rewardsToken.approve(sushiswap, type(uint256).max);
        rewardsPath = [address(rewardsToken), address(weth), address(dai)];
        hasRewards = true;
    }

    // Use to turn off extra rewards claiming
    function turnOffRewards() external onlyGovernance {
        hasRewards = false;
        if (address(rewardsToken) != address(0)) {
            rewardsToken.approve(sushiswap, uint256(0));
        }
        rewardsToken = IERC20(address(0));
    }

    // Set optimal token to sell harvested funds for depositing to Curve.
    // Default is DAI, but can be set to USDC or USDT as needed by strategist or governance.
    function setOptimal(uint256 _optimal) external onlyAuthorized {
        if (_optimal == 0) {
            crvPath[2] = address(dai);
            if (hasRewards) {
                rewardsPath[2] = address(dai);
            }
            optimal = 0;
        } else if (_optimal == 1) {
            crvPath[2] = address(usdc);
            if (hasRewards) {
                rewardsPath[2] = address(usdc);
            }
            optimal = 1;
        } else if (_optimal == 2) {
            crvPath[2] = address(usdt);
            if (hasRewards) {
                rewardsPath[2] = address(usdt);
            }
            optimal = 2;
        } else {
            revert("incorrect token");
        }
    }
}
