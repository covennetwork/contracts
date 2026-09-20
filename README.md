# Coven contracts

Smart contracts behind [Coven](https://coven.network), a swap platform on Arc. Coven routes trades through Uniswap v3 and v4 pools on Arc and can deliver the output as USDC on another chain through Circle's CCTP.

There are two contracts. `CovenRouter` executes swaps and holds the fee and safety settings. `CovenLens` finds and prices the best route for a trade. It stores nothing, and apps call it with `eth_call` rather than sending it transactions.

The contracts have not been audited.

## Deployments

Arc mainnet (chain ID 5042).

| Contract | Address |
| --- | --- |
| CovenRouter | TBD |
| CovenLens | TBD |

## Routing

For a token pair, the lens checks Uniswap v3 pools and hookless v4 pools at the four standard fee tiers (0.01%, 0.05%, 0.3% and 1%). It also tries two-hop routes through USDC or EURC, plus any extra v4 pools the caller passes in. Each candidate is priced by running Uniswap's swap math against the pool's current state, so the price reflects liquidity depth and price impact as well as the fee. The route with the largest output wins.

The caller sets a maximum price impact. A pool that can't fill the whole amount within that limit is skipped. The limit also caps how much work a quote does, so a single thin pool can't push the call over an RPC gas limit.

Some v4 hooks can change the result of a swap. Pools with those hooks are considered only if the router allows the hook (see [Hooks](#hooks)), and they are priced with Uniswap's V4Quoter because the hook's own code decides the outcome.

In the test suite, lens quotes match Uniswap's deployed quoters exactly, and swaps through the router pay out exactly the quoted amount when pool state hasn't changed in between.

## Swaps

`swap` takes an input token and amount, a route from the lens, a minimum output and a deadline. The router pulls the input from the caller, runs each hop, checks the minimum and sends the output to the recipient. Each hop has to use its full input. If a pool runs out of liquidity partway through, the transaction reverts rather than filling part of the order.

`swapAndBridge` runs the same kind of swap, which must end in USDC, and then burns the output through CCTP V2 so it can be minted on the destination chain. The caller passes the CCTP parameters, including optional hook data such as a request for Circle's Forwarding Service. The whole output is bridged, so nothing is left behind on Arc.

Routes use the ERC-20 interface of Arc's USDC. v4 pools that hold native USDC are not supported.

## Fees

Every swap pays a platform fee set by the contract owner and capped at 1%. Apps that integrate Coven can add their own fee of up to 3% per swap, sent directly to an address they choose. The two fees are independent, so an integrator can't lower or redirect the platform fee.

If USDC is on either side of a trade, both fees are paid in USDC: from the input when buying and from the output when selling. For other pairs they come out of the input token. The minimum output is checked after fees.

## Hooks

Uniswap v4 pools can have hook contracts attached, and a hook with swap permissions can change what a trader receives. The router only routes through such a pool when its hook is allowed. A hook can be allowed in two ways.

The owner can allow a specific hook address.

The owner can also register a hook template. Launchpads often deploy a separate hook for each token from the same code, changing only a few constants such as the token address and fee settings. A template records that code with the positions of those constants zeroed out, and any hook whose code matches is allowed. The owner reviews the template code and masks only positions that hold constants, so a matching hook runs the same logic as the reviewed one. Up to eight templates can be registered at once.

Hooks without swap permissions can't affect a trade. Pools that use them are routed without an allowlist check.

## Security model

The router holds no funds between transactions. It only pulls tokens from the address that called it, so nobody else can spend an approval given to the router. The router's own approvals to Uniswap and CCTP cover the exact amount of each call and are cleared afterward. The contracts can't be upgraded.

The owner is a multisig wallet and can:

- change the platform fee, up to the 1% cap
- change the address that receives platform fees
- allow or remove hooks and hook templates
- pause and unpause swaps
- set the guardian
- recover tokens sent to the router by mistake

The guardian can pause swaps but can't unpause them. A pause blocks new swaps and has no effect on anyone's funds. Ownership transfers take two steps, and ownership can't be renounced.

None of the owner's powers reach user wallets. The worst a compromised owner could do is raise the fee to 1%, redirect fee income, or allow a malicious hook. A malicious hook can take at most what the trader's slippage setting permits, because the router enforces the minimum output on every swap.

## Arc contracts used

| Contract | Address |
| --- | --- |
| USDC | `0x3600000000000000000000000000000000000000` |
| Uniswap v3 factory | `0xf0db7b58379503491d857dB50AC9ece64c653918` |
| Uniswap SwapRouter02 | `0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap V4Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| CCTP TokenMessengerV2 | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |

## Repository layout

```
src/
  CovenRouter.sol
  CovenLens.sol
  interfaces/
    ICovenRouter.sol
    external/            Uniswap v3, V4Quoter and CCTP interfaces
test/
  CovenRouter.t.sol
  CovenLens.t.sol
  LivePools.t.sol        quotes and swaps against live Arc pools
  utils/                 fork fixture, test tokens, liquidity helper, test hooks
script/
  Deploy.s.sol
```

## Build and test

The tests run on a fork of Arc mainnet and use Arc's real USDC, Uniswap and CCTP contracts. Standard Foundry can't simulate Arc's native USDC, so you need [Arc Foundry](https://github.com/circlefin/arc-foundry).

```sh
arc-forge soldeer install
arc-forge build
arc-forge test --network arc
```

Arc's public RPC rate-limits heavy traffic. If tests fail with HTTP 429 errors, run them on fewer threads with `-j 2`.

## License

MIT
