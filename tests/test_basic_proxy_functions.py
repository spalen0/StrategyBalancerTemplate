import pytest
import brownie


def test_basic_proxy_functions(
    chain,
    voter_proxy,
    user,
    bal,
    whale,
    yearn_balancer_voter,
    balancer_smart_wallet_checker,
    balancer_dao_multisig,
    ve_bal,
    bal_weth_bpt,
    gauge,
    gov,
):
    with brownie.reverts("!governance"):
        voter_proxy.setGovernance(user, {"from": user})

    whale_bal_balance = bal.balanceOf(whale)

    original_bal_transfer = whale_bal_balance / 10

    bal.transfer(yearn_balancer_voter, original_bal_transfer, {"from": whale})

    balancer_smart_wallet_checker.allowlistAddress(
        yearn_balancer_voter, {"from": balancer_dao_multisig}
    )

    assert ve_bal.balanceOf(yearn_balancer_voter) == 0

    yearn_balancer_voter.convertBAL(original_bal_transfer, True, {"from": gov})
    yearn_balancer_voter.createLock(
        bal_weth_bpt.balanceOf(yearn_balancer_voter),
        chain.time() + (60 * 60 * 24 * 60),
        False,
        {"from": gov},
    )  # lock for 30 days

    with brownie.reverts():
        voter_proxy.vote(gauge, ve_bal.balanceOf(yearn_balancer_voter), {"from": user})

    voter_proxy.approveVoter(user, {"from": gov})

    voter_proxy.vote(gauge, 10000, {"from": user})
