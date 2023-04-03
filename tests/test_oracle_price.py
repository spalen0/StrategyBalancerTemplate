import brownie
from brownie import Contract, config, ZERO_ADDRESS


def test_oracle_price(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    gauge,
    voter,
    amount,
):
    # strategy.setOptimalStable(2, {"from": gov})
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    newWhale = token.balanceOf(whale)

    # this is part of our check into the staking contract balance
    stakingBeforeHarvest = gauge.balanceOf(strategy)

    # harvest, store asset amount
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)
    old_assets = vault.totalAssets()
    assert old_assets > 0
    assert token.balanceOf(strategy) == 0
    assert strategy.estimatedTotalAssets() > 0
    print("\nStarting Assets: ", old_assets / 1e18)

    # try and include custom logic here to check that funds are in the staking contract (if needed)
    assert gauge.balanceOf(strategy) > stakingBeforeHarvest

    # simulate 7 days of earnings because more CRV need to be sent over
    chain.sleep(604800)
    chain.mine(1)

    # set oracle price to ETH price
    strategy.setPriceOracles("0x13e3ee699d1909e989722e753853ae30b17e08c5", "0x13e3ee699d1909e989722e753853ae30b17e08c5", {"from": gov})

    # harvest, store new asset amount
    chain.sleep(1)

    assert strategy.harvestTrigger(0, {"from": gov}) == False

    # harvest should revert because of oracle price will return much higher price
    with brownie.reverts():
        strategy.harvest({"from": gov})


def test_without_oracle_price(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    gauge,
    voter,
    amount,
):
    strategy.setPriceOracles(ZERO_ADDRESS, ZERO_ADDRESS, {"from": gov})

    # strategy.setOptimalStable(2, {"from": gov})
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    newWhale = token.balanceOf(whale)

    # this is part of our check into the staking contract balance
    stakingBeforeHarvest = gauge.balanceOf(strategy)

    # harvest, store asset amount
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)
    old_assets = vault.totalAssets()
    assert old_assets > 0
    assert token.balanceOf(strategy) == 0
    assert strategy.estimatedTotalAssets() > 0
    print("\nStarting Assets: ", old_assets / 1e18)

    # try and include custom logic here to check that funds are in the staking contract (if needed)
    assert gauge.balanceOf(strategy) > stakingBeforeHarvest

    # simulate 12 hours of earnings because more CRV need to be sent over
    chain.sleep(43200)
    chain.mine(1)

    # harvest, store new asset amount
    chain.sleep(1)
    strategy.harvest({"from": gov})

    new_assets = vault.totalAssets()
    # confirm swap was made without price oracles
    assert new_assets > old_assets


def test_oracle_price_without_slippage(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    gauge,
    voter,
    amount,
):
    # strategy.setOptimalStable(2, {"from": gov})
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    newWhale = token.balanceOf(whale)

    # this is part of our check into the staking contract balance
    stakingBeforeHarvest = gauge.balanceOf(strategy)

    # harvest, store asset amount
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)
    old_assets = vault.totalAssets()
    assert old_assets > 0
    assert token.balanceOf(strategy) == 0
    assert strategy.estimatedTotalAssets() > 0
    print("\nStarting Assets: ", old_assets / 1e18)

    # try and include custom logic here to check that funds are in the staking contract (if needed)
    assert gauge.balanceOf(strategy) > stakingBeforeHarvest

    # simulate 12 hours of earnings because more CRV need to be sent over
    chain.sleep(43200)
    chain.mine(1)

    # set oracle price
    strategy.setRewardsData(1, 0, {"from": gov})

    # harvest, store new asset amount
    chain.sleep(1)

    assert strategy.harvestTrigger(0, {"from": gov}) == False

    # harvest should revert because there is no slippage for swapping
    with brownie.reverts():
        strategy.harvest({"from": gov})
