import pytest
import brownie


def test_vote(
    chain,
    voter_proxy,
    user,
    bal,
    whale,
    yearn_balancer_voter,
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

    assert ve_bal.balanceOf(yearn_balancer_voter) == 0

    yearn_balancer_voter.convertLooseBALIntoBPT({"from": gov})
    yearn_balancer_voter.createLock(
        bal_weth_bpt.balanceOf(yearn_balancer_voter),
        chain.time() + (60 * 60 * 24 * 60),
        {"from": gov},
    )  # lock for 30 days

    with brownie.reverts():
        voter_proxy.vote(gauge, ve_bal.balanceOf(yearn_balancer_voter), {"from": user})

    voter_proxy.approveVoter(user, {"from": gov})

    voter_proxy.vote(gauge, 10000, {"from": user})
