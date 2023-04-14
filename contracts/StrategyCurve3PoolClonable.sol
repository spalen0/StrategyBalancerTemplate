// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/curve.sol";
import "./interfaces/yearn.sol";
import {IUniswapV3Router01} from "./interfaces/uniswap.sol";
import {AggregatorV3Interface} from "./interfaces/chainlink.sol";
import "./interfaces/velodrome.sol";
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

    address internal constant voter = 0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26; // Optimism SMS
    IMinter internal constant mintr = IMinter(0xabC000d88f23Bb45525E447528DBF656A9D55bf5);
    uint256 internal constant FEE_DENOMINATOR = 10000; // this means all of our fee values are in basis points
    IERC20 internal constant crv = IERC20(0x0994206dfE8De6Ec6920FF4D779B0d950605Fb53);

    string internal stratName;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) BaseStrategy(_vault) {}

    function initializeStrat(address _gauge, string memory _name) internal virtual {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 100 days; // 100 days in seconds
        minReportDelay = 21 days; // 21 days in seconds
        healthCheck = 0x3d8F58774611676fd196D26149C71a9142C45296; // health.ychad.eth
        creditThreshold = 500 * 1e18;
        keepCRV = 0; // default of 0%

        // these are our standard approvals. want = Curve LP token
        want.approve(address(_gauge), type(uint256).max);

        // set our curve gauge contract
        gauge = IGauge(_gauge);

        // set our strategy's name
        stratName = _name;
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    /// @notice How much want we have staked in Curve's gauge
    function stakedBalance() public view returns (uint256) {
        return IERC20(address(gauge)).balanceOf(address(this));
    }

    /// @notice Balance of want sitting in our strategy
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
        if (_toInvest > _debtOutstanding) {
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

    /// @notice Set the amount of CRV to be locked in Yearn's veCRV voter from each harvest. Default is 0%.
    /// @dev Max value is 10,000 (100%)
    /// @param _keepCRV The amount of CRV to be locked in Yearn's veCRV voter from each harvest.
    function setKeepCRV(uint256 _keepCRV) external onlyVaultManagers {
        require(_keepCRV <= 10_000);
        keepCRV = _keepCRV;
    }

}

abstract contract Strategy3CurveBase is StrategyCurveBase {
    using SafeERC20 for IERC20;

    IERC20 internal constant weth =
        IERC20(0x4200000000000000000000000000000000000006);
    IERC20 internal constant dai =
        IERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
    IERC20 internal constant usdc =
        IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    IERC20 internal constant usdt =
        IERC20(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58);
    address internal constant pool3 = 0x1337BedC9D22ecbe766dF105c9623922A27963EC;

    // Curve stuff
    ICurveFi public curve; /// @notice This is our curve pool specific to this vault
    address public targetStable;

    // rewards token info. we can have more than 1 reward token but this is rare, so we don't include this in the template
    IERC20 public poolToken;
    IERC20 public rewardsToken;

    function initializeStrat(
        address _gauge,
        address _curvePool,
        address _poolToken,
        string memory _name
    ) internal virtual { 
        super.initializeStrat(_gauge, _name);
        // set curve pool token, addinal to 3pool token
        poolToken = IERC20(_poolToken);
    
        // approve adding stables to 3pool
        dai.approve(pool3, type(uint256).max);
        usdt.safeApprove(pool3, type(uint256).max);
        usdc.approve(pool3, type(uint256).max);

        // this is the pool specific to this vault
        curve = ICurveFi(_curvePool);
        poolToken.safeApprove(_curvePool, type(uint256).max);
        IERC20(pool3).approve(_curvePool, type(uint256).max);

        // set strategy default traget stable
        targetStable = address(usdt);
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
        if (address(rewardsToken) != address(0)) {
            gauge.claim_rewards();
            uint256 _rewardsBalance = rewardsToken.balanceOf(address(this));
            if (_rewardsBalance > 0) {
                sellRewardToken(_rewardsBalance);
            }
        }

        if (_crvBalance > 1e17) {
            sellCrv(_crvBalance);
        }

        if (targetStable != address(poolToken)) {
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
            uint256 poolTokenBalance = poolToken.balanceOf(address(this));
            if (poolTokenBalance > 0) {
                curve.add_liquidity([poolTokenBalance, 0], 0);
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
        return hasEnoughRewardsToSell();
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

    /// @notice Set optimal token to sell harvested funds for depositing to Curve.
    /// @dev 0 - DAI, 1 - USDC, 2 - USDT, 3 - poolToken. Swaps use Uniswap V3, except for poolToken which uses Velodrome.
    /// @param _optimal Optimal token to sell harvested funds for depositing to Curve.
    function setOptimalStable(uint256 _optimal) external onlyVaultManagers {
        if (_optimal == 0) {
            targetStable = address(dai);
        } else if (_optimal == 1) {
            targetStable = address(usdc);
        } else if (_optimal == 2) {
            targetStable = address(usdt);
        } else if (_optimal == 3) {
            targetStable = address(poolToken);
        } else {
            revert("incorrect token");
        }
    }

    /* ========== VIRTUAL FUNCTIONS ========== */
    /// @dev Implement sell CRV token in desired way.
    function sellCrv(uint256 _amount) internal virtual;

    /// @dev Implement sell rewards token in desired way.
    function sellRewardToken(uint256 _amount) internal virtual;

    /// @dev Implement check for harvestTrigger if there are enough rewards to sell.
    function hasEnoughRewardsToSell() internal view virtual returns (bool);
}

contract StrategyClonable is Strategy3CurveBase {
    using SafeERC20 for IERC20;

    IUniswapV3Router01 internal constant uniswap =
        IUniswapV3Router01(0xE592427A0AEce92De3Edee1F18E0157C05861564); // we use this to sell our bonus token
    IVelodromeRouter internal constant veloRouter =
        IVelodromeRouter(0x9c12939390052919aF3155f41Bf4160Fd3666A6f);

    // swap related
    uint24 public feeCRVETH;
    uint24 public feeOPETH;
    uint24 public feeETHUSD;
    uint256 public maxSwapSlippage;
    address public rewardsOracle;
    address public crvOracle;
    uint24 public feeEthPooltoken; // set 0 to use velodrome

    uint256 public minRewardpoolTokenToTrigger;

    // check for cloning
    bool internal isOriginal = true;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        address _gauge,
        address _curvePool,
        address _poolToken,
        string memory _name
    ) StrategyCurveBase(_vault) {
        initializeStrat(_gauge, _curvePool, _poolToken, _name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // we use this to clone our original strategy to other vaults
    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _gauge,
        address _curvePool,
        address _poolToken,
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

        StrategyClonable(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _gauge,
            _curvePool,
            _poolToken,
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
        address _poolToken,
        string memory _name
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        initializeStrat(_gauge, _curvePool, _poolToken, _name);
    }

    // this is called by our original strategy, as well as any clones
    function initializeStrat(
        address _gauge,
        address _curvePool,
        address _poolToken,
        string memory _name
    ) internal override {
        // make sure that we haven't initialized this before
        require(address(curve) == address(0)); // already initialized.

        super.initializeStrat(_gauge, _curvePool, _poolToken, _name);

        // set uniswap v3 fees
        feeCRVETH = 3000;
        feeOPETH = 500;
        feeETHUSD = 500;

        // define minimal rewards to trigger harvest in dollars in BPS
        minRewardpoolTokenToTrigger = 50 * FEE_DENOMINATOR;
        rewardsOracle = 0x0D276FC14719f9292D5C1eA2198673d1f4269246;
        crvOracle = 0xbD92C6c284271c227a1e0bF1786F468b539f51D9;
        maxSwapSlippage = 1000;

        // approve tokens to swapping routers
        crv.approve(address(uniswap), type(uint256).max);
        weth.approve(address(uniswap), type(uint256).max);
        weth.approve(address(veloRouter), type(uint256).max);
    }


    /* ========== IMPL VIRTUAL FUNCTIONS ========== */
    function sellRewardToken(uint256 _amount) internal override {
        sellTokens(address(rewardsToken), feeOPETH, _amount, rewardsOracle);
    }

    function sellCrv(uint256 _amount) internal override {
        sellTokens(address(crv), feeCRVETH, _amount, crvOracle);
    }

    function sellTokens(address _tokenIn, uint24 _fee, uint256 _amount, address priceOracle) internal {
        uint256 minAmountOut = 0;
        if (priceOracle != address(0)) {
            // amountInUsd * (1 - slippage)%
            minAmountOut = getTokenInUsd(priceOracle, _tokenIn, _amount)
                * (FEE_DENOMINATOR - maxSwapSlippage) / FEE_DENOMINATOR;
            if (minAmountOut == 0) {
                // if we can't get a price, then don't sell
                return;
            }
            // convert to target decimals and downslace from BPS (fee denominator)
            minAmountOut *= 10 ** IERC20Metadata(targetStable).decimals() / FEE_DENOMINATOR;
        }

        // if we are selling to poolToken, then we need to use the velodrome router because there is liquidity
        if (targetStable == address(poolToken)) {
            sellPoolToken(_tokenIn, _fee, _amount, minAmountOut);
        } else {
            // sell token to weth and to target stable, all on uniswap v3
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
    }

    function sellPoolToken(address _tokenIn, uint24 _fee, uint256 _amount, uint256 _minAmountOut) internal {
        // sell token to weth on uniswap v3
        uniswap.exactInput(
            IUniswapV3Router01.ExactInputParams(
                abi.encodePacked(_tokenIn, _fee, address(weth)),
                address(this),
                block.timestamp,
                _amount,
                0
            )
        );
        if (feeEthPooltoken == 0) {
            // sell weth to poolToken on velodrome, if no uniswap v3 fee is set
            address usdcAddress = address(usdc);
            IVelodromeRouter.route[] memory path = new IVelodromeRouter.route[](2);
            path[0] = IVelodromeRouter.route(address(weth), usdcAddress, false);
            path[1] = IVelodromeRouter.route(usdcAddress, address(poolToken), true);
            veloRouter.swapExactTokensForTokens(
                weth.balanceOf(address(this)),
                _minAmountOut,
                path,
                address(this),
                block.timestamp
            );
        } else {
            // we sell weth to poolToken on uniswap v3
            uniswap.exactInput(
                IUniswapV3Router01.ExactInputParams(
                    abi.encodePacked(address(weth), feeEthPooltoken, address(poolToken)),
                    address(this),
                    block.timestamp,
                    weth.balanceOf(address(this)),
                    0
                )
            );
        }
    }

    function hasEnoughRewardsToSell() internal override view returns (bool) {
        return getTokenInUsd(rewardsOracle, address(rewardsToken), rewardsToken.balanceOf(address(this)))
            > minRewardpoolTokenToTrigger;
    }

    /* ========== SETTER FUNCTIONS ========== */

    /// @notice Set chainlink price oracles
    /// @param _rewardsOracle Address of chainlink oracle for rewards token in dollars.
    /// @param _crvOracle Address of chainlink oracle for crv token in dollars.
    function setPriceOracles(address _rewardsOracle, address _crvOracle) external onlyVaultManagers {
        rewardsOracle = _rewardsOracle;
        crvOracle = _crvOracle;
    }

    /// @notice Set uniswap v3 fees for swapping CRV to WETH.
    /// @param _newFeeCRVETH New fee for swapping CRV to WETH.
    function setFeeCRVETH(uint24 _newFeeCRVETH) external onlyVaultManagers {
        feeCRVETH = _newFeeCRVETH;
    }

    /// @notice Set uniswap v3 fees for swapping OP to WETH.
    /// @param _newFeeOPETH New fee for swapping OP to WETH.
    function setFeeOPETH(uint24 _newFeeOPETH) external onlyVaultManagers {
        feeOPETH = _newFeeOPETH;
    }

    /// @notice Set uniswap v3 fees for swapping WETH to traget stable.
    /// @param _newFeeETHUSD New fee for swapping WETH to traget stable.
    function setFeeETHUSD(uint24 _newFeeETHUSD) external onlyVaultManagers {
        feeETHUSD = _newFeeETHUSD;
    }

    /// @notice Set uniswap v3 fees for swapping WETH to poolToken. If the value is 0, then it uses velodrome router.
    /// @param _newfeeEthPooltoken New fee for swapping WETH to poolToken. Set to 0 to use velodrome router.
    function setFeeEthPooltoken(uint24 _newfeeEthPooltoken) external onlyVaultManagers {
        feeEthPooltoken = _newfeeEthPooltoken;
    }

    /// @notice Set minimal rewards to trigger harvest in dollars in BPS.
    /// @param _minRewardpoolTokenToTrigger Minimal rewards to trigger harvest in dollars in BPS.
    /// @param _maxSwapSlippage Max slippage to swap token in BPS.
    function setRewardsData(uint256 _minRewardpoolTokenToTrigger, uint256 _maxSwapSlippage) external onlyVaultManagers {
        minRewardpoolTokenToTrigger = _minRewardpoolTokenToTrigger;
        require(_maxSwapSlippage < FEE_DENOMINATOR, "Invalid slippage");
        maxSwapSlippage = _maxSwapSlippage;
    }

    /// @notice Use to add, update or remove reward token
    /// @dev default is OP token: 0x4200000000000000000000000000000000000042
    /// @param _rewardsToken Address of new reward token.
    function updateRewards(address _rewardsToken)
        external
        onlyGovernance
    {
        // if we already have a rewards token, get rid of it
        if (address(rewardsToken) != address(0)) {
            rewardsToken.safeApprove(address(uniswap), uint256(0));
        }
        if (_rewardsToken == address(0)) {
            rewardsToken = IERC20(address(0));
        } else {
            // approve, setup our path, and turn on rewards
            rewardsToken = IERC20(_rewardsToken);
            rewardsToken.safeApprove(address(uniswap), type(uint256).max);
        }
    }

    /// @notice get the price of a token in USD, in BPS (same value as FEE_DENOMINATOR)
    /// @param oracleAddress Address of chainlink oracle for token in dollars.
    /// @param token Address of token to get price from in USD.
    /// @param rewards Amount of token that is wanted to get price in USD.
    function getTokenInUsd(address oracleAddress, address token, uint256 rewards) internal view returns (uint256) {
        if (oracleAddress == address(0) || rewards == 0) {
            return 0;
        }
        AggregatorV3Interface oracle = AggregatorV3Interface(oracleAddress);
        (uint80 roundId, int256 answer, , , uint80 answeredInRound) = oracle.latestRoundData();
        if (answeredInRound <= roundId && answer > 0) {
            return uint256(answer) * rewards * FEE_DENOMINATOR
                / 10 ** (oracle.decimals() + IERC20Metadata(token).decimals());
        }
    }
}
