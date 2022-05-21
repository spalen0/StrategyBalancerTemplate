import pytest


def test_revoke_strategy_from_vault(
    chain, want, vault, strategy, strategist, amount, user, gov, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    want.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.revokeStrategy(strategy.address, {"from": gov})
    strategy.harvest({"from": strategist})
    assert pytest.approx(want.balanceOf(vault.address), rel=RELATIVE_APPROX) == amount


def test_revoke_strategy_from_strategy(
    chain, want, vault, strategy, amount, user, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    want.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    strategy.setEmergencyExit()
    strategy.harvest()
    assert pytest.approx(want.balanceOf(vault.address), rel=RELATIVE_APPROX) == amount
