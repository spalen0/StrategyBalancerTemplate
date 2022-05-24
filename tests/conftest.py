import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def whale(accounts):
    address = "0x10A19e7eE7d7F8a52822f6817de8ea18204F2e4f"  # Balancer DAO multisig, might need to be changed if they dispose of it
    yield accounts.at(address, force=True)


@pytest.fixture
def trade_factory():
    yield Contract("0x99d8679bE15011dEAD893EB4F5df474a4e6a8b29")


@pytest.fixture
def ymechs_safe():
    yield Contract("0x2C01B4AD51a67E2d8F02208F54dF9aC4c0B778B6")


@pytest.fixture
def balancer_vault():
    yield Contract("0xBA12222222228d8Ba445958a75a0704d566BF2C8")


@pytest.fixture(scope="module")
def multicall_swapper(interface):
    yield interface.MultiCallOptimizedSwapper(
        "0xB2F65F254Ab636C96fb785cc9B4485cbeD39CDAA"
    )


@pytest.fixture
def want():
    token_address = "0x7B50775383d3D6f0215A8F290f2C9e2eEBBEceb2"  # boosted pool token
    yield Contract(token_address)


@pytest.fixture
def bal():
    token_address = "0xba100000625a3754423978a60c9317c58a424e3D"
    yield Contract(token_address)


@pytest.fixture
def amount(want, user, whale):
    amount = 10 * (10 ** 18)
    want.transfer(user, amount, {"from": whale})
    yield amount


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, want):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(want, gov, rewards, "", "", guardian, management, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5


@pytest.fixture
def gauge():
    gauge_address = "0x68d019f64A7aa97e2D4e7363AEE42251D08124Fb"
    yield Contract(gauge_address)


@pytest.fixture
def gauge_factory():
    address = "0x4E7bBd911cf1EFa442BC1b2e9Ea01ffE785412EC"
    yield Contract(gauge_factory)


@pytest.fixture
def strategy(
    StrategyBalancerClonable,
    vault,
    trade_factory,
    ymechs_safe,
    keeper,
    strategist,
    gov,
    yearn_balancer_voter,
    voter_proxy,
    gauge,
):
    strategy = strategist.deploy(
        StrategyBalancerClonable,
        vault,
        voter_proxy,
        yearn_balancer_voter,
    )
    strategy.setKeeper(keeper, {"from": gov})
    trade_factory.grantRole(
        trade_factory.STRATEGY(),
        strategy.address,
        {"from": ymechs_safe, "gas_price": "0 gwei"},
    )
    strategy.setTradeFactory(trade_factory.address, {"from": gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    voter_proxy.approveStrategy(gauge, strategy, {"from": gov})

    yield strategy


@pytest.fixture
def yearn_balancer_voter(YearnBalancerVoter, strategist, gov):
    yearn_balancer_voter = strategist.deploy(YearnBalancerVoter)

    yearn_balancer_voter.setGovernance(gov, {"from": strategist})

    yield yearn_balancer_voter


@pytest.fixture
def voter_proxy(BalancerStrategyVoterProxy, yearn_balancer_voter, strategist, gov):
    voter_proxy = strategist.deploy(BalancerStrategyVoterProxy, yearn_balancer_voter)

    voter_proxy.setGovernance(gov, {"from": strategist})
    yearn_balancer_voter.setProxy(voter_proxy, {"from": gov})

    yield voter_proxy
