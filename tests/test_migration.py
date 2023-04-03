import brownie
from brownie import Contract, config, ZERO_ADDRESS
import math


def test_migration(
    StrategyClonable,
    gov,
    token,
    vault,
    guardian,
    strategist,
    whale,
    strategy,
    chain,
    rewards_token,
    strategist_ms,
    healthCheck,
    amount,
    pool,
    strategy_name,
    gauge,
    pool_token,
):

    ## deposit to the vault after approving
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # deploy our new strategy
    new_strategy = strategist.deploy(
        StrategyClonable,
        vault,
        gauge,
        pool,
        strategy_name,
        pool_token,
    )
    strategy.updateRewards(True, rewards_token, {"from": gov})
    strategy.setFeeCRVETH(3000, {"from": gov})
    strategy.setFeeOPETH(500, {"from": gov})
    strategy.setFeeETHUSD(500, {"from": gov})
    total_old = strategy.estimatedTotalAssets()

    # can we harvest an unactivated strategy? should be no
    # under our new method of using min and maxDelay, this no longer matters or works
    # tx = new_strategy.harvestTrigger(0, {"from": gov})
    # print("\nShould we harvest? Should be False.", tx)
    # assert tx == False

    # simulate 1 day of earnings
    chain.sleep(86400)
    chain.mine(1)

    # migrate our old strategy
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    new_strategy.setHealthCheck(healthCheck, {"from": gov})
    new_strategy.setDoHealthCheck(True, {"from": gov})

    # assert that our old strategy is empty
    updated_total_old = strategy.estimatedTotalAssets()
    assert updated_total_old == 0
    assert rewards_token.balanceOf(strategy) == 0

    # harvest to get funds back in strategy
    chain.sleep(1)
    new_strategy.harvest({"from": gov})
    new_strat_balance = new_strategy.estimatedTotalAssets()

    # confirm we made money, or at least that we have about the same
    assert new_strat_balance >= total_old or math.isclose(
        new_strat_balance, total_old, abs_tol=5
    )

    startingVault = vault.totalAssets()
    print("\nVault starting assets with new strategy: ", startingVault)

    # simulate one day of earnings
    chain.sleep(86400)
    chain.mine(1)

    # Test out our migrated strategy, confirm we're making a profit
    new_strategy.harvest({"from": gov})
    vaultAssets_2 = vault.totalAssets()
    # confirm we made money, or at least that we have about the same
    assert vaultAssets_2 >= startingVault or math.isclose(
        vaultAssets_2, startingVault, abs_tol=5
    )
    print("\nAssets after 1 day harvest: ", vaultAssets_2)