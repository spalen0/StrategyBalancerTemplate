import brownie
from brownie import Contract
from brownie import config
import math


def test_triggers(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    amount,
):
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    newWhale = token.balanceOf(whale)
    starting_assets = vault.totalAssets()
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # simulate a day of earnings
    chain.sleep(86400)
    chain.mine(1)

    # harvest should trigger false; hasn't been long enough
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be False.", tx)
    assert tx == False

    # simulate 5 days of earnings
    chain.sleep(86400 * 5)
    chain.mine(1)

    # harvest should trigger true
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be true.", tx)
    assert tx == False

    strategy.setMinReportDelay(6*86400, {"from":gov})

    # simulate 5 days of earnings
    chain.sleep(86400 * 5)
    chain.mine(1)

    # harvest should trigger true
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be true.", tx)
    assert tx == True

    # withdraw and confirm we made money
    strategy.harvest({"from": gov})
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) >= startingWhale


def test_less_useful_triggers(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    amount,
):
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    newWhale = token.balanceOf(whale)
    starting_assets = vault.totalAssets()
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    strategy.setMinReportDelay(100, {"from": gov})
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be False.", tx)
    assert tx == False


def test_rewards_triggers(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    amount,
    rewards_token,
):
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    newWhale = token.balanceOf(whale)
    starting_assets = vault.totalAssets()
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # rewards token is below min amount
    min_rewards_to_sell = 1e10
    rewards_token.transfer(strategy, 1e10 + 1, {"from": whale})
    assert strategy.harvestTrigger(0, {"from": gov}) == False

    # set lower min rewards trigger
    strategy.setMinRewardsToSell(min_rewards_to_sell, {"from": gov})
    assert strategy.harvestTrigger(0, {"from": gov}) == True
