import pytest
from brownie import config, Wei, Contract

# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

use_tenderly = False


################################################## TENDERLY DEBUGGING ##################################################

# change autouse to True if we want to use this fork to help debug tests
@pytest.fixture(scope="session", autouse=use_tenderly)
def tenderly_fork(web3, chain):
    fork_base_url = "https://simulate.yearn.network/fork"
    payload = {"network_id": str(chain.id)}
    resp = requests.post(fork_base_url, headers={}, json=payload)
    fork_id = resp.json()["simulation_fork"]["id"]
    fork_rpc_url = f"https://rpc.tenderly.co/fork/{fork_id}"
    print(fork_rpc_url)
    tenderly_provider = web3.HTTPProvider(fork_rpc_url, {"timeout": 600})
    web3.provider = tenderly_provider
    print(f"https://dashboard.tenderly.co/yearn/yearn-web/fork/{fork_id}")


################################################ UPDATE THINGS BELOW HERE ################################################


@pytest.fixture(scope="session")
def tests_using_tenderly():
    yes_or_no = use_tenderly
    yield yes_or_no



@pytest.fixture(scope="module")
def whale(accounts):
    # Totally in it for the tech
    # Update this with a large holder of your want token (the largest EOA holder of LP)
    whale = accounts.at("0xc5ae4b5f86332e70f3205a8151ee9ed9f71e0797", force=True)
    yield whale


# this is the amount of funds we have our whale deposit. adjust this as needed based on their wallet balance
@pytest.fixture(scope="module")
def amount():
    amount = 1e23
    yield amount


# this is the name we want to give our strategy
@pytest.fixture(scope="module")
def strategy_name():
    strategy_name = "StrategyCurvesUSD"
    yield strategy_name


# Only worry about changing things above this line, unless you want to make changes to the vault or strategy.
# ----------------------------------------------------------------------- #


@pytest.fixture(scope="function")
def voter():
    yield Contract("0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26")


@pytest.fixture(scope="function")
def crv():
    yield Contract("0x0994206dfE8De6Ec6920FF4D779B0d950605Fb53")


@pytest.fixture(scope="module")
def other_vault_strategy():
    yield Contract("0xfF8bb7261E4D51678cB403092Ae219bbEC52aa51")


@pytest.fixture(scope="module")
def farmed():
    yield Contract("0x4200000000000000000000000000000000000042")


@pytest.fixture(scope="module")
def healthCheck():
    yield Contract("0x3d8F58774611676fd196D26149C71a9142C45296")


# Define relevant tokens and contracts in this section
@pytest.fixture(scope="module")
def token():
    # this should be the address of the ERC-20 used by the strategy/vault
    token_address = "0x061b87122ed14b9526a813209c8a59a633257bab"
    yield Contract(token_address)


# zero address
@pytest.fixture(scope="module")
def zero_address():
    zero_address = "0x0000000000000000000000000000000000000000"
    yield zero_address


# gauge for the curve pool
@pytest.fixture(scope="module")
def gauge():
    # this should be the address of the convex deposit token
    gauge = "0xc5ae4b5f86332e70f3205a8151ee9ed9f71e0797"
    yield Contract(gauge)


# curve deposit pool
@pytest.fixture(scope="module")
def pool():
    poolAddress = Contract("0x061b87122ed14b9526a813209c8a59a633257bab")
    yield poolAddress

@pytest.fixture(scope="session")
def has_rewards():
    has_rewards = True  # false for all ETH
    yield has_rewards

@pytest.fixture(scope="session")
def rewards_token():  # OP
    yield Contract("0x4200000000000000000000000000000000000042")


# Define any accounts in this section
# for live testing, governance is the strategist MS; we will update this before we endorse
# normal gov is ychad, 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52
@pytest.fixture(scope="module")
def gov(accounts):
    yield accounts.at("0xF5d9D6133b698cE29567a90Ab35CfB874204B3A7", force=True)


@pytest.fixture(scope="module")
def strategist_ms(accounts):
    # like governance, but better
    yield accounts.at("0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26", force=True)


@pytest.fixture(scope="module")
def keeper(accounts):
    yield accounts.at("0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26", force=True)


@pytest.fixture(scope="module")
def rewards(accounts):
    yield accounts.at("0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26", force=True)


@pytest.fixture(scope="module")
def guardian(accounts):
    yield accounts[2]


@pytest.fixture(scope="module")
def management(accounts):
    yield accounts[3]


@pytest.fixture(scope="module")
def strategist(accounts):
    yield accounts.at("0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26", force=True)

@pytest.fixture(scope="session")
def contract_name(StrategyCurve3PoolClonable):
    contract_name = StrategyCurve3PoolClonable
    yield contract_name

@pytest.fixture(scope="session")
def is_clonable():
    is_clonable = True
    yield is_clonable

@pytest.fixture(scope="session")
def sleep_time():
    yield 86_400

@pytest.fixture(scope="session")
def is_convex():
    yield False

@pytest.fixture(scope="function")
def vault_address(vault):
    yield vault.address

@pytest.fixture(scope="session")
def rewards_template():
    rewards_template = True 
    yield rewards_template

@pytest.fixture(scope="session")
def sushi_router():  # use this to check our allowances
    yield Contract("0xE592427A0AEce92De3Edee1F18E0157C05861564")

# # list any existing strategies here
# @pytest.fixture(scope="module")
# def LiveStrategy_1():
#     yield Contract("0xC1810aa7F733269C39D640f240555d0A4ebF4264")


# use this if you need to deploy the vault
@pytest.fixture(scope="function")
def vault(pm, gov, rewards, guardian, management, token, chain):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    chain.sleep(1)
    yield vault


# use this if your vault is already deployed
# @pytest.fixture(scope="function")
# def vault(pm, gov, rewards, guardian, management, token, chain):
#     vault = Contract("0x497590d2d57f05cf8B42A36062fA53eBAe283498")
#     yield vault


# replace the first value with the name of your strategy
@pytest.fixture(scope="function")
def strategy(
    StrategyCurve3PoolClonable,
    strategist,
    keeper,
    vault,
    gov,
    guardian,
    token,
    healthCheck,
    chain,
    pool,
    strategy_name,
    gauge,
    strategist_ms,
    has_rewards,
    rewards_token
):
    # make sure to include all constructor parameters needed here
    strategy = strategist.deploy(
        StrategyCurve3PoolClonable,
        vault,
        gauge,
        pool,
        strategy_name,
    )
    strategy.setKeeper(keeper, {"from": gov})
    if has_rewards:
        strategy.updateRewards(has_rewards, rewards_token, {"from": gov})
        # strategy.setFeeCRVETH(3000, {"from": gov})
        # strategy.setFeeOPETH(500, {"from": gov})
        # strategy.setFeeETHUSD(500, {"from": gov})
    # set our management fee to zero so it doesn't mess with our profit checking
    vault.setManagementFee(0, {"from": gov})
    # add our new strategy
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    strategy.setHealthCheck(healthCheck, {"from": gov})
    strategy.setDoHealthCheck(True, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)
    yield strategy


@pytest.fixture(scope="function")
def swap_route_usdt():
    yield "0000000000000000000000000994206dfe8de6ec6920ff4d779b0d950605fb530000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000420000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000001f400000000000000000000000094b008aa00579c1307b0ef2c499ad98a8ce58e58"
