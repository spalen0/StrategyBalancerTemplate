import pytest
import brownie
import eth_utils
import eth_abi
from eth_abi.packed import encode_abi_packed


def test_profitable_harvest(
    chain,
    want,
    bal,
    vault,
    strategy,
    amount,
    user,
    strategist,
    yearn_balancer_voter,
    gauge,
    balancer_vault,
    multicall_swapper,
    ymechs_safe,
    trade_factory,
    accounts,
    RELATIVE_APPROX,
):
    want.approve(vault, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    assert gauge.balanceOf(yearn_balancer_voter) == amount

    chain.sleep(60 * 60 * 24 * 7)

    strategy.harvest({"from": strategist})

    assert bal.balanceOf(strategy) > 0
    assert (
        pytest.approx(bal.balanceOf(yearn_balancer_voter), rel=RELATIVE_APPROX)
        == bal.balanceOf(strategy) / 9
    )  # should have moved 10% of tokens in

    assert want.balanceOf(vault) == 0  # no profit yet since BAL hasn't been sold

    token_in = bal
    token_out = want
    receiver = strategy.address
    amount_in = token_in.balanceOf(strategy)
    asyncTradeExecutionDetails = [strategy, token_in, token_out, amount_in, 1]

    optimizations = [["uint8"], [5]]
    a = optimizations[0]
    b = optimizations[1]

    calldata = token_in.approve.encode_input(balancer_vault, amount_in)
    t = createTx(token_in, calldata)
    a = a + t[0]
    b = b + t[1]

    pool_BAL_WETH = "0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014"
    pool_DAI_WETH = "0x0b09dea16768f0799065c475be02919503cb2a3500020000000000000000001a"
    pool_boosted_DAI = (
        "0x804cdb9116a10bb78768d3252355a1b18067bf8f0000000000000000000000fb"
    )
    pool_boosted_USD = (
        "0x7b50775383d3d6f0215a8f290f2c9e2eebbeceb20000000000000000000000fe"
    )

    token_BAL = "0xba100000625a3754423978a60c9317c58a424e3D"
    token_WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    token_DAI = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
    token_bb_a_DAI = "0x804CdB9116a10bB78768D3252355a1b18067bF8f"
    token_bb_a_USD = "0x7B50775383d3D6f0215A8F290f2C9e2eEBBEceb2"

    swap_steps = [
        {
            "poolId": pool_BAL_WETH,
            "assetIn": token_BAL,
            "assetOut": token_WETH,
            "amount": amount_in,
        },
        {
            "poolId": pool_DAI_WETH,
            "assetIn": token_WETH,
            "assetOut": token_DAI,
            "amount": 0,
        },
        {
            "poolId": pool_boosted_DAI,
            "assetIn": token_DAI,
            "assetOut": token_bb_a_DAI,
            "amount": 0,
        },
        {
            "poolId": pool_boosted_USD,
            "assetIn": token_bb_a_DAI,
            "assetOut": token_bb_a_USD,
            "amount": 0,
        },
    ]

    token_addresses = list(
        [token_BAL, token_WETH, token_DAI, token_bb_a_DAI, token_bb_a_USD]
    )
    token_addresses.sort()
    token_indices = {token_addresses[idx]: idx for idx in range(len(token_addresses))}

    user_data_encoded = eth_abi.encode_abi(["uint256"], [0])
    swaps_step_structs = []
    for step in swap_steps:
        swaps_step_struct = (
            step["poolId"],
            token_indices[step["assetIn"]],
            token_indices[step["assetOut"]],
            int(step["amount"]),
            user_data_encoded,
        )
        swaps_step_structs.append(swaps_step_struct)

    token_limits = [2 ** 200 for token in token_addresses]

    fund_management = (strategy.address, False, strategy.address, False)
    swap_kind = 0  # GIVEN_IN

    calldata = balancer_vault.batchSwap.encode_input(
        swap_kind,
        swaps_step_structs,
        token_addresses,
        fund_management,
        token_limits,
        2 ** 255,
    )
    t = createTx(balancer_vault, calldata)
    a = a + t[0]
    b = b + t[1]

    transaction = encode_abi_packed(a, b)

    # trade_factory.execute['tuple,address,bytes'](asyncTradeExecutionDetails,
    #     multicall_swapper.address, transaction, {"from": ymechs_safe}
    # )
    # print(token_out.balanceOf(trade_factory))
    # # assert False

    strategy_account = accounts.at(strategy.address, force=True)
    bal.approve(balancer_vault, amount_in, {"from": strategy_account})
    balancer_vault.batchSwap(
        swap_kind,
        swaps_step_structs,
        token_addresses,
        fund_management,
        token_limits,
        2 ** 255,
        {"from": strategy_account},
    )  # for now simulating yswaps this way

    chain.sleep(1)

    strategy.harvest({"from": strategist})

    assert want.balanceOf(vault) > 0  # some profits

    vault.withdraw({"from": user})
    assert want.balanceOf(user) > amount


def createTx(to, data):
    inBytes = eth_utils.to_bytes(hexstr=data)
    return [["address", "uint256", "bytes"], [to.address, len(inBytes), inBytes]]


def test_remove_trade_factory(strategy, gov, trade_factory, bal):
    assert strategy.tradeFactory() == trade_factory.address
    assert bal.allowance(strategy.address, trade_factory.address) > 0

    strategy.removeTradeFactoryPermissions({"from": gov})

    assert strategy.tradeFactory() != trade_factory.address
    assert bal.allowance(strategy.address, trade_factory.address) == 0
