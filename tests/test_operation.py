import pytest
import brownie


def test_operation(
    chain,
    want,
    vault,
    strategy,
    amount,
    user,
    strategist,
    yearn_balancer_voter,
    gauge,
    RELATIVE_APPROX,
):
    want.approve(vault, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    assert gauge.balanceOf(yearn_balancer_voter) == amount

    vault.withdraw({"from": user})
    assert pytest.approx(want.balanceOf(user), rel=RELATIVE_APPROX) == amount


def test_change_debt(
    chain,
    gov,
    want,
    vault,
    strategy,
    user,
    amount,
    RELATIVE_APPROX,
):
    want.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    half = int(amount / 2)
    sixty_percent = int(amount * 0.6)
    fourty_percent = int(amount * 0.4)

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.updateStrategyDebtRatio(strategy.address, 6_000, {"from": gov})

    strategy.harvest()
    assert (
        pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == sixty_percent
    )


def test_sweep(gov, vault, strategy, want, user, amount):
    want.transfer(strategy, amount, {"from": user})
    assert want.address == strategy.want()
    assert want.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(want, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault, {"from": gov})


def test_triggers(chain, gov, vault, strategy, want, amount, user):
    # Deposit to the vault and harvest
    want.approve(vault, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
