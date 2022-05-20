import pytest


def test_operation(
    chain, want, vault, strategy, amount, user, strategist, RELATIVE_APPROX
):
    want.approve(vault, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
