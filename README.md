# Coven contracts

Smart contracts behind [Coven](https://coven.network), a swap platform on Arc. Coven routes trades through Uniswap v3 and v4 pools on Arc and can deliver the output as USDC on another chain through Circle's CCTP.

There are five contracts.

`CovenRouter` executes swaps and holds the fee and safety settings. `CovenLens` finds and prices the best route for a trade; it stores nothing, and apps call it with `eth_call` rather than sending it transactions. `CovenSession` is a delegated-trading wallet that lets an automated agent trade an owner's balance inside caps the owner sets. `CovenSessionFactory` deploys sessions and records the ones it created. `CovenArb` is a permissionless arbitrage executor that flash-borrows from the v4 PoolManager and pays the caller any profit.

The contracts were reviewed in September 2026; the report is in [audit/](audit/) and the findings it raised have been fixed. They have not had a third-party audit.

## Deployments

Arc mainnet (chain ID 5042), deployed 23 September 2026.

| Contract | Address |
| --- | --- |
| CovenRouter | `0x5b86f1e5d95eFe358004B4484bF0a8C386c419a8` |
| CovenLens | `0x098Bb65C8aBBfF80c91e2A72A4A1439D31770fed` |
| CovenSessionFactory | `0xC7d8306A78e91d0C4fA0e5Ad6D1278A73767b057` |
| CovenArb | `0xFFAEFEA08cD27e9f0CA6A7e7ce3047e924cb663e` |

Sessions have no fixed address; the factory deploys one per owner with CREATE2.

The router and lens deployed on 19 September 2026 at `0xA13b8d54…` and `0xc041C074…` predate the review and should not be used.

## Routing

For a token pair, the lens checks Uniswap v3 pools and hookless v4 pools at the four standard fee tiers (0.01%, 0.05%, 0.3% and 1%). It also tries two-hop routes through USDC or EURC, plus any extra v4 pools the caller passes in. Each candidate is priced by running Uniswap's swap math against the pool's current state, so the price reflects liquidity depth and price impact as well as the fee. The route with the largest output wins.

The caller sets a maximum price impact. A pool that can't fill the whole amount within that limit is skipped.

The impact limit bounds the price range a quote walks, but not how many initialised ticks sit inside it, and anyone can add ticks to a pool. A separate step budget (`MAX_SWAP_STEPS`) caps the total number of tick crossings across a whole `quote` call, shared by every candidate pool it considers. A pool that would exhaust the budget is skipped rather than allowed to run the call out of gas. Ordinary routes use a small fraction of it.

Some v4 hooks can change the result of a swap. Pools with those hooks are considered only if the router allows the hook (see [Hooks](#hooks)), and they are priced with Uniswap's V4Quoter because the hook's own code decides the outcome.

In the test suite, lens quotes match Uniswap's deployed quoters exactly, and swaps through the router pay out exactly the quoted amount when pool state hasn't changed in between.

## Swaps

`swap` takes an input token and amount, a route from the lens, a minimum output and a deadline. The router pulls the input from the caller, runs each hop, checks the minimum and sends the output to the recipient. Each hop has to use its full input. If a pool runs out of liquidity partway through, the transaction reverts rather than filling part of the order.

`swapAndBridge` runs the same kind of swap, which must end in USDC, and then burns the output through CCTP V2 so it can be minted on the destination chain. The caller passes the CCTP parameters, including optional hook data such as a request for Circle's Forwarding Service. The whole output is bridged, so nothing is left behind on Arc.

Routes use the ERC-20 interface of Arc's USDC. v4 pools that hold native USDC are not supported.

## Fees

Every swap pays a platform fee set by the contract owner and capped at 1%. Apps that integrate Coven can add their own fee of up to 3% per swap, sent directly to an address they choose. The two fees are independent, so an integrator can't lower or redirect the platform fee.

If USDC is on either side of a trade, both fees are paid in USDC: from the input when buying and from the output when selling. For other pairs they come out of the input token. The minimum output is checked after fees.

Fees are paid out during the swap. If a payment fails, because the recipient has been frozen by the token issuer for instance, the amount is credited instead and the recipient withdraws it later with `claimFees`. A fee recipient that can't receive therefore doesn't stop anyone else from trading. Accrued fees are reserved: `sweep` can only take what is left over.

## Hooks

Uniswap v4 pools can have hook contracts attached, and a hook with swap permissions can change what a trader receives. The router only routes through such a pool when its hook is allowed. A hook can be allowed in two ways.

The owner can allow a specific hook address.

The owner can also register a hook template. Launchpads often deploy a separate hook for each token from the same code, changing only a few constants such as the token address and fee settings. A template records that code with the positions of those constants zeroed out, and any hook whose code matches is allowed. Up to eight templates can be registered at once.

Each masked position is an `(offset, length)` pair, so a template masks exactly the bytes a constant occupies: twenty for an address, two for a `uint16`. Registration walks the reference contract's bytecode and rejects any window that reaches outside a PUSH immediate, which stops a template from accidentally blanking executable code and admitting hooks that do something else. A template also records the hook's permission bits, and a candidate has to match those too, because in v4 the same code at an address with different bits is a different hook.

Masking a constant means clones may set it to anything, so registering a template is a decision about the masked values as much as the code. Review both.

A hook with no swap permissions still can't intervene in a swap, but it can set the fee on a dynamic-fee pool, up to 100%, at any time. Pools are therefore routed without an allowlist check only when the hook has no swap permissions *and* the pool's fee is static.

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

Keep the fee recipient on a different address from the owner. Arc USDC can be frozen, and if one address is both, a freeze takes out the fee income and the key that would rotate it.

None of the owner's powers reach user wallets. The worst a compromised owner could do is raise the fee to 1%, redirect fee income, or allow a malicious hook. A malicious hook can take at most what the trader's slippage setting permits, because the router enforces the minimum output on every swap.

## Sessions

A session lets an owner hand trading authority to an automated agent without handing over the wallet. The owner approves tokens to the session contract and sets a session key. That key can then call `executeSwap`, and proceeds always go to the owner. The session never holds a balance between trades.

What the key can do is bounded by an expiry, a per-trade and daily cap for each allowed token, a cap on trades per day, a price-impact ceiling and a slippage ceiling. Every trade is priced on-chain through the lens at execution time, and the minimum output is derived from that price and the slippage ceiling. A caller may ask for a tighter minimum than the contract's own, never a looser one, so a key that misbehaves still can't trade at a bad price.

Raising any limit takes effect only after a delay the owner fixes at creation, at least an hour. Lowering a limit, revoking a token, disabling the session key and revoking the session all take effect immediately. Daily caps use a fixed window that resets once a full day has passed since the window opened, so a burst spanning a window boundary can move up to two days' worth.

Create sessions through `CovenSessionFactory`, which forces the canonical router and lens into the configuration and records what it created. A session is owned by whoever called `create`.

## Arbitrage

`CovenArb` executes a plan of up to four swap legs inside a single v4 unlock, flash-borrowing whatever the first leg needs from the PoolManager. It checks that the plan ends with a positive balance in the profit token, keeps a share of that profit, and sends the rest to the caller. Anyone can call it. It holds no funds and owns no user approvals.

The owner sets the fee share, capped at 20%. Each plan names the highest fee it will accept, so a fee change can't reprice a transaction that is already in flight. Fees accrue as ERC-6909 claims inside the PoolManager rather than as transfers, so a recipient that can't receive a token can't block anyone's arbitrage. Redeeming those claims means calling the PoolManager inside an unlock, so point the fee recipient at an address that can do that.

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
  CovenSession.sol
  CovenSessionFactory.sol
  CovenArb.sol
  interfaces/
    ICovenRouter.sol
    external/            Uniswap v3, V4Quoter and CCTP interfaces
test/
  CovenRouter.t.sol
  CovenLens.t.sol
  CovenSession.t.sol
  CovenSessionFactory.t.sol
  CovenArb.t.sol
  LivePools.t.sol        quotes and swaps against live Arc pools
  audit/                 adversarial and regression tests, runnable without an RPC
  utils/                 fork fixture, test tokens, liquidity helper, test hooks
script/
  Deploy.s.sol           router and lens
  DeployFactory.s.sol    session factory
  DeployArb.s.sol        arbitrage executor
audit/
  2026-09-23-security-review.md
```

`../deploy-all.sh` runs all three scripts in order and checks the result.

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
