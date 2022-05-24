import pytest


def test_migration(
    chain,
    want,
    vault,
    strategy,
    amount,
    StrategyBalancerClonable,
    strategist,
    gov,
    user,
    trade_factory,
    ymechs_safe,
    voter_proxy,
    yearn_balancer_voter,
    RELATIVE_APPROX,
):
    # Deposit to the vault and harvest
    want.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    predicted_new_strategy_address = strategist.get_deployment_address()
    trade_factory.grantRole(
        trade_factory.STRATEGY(),
        predicted_new_strategy_address,
        {"from": ymechs_safe, "gas_price": "0 gwei"},
    )
    new_strategy = strategist.deploy(
        StrategyBalancerClonable,
        vault,
        voter_proxy,
        yearn_balancer_voter,
    )
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert (
        pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == amount
    )
