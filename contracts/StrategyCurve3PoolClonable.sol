// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/curve.sol";
import "./interfaces/yearn.sol";
import {IUniswapV3Router01} from "./interfaces/uniswap.sol";
import {AggregatorV3Interface} from "./interfaces/chainlink.sol";
import "@yearnvaults/contracts/BaseStrategy.sol";

interface IWeth {
    function withdraw(uint256 wad) external;
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

abstract contract StrategyCurveBase is BaseStrategy {

    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.

    // curve infrastructure contracts
    IGauge public gauge; // Curve gauge contract, most are tokenized, held by Yearn's voter

    // keepCRV stuff
    uint256 public keepCRV; // the percentage of CRV we re-lock for boost (in basis points)
    address public constant voter = 0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26; // Optimism SMS
    uint256 internal constant FEE_DENOMINATOR = 10000; // this means all of our fee values are in basis points

    // Swap stuff
    IUniswapV3Router01 internal constant uniswap =
        IUniswapV3Router01(0xE592427A0AEce92De3Edee1F18E0157C05861564); // we use this to sell our bonus token

    IERC20 internal constant sUsd =
        IERC20(0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9);
    IERC20 internal constant crv =
        IERC20(0x0994206dfE8De6Ec6920FF4D779B0d950605Fb53);
    IERC20 internal constant weth =
        IERC20(0x4200000000000000000000000000000000000006);
    IERC20 internal constant dai =
        IERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
    IERC20 internal constant usdc =
        IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    IERC20 internal constant usdt =
        IERC20(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58);
    IMinter public constant mintr = IMinter(0xabC000d88f23Bb45525E447528DBF656A9D55bf5);
    address internal constant pool3 = 0x1337BedC9D22ecbe766dF105c9623922A27963EC;

    string internal stratName;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) BaseStrategy(_vault) {}

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    ///@notice How much want we have staked in Curve's gauge
    function stakedBalance() public view returns (uint256) {
        return IERC20(address(gauge)).balanceOf(address(this));
    }

    ///@notice Balance of want sitting in our strategy
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + stakedBalance();
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // Deposit to the gauge if we have any
        uint256 _toInvest = balanceOfWant();
        if (_toInvest > 0 && _toInvest > _debtOutstanding) {
            gauge.deposit(_toInvest - _debtOutstanding);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBal = balanceOfWant();
        if (_amountNeeded > _wantBal) {
            // check if we have enough free funds to cover the withdrawal
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                gauge.withdraw(
                    Math.min(_stakedBal, _amountNeeded - _wantBal)
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBal);
            _loss = _amountNeeded - _liquidatedAmount;
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    // fire sale, get rid of it all!
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            // don't bother withdrawing zero
            gauge.withdraw(_stakedBal);
        }
        return balanceOfWant();
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Set the amount of CRV to be locked in Yearn's veCRV voter from each harvest. Default is 10%.
    function setKeepCRV(uint256 _keepCRV) external onlyVaultManagers {
        require(_keepCRV <= 10_000);
        keepCRV = _keepCRV;
    }

}

contract StrategyCurve3PoolClonable is StrategyCurveBase {
    using SafeERC20 for IERC20;
    /* ========== STATE VARIABLES ========== */
    // these will likely change across different wants.

    // Curve stuff
    ICurveFi public curve; ///@notice This is our curve pool specific to this vault
    uint24 public feeCRVETH;
    uint24 public feeOPETH;
    uint24 public feeETHUSD;
    address public targetStable;

    // rewards token info. we can have more than 1 reward token but this is rare, so we don't include this in the template
    IERC20 public rewardsToken;
    bool public hasRewards;
    uint256 public minRewardsUsdToTrigger;
    uint256 public maxSwapSlippage;
    address public rewardsOracle;
    address public crvOracle;

    // check for cloning
    bool internal isOriginal = true;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        address _gauge,
        address _curvePool,
        string memory _name
    ) StrategyCurveBase(_vault) {
        _initializeStrat(_gauge, _curvePool, _name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // we use this to clone our original strategy to other vaults
    function cloneCurveOldEth(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _gauge,
        address _curvePool,
        string memory _name
    ) external returns (address payable newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategyCurve3PoolClonable(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _gauge,
            _curvePool,
            _name
        );

        emit Cloned(newStrategy);
    }

    // this will only be called by the clone function above
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _gauge,
        address _curvePool,
        string memory _name
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_gauge, _curvePool, _name);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(
        address _gauge,
        address _curvePool,
        string memory _name
    ) internal {
        // make sure that we haven't initialized this before
        require(address(curve) == address(0)); // already initialized.

        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 100 days; // 100 days in seconds
        minReportDelay = 21 days; // 21 days in seconds
        healthCheck = 0x3d8F58774611676fd196D26149C71a9142C45296; // health.ychad.eth
        creditThreshold = 500 * 1e18;
        keepCRV = 0; // default of 0%

        // set uniswap v3 fees
        feeCRVETH = 3000;
        feeOPETH = 500;
        feeETHUSD = 500;

        // define minimal rewards to trigger harvest in dollars in BPS
        minRewardsUsdToTrigger = 50 * FEE_DENOMINATOR;
        rewardsOracle = 0x0D276FC14719f9292D5C1eA2198673d1f4269246;
        crvOracle = 0xbD92C6c284271c227a1e0bF1786F468b539f51D9;
        maxSwapSlippage = 1000;

        // these are our standard approvals. want = Curve LP token
        want.approve(address(_gauge), type(uint256).max);
        crv.approve(address(uniswap), type(uint256).max);
        weth.approve(address(uniswap), type(uint256).max);

        dai.approve(pool3, type(uint256).max);
        usdt.safeApprove(pool3, type(uint256).max);
        usdc.approve(pool3, type(uint256).max);

        // this is the pool specific to this vault
        curve = ICurveFi(_curvePool);
        sUsd.approve(_curvePool, type(uint256).max);
        IERC20(pool3).approve(_curvePool, type(uint256).max);

        // set our curve gauge contract
        gauge = IGauge(_gauge);

        // set our strategy's name
        stratName = _name;

        // set strategy default traget stable
        targetStable = address(usdt);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function setFeeCRVETH(uint24 _newFeeCRVETH) external onlyVaultManagers {
        feeCRVETH = _newFeeCRVETH;
    }

    function setFeeOPETH(uint24 _newFeeOPETH) external onlyVaultManagers {
        feeOPETH = _newFeeOPETH;
    }

    function setFeeETHUSD(uint24 _newFeeETHUSD) external onlyVaultManagers {
        feeETHUSD = _newFeeETHUSD;
    }

    ///@notice Set minimal rewards to trigger harvest in dollars in BPS.
    ///@param _minRewardsUsdToTrigger Minimal rewards to trigger harvest in dollars in BPS.
    ///@param _maxSwapSlippage Max slippage to swap token in BPS.
    function setRewardsData(uint256 _minRewardsUsdToTrigger, uint256 _maxSwapSlippage) external onlyVaultManagers {
        minRewardsUsdToTrigger = _minRewardsUsdToTrigger;
        require(_maxSwapSlippage < FEE_DENOMINATOR, "Invalid slippage");
        maxSwapSlippage = _maxSwapSlippage;
    }

    ///@notice Set chainlink price oracles
    ///@param _rewardsOracle Address of chainlink oracle for rewards token in dollars.
    ///@param _crvOracle Address of chainlink oracle for crv token in dollars.
    function setPriceOracles(address _rewardsOracle, address _crvOracle) external onlyVaultManagers {
        rewardsOracle = _rewardsOracle;
        crvOracle = _crvOracle;
    }

    ///@notice Set optimal token to sell harvested funds for depositing to Curve.
    function setOptimalStable(uint256 _optimal) external onlyVaultManagers {
        if (_optimal == 0) {
            targetStable = address(dai);
        } else if (_optimal == 1) {
            targetStable = address(usdc);
        } else if (_optimal == 2) {
            targetStable = address(usdt);
        } else if (_optimal == 3) {
            targetStable = address(sUsd);
        } else {
            revert("incorrect token");
        }
    }

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
        uint256 _crvBalance = crv.balanceOf(address(this));
        if (_stakedBal > 0) {
            // Mintr CRV emissions
            mintr.mint(address(gauge));
            _crvBalance = crv.balanceOf(address(this));
            // if we claimed any CRV, then sell it
            if (_crvBalance > 0) {
                // keep some of our CRV to increase our boost
                uint256 _sendToVoter =
                    _crvBalance * keepCRV / FEE_DENOMINATOR;
                if (_sendToVoter > 0) {
                    crv.safeTransfer(voter, _sendToVoter);
                }
                _crvBalance -= _sendToVoter;
            }
        }

        // claim and sell our rewards if we have them
        if (hasRewards) {
            gauge.claim_rewards();
            uint256 _rewardsBalance = rewardsToken.balanceOf(address(this));
            if (_rewardsBalance > 0) {
                _sellTokenToStableUniV3(address(rewardsToken), feeOPETH, _rewardsBalance, rewardsOracle);
            }
        }

        if (_crvBalance > 1e17) {
            // don't want to swap dust or we might revert
            _sellTokenToStableUniV3(address(crv), feeCRVETH, _crvBalance, crvOracle);
        }

        if (targetStable != address(sUsd)) {
            // check for balances of tokens to deposit
            uint256 _daiBalance = dai.balanceOf(address(this));
            uint256 _usdcBalance = usdc.balanceOf(address(this));
            uint256 _usdtBalance = usdt.balanceOf(address(this));
            // deposit our balance to Curve if we have any
            if (_daiBalance > 0 || _usdcBalance > 0 || _usdtBalance > 0) {
                ICurveFi(pool3).add_liquidity(
                    [_daiBalance, _usdcBalance, _usdtBalance],
                    0
                );
            }
            uint256 pool3Balance = IERC20(pool3).balanceOf(address(this));
            if (pool3Balance > 0) {
                curve.add_liquidity([0, pool3Balance], 0);
            }
        } else {
            uint256 sUsdBalance = sUsd.balanceOf(address(this));
            if (sUsdBalance > 0) {
                curve.add_liquidity([sUsdBalance, 0], 0);
            }
        }

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            if (_stakedBal > 0) {
                // don't bother withdrawing if we don't have staked funds
                gauge.withdraw(Math.min(_stakedBal, _debtOutstanding));
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets - debt;
            uint256 _wantBal = balanceOfWant();
            if (_profit + _debtPayment > _wantBal) {
                // this should only be hit following donations to strategy
                liquidateAllPositions();
            }
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt - assets;
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            gauge.withdraw(_stakedBal);
        }
        crv.safeTransfer(_newStrategy, crv.balanceOf(address(this)));
        if (address(rewardsToken) != address(0)) {
            rewardsToken.safeTransfer(_newStrategy, rewardsToken.balanceOf(address(this)));
        }
    }

    // Sells our harvested reward token into the selected output.
    function _sellTokenToStableUniV3(address _tokenIn,uint24 _fee, uint256 _amount, address priceOracle) internal {
        uint256 minAmountOut = 0;
        if (priceOracle != address(0)) {
            // amountInUsd * (1 - slippage)%
            minAmountOut = getTokenInUsd(priceOracle, _tokenIn, _amount)
                * (FEE_DENOMINATOR - maxSwapSlippage) / FEE_DENOMINATOR;
            if (minAmountOut == 0) {
                // if we can't get a price, then don't sell
                return;
            }
            // convert to target decimals
            minAmountOut *= 10 ** IERC20Metadata(targetStable).decimals() / FEE_DENOMINATOR;
        }

        uniswap.exactInput(
            IUniswapV3Router01.ExactInputParams(
                abi.encodePacked(_tokenIn, _fee, address(weth), feeETHUSD, targetStable),
                address(this),
                block.timestamp,
                _amount,
                minAmountOut
            )
        );
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if (block.timestamp - params.lastReport > maxReportDelay) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we hit our minDelay, but only if our gas price is acceptable
        if (block.timestamp - params.lastReport > minReportDelay) {
            return true;
        }

        // harvest our credit if it's above our threshold
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        uint256 rewards = gauge.claimable_reward(address(this), address(rewardsToken))
            - gauge.claimed_reward(address(this), address(rewardsToken));
        if (getTokenInUsd(rewardsOracle, address(rewardsToken), rewards) > minRewardsUsdToTrigger) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    /// @notice get the price of a token in USD, in BPS
    function getTokenInUsd(address oracleAddress, address token, uint256 rewards) public view returns (uint256) {
        if (oracleAddress == address(0)) {
            return 0;
        }
        AggregatorV3Interface oracle = AggregatorV3Interface(oracleAddress);
        (uint80 roundId, int256 answer, , , uint80 answeredInRound) = oracle.latestRoundData();
        if (answeredInRound <= roundId && answer > 0) {
            return uint256(answer) * rewards * FEE_DENOMINATOR
                / 10 ** (oracle.decimals() + IERC20Metadata(token).decimals());
        }
    }

    // convert our keeper's eth cost into want, we don't need this anymore since we don't use baseStrategy harvestTrigger
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {}

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    ///@notice Use to add, update or remove reward token
    // OP token: 0x4200000000000000000000000000000000000042
    function updateRewards(bool _hasRewards, address _rewardsToken)
        external
        onlyGovernance
    {
        // if we already have a rewards token, get rid of it
        if (address(rewardsToken) != address(0)) {
            rewardsToken.safeApprove(address(uniswap), uint256(0));
        }
        if (_hasRewards == false) {
            hasRewards = false;
            rewardsToken = IERC20(address(0));
        } else {
            // approve, setup our path, and turn on rewards
            rewardsToken = IERC20(_rewardsToken);
            rewardsToken.safeApprove(address(uniswap), type(uint256).max);
            hasRewards = true;
        }
    }
}
