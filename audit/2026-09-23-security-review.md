# Coven Protocol: Security Assessment

*Published copy: `docs/src/content/docs/reference/security-review.md`, rendered at /reference/security-review/. Keep the two in step.*

| | |
| --- | --- |
| Subject | Coven protocol contracts |
| Network | Arc mainnet, chain ID 5042 |
| Source revision | `c9f103d0d8dac3c225e23efb6bd14c6866bd559f` plus remediation |
| Assessment period | 23 September 2026 |
| Deployment date | 23 September 2026 |
| Deployment verified at | Block 22373658, 2026-09-23 16:11:02 UTC |
| Report version | 1.0 |
| Status | Final. All findings resolved. |

## 1. Disclaimer

This assessment was performed internally by the Coven engineering team. It is not a third-party audit and confers no warranty, guarantee, or certification. A security assessment is a time-boxed review of a specific revision of a codebase; it reduces risk but cannot establish the absence of defects. The findings below reflect the state of the code at the time of review. Subsequent modification of the contracts, the environments they depend on, or their configuration may invalidate any conclusion drawn here.

The assessment covers only the contracts listed in section 3.1. Uniswap v3 and v4, Circle's CCTP contracts, Arc USDC, and any hook contract not explicitly named are treated as trusted external dependencies and were not reviewed.

Readers should not rely on this document as the sole basis for a decision to interact with the protocol.

## 2. Risk Classification

Severity is derived from impact and likelihood.

| | Likelihood: High | Likelihood: Medium | Likelihood: Low |
| --- | --- | --- | --- |
| **Impact: High** | Critical | High | Medium |
| **Impact: Medium** | High | Medium | Low |
| **Impact: Low** | Medium | Low | Informational |

Impact measures the consequence of successful exploitation: loss of user funds, loss of protocol funds, or loss of a security property the system documents. Likelihood measures the preconditions an attacker must satisfy, the cost of satisfying them, and whether any privileged party must first err.

Informational findings record deviations from good practice that carry no direct exploit path.

## 3. Assessment Details

### 3.1 Scope

The following contracts were reviewed and are deployed at the addresses shown.

| Contract | Address | Runtime size |
| --- | --- | --- |
| CovenRouter | `0x5b86f1e5d95eFe358004B4484bF0a8C386c419a8` | 15,602 bytes |
| CovenLens | `0x098Bb65C8aBBfF80c91e2A72A4A1439D31770fed` | 14,489 bytes |
| CovenSessionFactory | `0xC7d8306A78e91d0C4fA0e5Ad6D1278A73767b057` | 15,471 bytes |
| CovenArb | `0xFFAEFEA08cD27e9f0CA6A7e7ce3047e924cb663e` | 7,576 bytes |

`CovenSession` is within scope. It has no fixed address; `CovenSessionFactory` deploys one instance per owner using CREATE2.

Also in scope: `src/interfaces/ICovenRouter.sol` and the external interface declarations under `src/interfaces/external/`.

Out of scope: the off-chain packages (`app`, `sdk`, `core`, `arb`, `mcp`), deployment scripts except as they affect deployed configuration, and all external protocol dependencies.

Build configuration: Solidity 0.8.37, IR pipeline enabled, optimizer at 10,000 runs, EVM target `osaka`. Dependencies pinned via Soldeer to forge-std 1.16.2, OpenZeppelin Contracts 5.7.0, and Uniswap v4-core 4.0.0 at revision `e50237c43811bd9b526eff40f26772152a42daba`.

### 3.2 Deployment Verification

The deployed runtime bytecode was retrieved from Arc mainnet at block 22373658 and compared against bytecode compiled locally from the remediated source under the build configuration above.

| Contract | Result |
| --- | --- |
| CovenRouter | Byte-for-byte identical |
| CovenArb | Byte-for-byte identical |
| CovenLens | Identical except 2 immutable slots |
| CovenSessionFactory | Identical except 6 immutable slots |

Every divergence resolves to an immutable assigned at construction, and each holds the expected value:

| Contract | Offsets | Value |
| --- | --- | --- |
| CovenLens | 156, 4927 | `0x5b86f1e5…c419a8`, the deployed CovenRouter |
| CovenSessionFactory | 259, 923, 1612 | `0x5b86f1e5…c419a8`, the deployed CovenRouter |
| CovenSessionFactory | 316, 960, 1690 | `0x098bb65c…770fed`, the deployed CovenLens |

No unexplained bytes were found in any of the four deployments. The deployed contracts therefore correspond to the reviewed source.

Deployed configuration was read from chain and matches the intended parameters:

| Parameter | Value |
| --- | --- |
| Router owner | `0x6a158A30Fcdc4e3B457ECd392eDabf9ECe3eBc3E` (contract account) |
| Router fee recipient | `0xca588AEEd8272711dF93a9245Bfc3e94d22B10E8` |
| Router guardian | `0xca588AEEd8272711dF93a9245Bfc3e94d22B10E8` |
| Platform fee | 30 bps |
| Paused | No |
| Registered hook templates | 1 |
| Explicitly allowed hooks | 1 |
| Arb fee | 1000 bps of realised profit |

### 3.3 Privileged Roles

| Role | Held by | Capabilities |
| --- | --- | --- |
| Router owner | Contract account, two-step transfer, renouncement disabled | Set platform fee within a 1% ceiling; set fee recipient; set guardian; add or remove hook allowances and templates; pause and unpause; recover unreserved token balances |
| Guardian | EOA or contract | Pause swaps. Cannot unpause |
| Arb owner | Contract account, renouncement disabled | Set arb fee within a 20% ceiling; set arb fee recipient; recover token balances |
| Session owner | End user | Set all session limits; rotate or disable the session key; revoke the session; recover token balances |
| Session key | Automated agent | Execute swaps within the owner's configured limits. No other capability |

No privileged role can transfer or spend tokens held in a user wallet. The maximum loss attributable to a fully compromised router owner is a platform fee of 1%, redirection of fee income, and admission of a hostile hook whose effect on any individual trade remains bounded by that trade's minimum output.

### 3.4 Methodology

The assessment consisted of a line-by-line manual review of the in-scope contracts, conducted against the vendored copies of Uniswap v4-core and OpenZeppelin Contracts in the repository's `dependencies/` directory, so that library behaviour was confirmed against the exact code linked into the build.

Particular attention was given to:

- Accounting across the Uniswap v4 unlock and callback boundary, including delta settlement and the conditions under which the PoolManager reverts an unsettled lock
- The hook allowlist and hook template mechanism, including the relationship between a hook's runtime code and the permission bits encoded in its address
- Fee derivation, rounding direction, and the token in which each fee is denominated
- Token-transfer assumptions, covering fee-on-transfer behaviour and issuer-controlled denylists on Arc USDC
- Reentrancy across all external call sites, including calls into attacker-influenced hook contracts
- Access control on every state-changing function and on both external callbacks
- Gas-bounded loops and their behaviour under adversarially constructed pool state

Findings that could be reproduced without mainnet state were developed into proof-of-concept tests. Those tests were subsequently inverted into regression tests that fail if a remediation is reverted; they reside in `contracts/test/audit/`. The gas figures supporting H-02 were measured, not estimated.

The fork-based test suites require an Arc mainnet RPC endpoint and were not executed during the assessment. The offline suite comprises 47 tests, all passing against the remediated source.

## 4. System Summary

`CovenRouter` executes swaps. It transfers the input token from the caller, routes through up to four hops across Uniswap v3 (via SwapRouter02) or Uniswap v4 (via the PoolManager unlock callback), deducts a platform fee capped at 1% and an optional integrator fee capped at 3%, enforces a minimum output, and forwards the proceeds. `swapAndBridge` performs an equivalent swap that must terminate in USDC and burns the result through CCTP V2. The contract retains no balance between transactions other than fees that could not be delivered, and is not upgradeable.

`CovenLens` prices routes. It holds no state and is intended for `eth_call`. For a given pair it evaluates Uniswap v3 and hookless v4 pools across four standard fee tiers, evaluates two-hop routes through caller-supplied connectors, and prices each candidate by executing Uniswap's swap mathematics against live pool state. Pools with swap-permissioned hooks are priced through Uniswap's V4Quoter, and only where the router's allowlist admits the hook.

`CovenSession` is a delegated-trading contract. An owner approves tokens to the session and assigns a session key to an automated agent. The session constrains that key by expiry, per-trade and daily caps per token, a trade count cap, a maximum price impact, and a maximum slippage. Increases to any limit are subject to a delay of no less than one hour; decreases, key rotation to the zero address, and revocation take effect immediately. Proceeds are paid to the owner.

`CovenSessionFactory` deploys sessions via CREATE2 and records those it created.

`CovenArb` is a permissionless arbitrage executor. A caller submits a plan of up to four legs; the contract borrows from the Uniswap v4 PoolManager within a single lock, executes the legs, requires a positive delta in the nominated profit token, retains a fee as ERC-6909 claims, and transfers the remainder to the caller.

## 5. Executive Summary

The assessment identified 17 findings: 1 critical, 2 high, 4 medium, and 10 low. All have been resolved. Remediation was applied prior to deployment and is present in the deployed bytecode, as established in section 3.2.

The router and lens demonstrated a consistently defensive implementation. Fee accounting is derived from measured balance deltas rather than assumed transfer amounts, external approvals are scoped to a single call and cleared afterwards, and an exact-fill invariant is enforced on every hop, which eliminates the partial-fill class of defect common to routing contracts. The Uniswap v4 unlock callback and the ERC-6909 fee accrual path in `CovenArb` were both found correct.

The most significant finding, C-01, concerned `CovenSession`. The contract obtained an authoritative on-chain price for every trade and then did not constrain execution against it, deriving its slippage floor exclusively from a value supplied by the caller. Because the caller is the session key, the single guarantee the contract exists to provide did not hold.

Two further findings identified violations of security properties asserted in the protocol's own documentation. H-01 established that the hook allowlist did not apply to dynamic-fee pools, permitting an unreviewed hook to control the effective swap fee. H-02 established that the price-impact ceiling bounded the price range traversed by a quote but not the computational work performed within it, an asymmetry an attacker could exploit at low cost.

### Issues Found

| Severity | Count | Resolved |
| --- | --- | --- |
| Critical | 1 | 1 |
| High | 2 | 2 |
| Medium | 4 | 4 |
| Low | 10 | 10 |
| **Total** | **17** | **17** |

| ID | Title | Severity | Status |
| --- | --- | --- | --- |
| C-01 | Slippage floor derived exclusively from caller-supplied input | Critical | Resolved |
| H-01 | Dynamic-fee pools bypass the hook allowlist | High | Resolved |
| H-02 | Quote execution cost unbounded in initialised tick count | High | Resolved |
| M-01 | Hook templates bind runtime code but not permission bits | Medium | Resolved |
| M-02 | Template mask windows are unconstrained | Medium | Resolved |
| M-03 | Undeliverable platform fee halts all swaps | Medium | Resolved |
| M-04 | Factory attests sessions it does not authenticate | Medium | Resolved |
| L-01 to L-10 | See section 6.4 | Low | Resolved |

## 6. Findings

### 6.1 Critical

#### C-01 Slippage floor derived exclusively from caller-supplied input

**Severity** Critical (Impact: High, Likelihood: High)
**Target** `CovenSession.executeSwap`
**Status** Resolved

**Description.** `executeSwap` obtained a route and an output estimate from `CovenLens` within the same transaction and assigned the estimate to a local variable, `gross`. That variable was subsequently referenced only to determine whether a viable route existed. The minimum output enforced against the swap was computed exclusively from `expectedOut`, a function parameter:

```solidity
uint256 minOut = expectedOut * (BPS - slippageBps) / BPS;
if (minOut == 0) revert ZeroMinOut();
```

`executeSwap` is callable by the session key. The session key is therefore able to select the reference value against which its own execution is measured. The only lower bound applied was the `ZeroMinOut` check, which rejects a minimum that rounds to zero and is satisfied by any value above a few thousand wei.

**Impact.** The configured `maxSlippageBps` provided no constraint on a session key that chose to understate `expectedOut`. A session key could execute trades at an arbitrary price up to the configured caps. Because caps are accounted against the input token, alternating buy and sell operations charge the USDC cap on one leg and the token cap on the other, permitting extraction across both allowances within a single window until the trade count cap is reached.

Exploitation does not require key theft. Session keys are held by automated agents; a compromised, defective, or prompt-injected agent produces the same outcome. Likelihood is assessed as high because the contract's stated purpose is to bound a semi-trusted key, and the defect nullifies that bound.

**Exploit scenario.** An owner configures a session with `maxSlippageBps = 100` and a per-trade cap of 1,000 USDC. The lens quotes 1,000e18 units of output for a 1,000 USDC input. The session key submits `expectedOut = 1000` wei. The resulting minimum output is 990 wei. The key routes the trade through a pool it has positioned itself against and retains the difference. `maxSlippageBps()` continues to return 100 throughout.

**Proof of concept.** Reproduced in `test/audit/FindingsRegression.t.sol`. The test configures a session matching the project's own fixture, supplies an honest lens quote of 1,000e18, and confirms that a 1,000 USDC input settles for 1,000 wei of output.

**Recommendation.** Derive the floor from the quote obtained within the transaction and permit `expectedOut` to tighten it but never to relax it.

**Resolution.** Implemented as recommended:

```solidity
uint256 netQuote = tokenOut == USDC ? gross - gross * ROUTER.platformFeeBps() / BPS : gross;
uint256 floor = netQuote * (BPS - slippageBps) / BPS;
uint256 minOut = expectedOut > floor ? expectedOut : floor;
```

Both bounds are now applied and the stricter governs. Retaining `expectedOut` is deliberate. A value carried from an earlier simulation detects price movement between simulation and execution, which a quote taken within the execution transaction cannot, as that quote already incorporates the movement. The contract-derived floor addresses the case the original design did not, namely a caller that understates the reference. Neither bound subsumes the other.

### 6.2 High

#### H-01 Dynamic-fee pools bypass the hook allowlist

**Severity** High (Impact: Medium, Likelihood: High)
**Target** `CovenRouter._hop`, `CovenLens._bestLeg`
**Status** Resolved

**Description.** Both contracts determined whether a Uniswap v4 pool required an allowlisted hook by testing four swap-permission bits in the hook address. The premise, stated in the protocol documentation, was that a hook holding no swap permissions cannot influence a trade. This holds for the hook callback path but not in general.

Uniswap v4 permits a hook with no permission bits to be attached to a pool with a dynamic fee. `PoolManager.updateDynamicLPFee` is gated solely on `msg.sender == key.hooks`; it requires no permission bit and accepts any value up to `MAX_LP_FEE`, which is 1,000,000, or 100%. Such a hook may therefore alter the effective swap fee at any time, including in the block preceding a pending trade. Both the router and the lens classified these pools as hookless and routed them without consulting the allowlist.

**Impact.** An unreviewed contract could determine the price of any swap routed through its pool. The loss on an individual trade remained bounded by that trade's minimum output, which is why impact is assessed as medium rather than high. Likelihood is assessed as high: the attack requires no error by a privileged party, and the lens will actively select such a pool while its hook advertises a competitive fee.

**Exploit scenario.** An attacker deploys a hook at an address carrying no swap-permission bits and initialises a pool with `fee = 0x800000`. The hook sets a low LP fee. The pool is surfaced through a discovery feed and passed to `CovenLens.quote` as an extra pool, where it prices competitively and is selected. Before the resulting swap is mined, the hook raises the LP fee. The trader receives the minimum their slippage setting permits.

**Proof of concept.** Reproduced in `test/audit/FindingsRegression.t.sol`, which routes a swap through a hook address holding only `BEFORE_DONATE_FLAG` on a pool with `fee = DYNAMIC_FEE_FLAG` and asserts both that `isHookAllowed` returns false and that the swap nevertheless succeeds.

**Recommendation.** Treat a dynamic fee as equivalent to a swap permission for allowlist purposes.

**Resolution.** Both contracts now require an allowlisted hook where the hook address is non-zero and either a swap-permission bit is set or the pool fee is dynamic. Pools combining a static fee with a hook that cannot intervene in a swap continue to route without a check. The documentation has been corrected.

#### H-02 Quote execution cost unbounded in initialised tick count

**Severity** High (Impact: Medium, Likelihood: High)
**Target** `CovenLens._simulate`
**Status** Resolved

**Description.** `_simulate` traverses a pool tick by tick until the input is consumed or a price limit is reached. The loop carried no iteration bound. Its only constraint was the price limit derived from `maxImpactBps`, which bounds the price range traversed but not the number of initialised ticks contained within that range. Tick density is determined by liquidity providers and is therefore attacker-controlled.

At the 0.01% fee tier, tick spacing is 1 and a 500 bps impact ceiling spans approximately 513 ticks. An attacker who establishes minimal-liquidity positions across that band forces the loop to cross each one. When the traversal reaches the price limit with input remaining, the function returns zero and the candidate is discarded, so the gas consumed produces no result.

**Impact.** `CovenLens.quote` is invoked by `eth_call` from client applications and by `CovenSession.executeSwap` within a transaction. In the first case, quoting for an affected pair fails once the call exceeds provider gas ceilings, which commonly fall between 10 and 50 million. In the second, the session's trades for that pair exceed the block gas limit and cease to execute. No owner-controlled parameter excludes a fee tier from evaluation, so recovery requires redeployment of the lens.

**Proof of concept.** Measured in `test/audit/LensGasBench.t.sol` against a pool in which every tick within range is initialised and net liquidity change is zero, which represents the minimum achievable per-tick cost and therefore a lower bound:

| Configuration | Gas |
| --- | --- |
| Direct leg, 100 bps ceiling (approx. 101 ticks) | 642,116 |
| Direct leg, 500 bps ceiling (approx. 513 ticks) | 3,214,693 |
| Direct leg, 1000 bps ceiling (approx. 1054 ticks) | 6,684,594 |
| Full quote, two connectors, one seeded pool | 9,898,177 |

The final measurement excludes Uniswap v4 candidates entirely; seeding the corresponding v4 pool approximately doubles it.

**Recommendation.** Bound the traversal directly rather than relying on the price ceiling to do so indirectly. The contract already applies an explicit gas ceiling to hooked quotes via `HOOKED_QUOTE_GAS`; the unhooked path warrants an equivalent constraint.

**Resolution.** `MAX_SWAP_STEPS`, set to 512, now bounds total tick crossings across an entire `quote` invocation and is shared by every candidate pool evaluated. A pool that would exhaust the budget is skipped rather than permitted to exhaust the call. Routing against pools of ordinary tick density consumes a small fraction of the budget.

### 6.3 Medium

#### M-01 Hook templates bind runtime code but not permission bits

**Severity** Medium (Impact: Medium, Likelihood: Low)
**Target** `CovenRouter.isHookAllowed`, `CovenRouter.addHookTemplate`
**Status** Resolved

**Description.** `isHookAllowed` compared a candidate hook's masked runtime code and code size against each registered template. The candidate's address was not considered. In Uniswap v4, behaviour is determined by the pair of runtime code and address, because the low 14 bits of the address select which callbacks the PoolManager invokes, and no protocol-level check confirms that the code implements the permissions the address asserts.

A template registered from a reference hook deployed at an address carrying one permission set therefore also admitted a clone deployed at an address carrying additional swap permissions. The reviewing owner approved one set of capabilities and implicitly authorised a larger set.

**Impact.** A launchpad, or any party able to mine a CREATE2 address, could obtain admission for a hook with capabilities the owner had not evaluated. Likelihood is assessed as low because it requires a template to be registered and an address to be mined for the escalated permission set.

**Recommendation.** Record the reference hook's permission bits in the template and require an exact match.

**Resolution.** Templates now store `uint160(referenceHook) & ALL_HOOK_MASK` and `isHookAllowed` requires the candidate's bits to match. Clones produced by a single launchpad share a permission set by construction, so the intended workflow is unaffected.

#### M-02 Template mask windows are unconstrained

**Severity** Medium (Impact: High, Likelihood: Low)
**Target** `CovenRouter.addHookTemplate`
**Status** Resolved

**Description.** `addHookTemplate` accepted arbitrary 32-byte offsets, validating only that they were ascending, non-overlapping, and within the bounds of the reference code. No check established that a masked window covered constant data rather than executable instructions. Any hook whose code matched outside the masked regions was admitted regardless of the content of those regions. The security of the mechanism rested entirely on the registering owner selecting offsets correctly.

The mask offsets prepared for the protocol's first production template, targeting the Argus launchpad hook at `0x399218a6395D79C695Ad4E95d53a6eD3914F2044`, were examined against the deployed runtime code. Each of the fourteen offsets identifies the correct starting position of a constant, but each was intended as a 32-byte window. Every offset begins inside a PUSH32 immediate without coinciding with its start, so every window extends beyond the end of that immediate into subsequent instructions. In aggregate the fourteen windows would have masked 448 bytes, of which 276 are executable code.

**Impact.** Any hook matching such a template could substitute arbitrary instructions within the masked regions while still being admitted by the allowlist, defeating the review the template represents.

**Recommendation.** Replace fixed 32-byte offsets with explicit `(offset, length)` windows so that a template masks precisely the bytes a constant occupies, and validate at registration that every window falls within PUSH immediate data.

**Resolution.** Mask windows are now `(offset, length)` pairs. Registration decodes the reference runtime code and rejects any window extending outside a PUSH immediate, reverting with `MaskCoversCode(offset)`. Under the corrected form the Argus template masks 172 bytes, comprising eight 20-byte addresses and six 2-byte values, and no executable code. `test/audit/ArgusTemplate.t.sol` registers the template against the deployed runtime code, confirms the reference hook matches, and confirms the original 32-byte form is rejected.

A residual property remains by design: masking a constant permits a matching clone to assign it any value. Template registration is consequently a decision about the masked values as much as about the code, and this is now stated in the protocol documentation.

#### M-03 Undeliverable platform fee halts all swaps

**Severity** Medium (Impact: Medium, Likelihood: Medium)
**Target** `CovenRouter._chargeFees`
**Status** Resolved

**Description.** The platform fee was transferred unconditionally on every swap where it was non-zero. Arc USDC is issued by Circle and carries an issuer-controlled denylist. A denylisted fee recipient would cause every swap with USDC on either side to revert until the owner rotated the recipient address. The original deployment configured the fee recipient as the owner account, meaning a single denylisting would have disabled both the fee destination and the account required to remediate it.

`CovenArb` already addressed the equivalent condition correctly, accruing fees as ERC-6909 claims rather than performing transfers.

**Impact.** Complete loss of availability for USDC-side swaps until an owner transaction executes. No loss of principal. The guardian cannot remediate, and pausing does not assist.

**Recommendation.** Accrue the fee where delivery fails rather than reverting the swap, and prevent the owner's recovery function from appropriating accrued balances.

**Resolution.** Fee payment now falls back to an accrual which the recipient withdraws via `claimFees`. Accrued balances are tracked per token and reserved; `sweep` reverts with `SweepExceedsFree` where the requested amount exceeds the unreserved balance. The deployed configuration sets a fee recipient distinct from the owner.

#### M-04 Factory attests sessions it does not authenticate

**Severity** Medium (Impact: Medium, Likelihood: Medium)
**Target** `CovenSessionFactory.create`
**Status** Resolved

**Description.** `create` accepted `owner` as a parameter and performed no authentication of the caller. Any party could deploy a session nominating an arbitrary owner, with an arbitrary session key, expiry, and caps. The resulting contract was recorded in `isSession` and appended to `_ownerSessions[owner]`, the mapping exposed by `sessionsOf`.

**Impact.** The factory exists to provide attestation; `isSession` is the signal a client application uses to distinguish a genuine session from a lookalike. The flaw reduced that signal to a statement that the contract was deployed by the factory, which any party could arrange. A client enumerating `sessionsOf` would present an attacker-controlled session alongside legitimate ones. No funds move unless the nominated owner approves tokens to the planted address, so this constitutes phishing amplification rather than direct theft. `_ownerSessions` provides no removal path, so an entry is permanent.

**Recommendation.** Derive the owner from `msg.sender`.

**Resolution.** `create` now assigns ownership to `msg.sender` and the `owner` parameter has been removed. The CREATE2 salt remains keyed on the owner, which is now necessarily the caller. `test/CovenSessionFactory.t.sol` asserts that a session created by any account is owned by that account and does not appear in another account's list.

### 6.4 Low

| ID | Finding | Resolution |
| --- | --- | --- |
| L-01 | `CovenSession` did not disable `renounceOwnership`, diverging from `CovenRouter` and `CovenArb`. Renouncement would render the session inoperable and remove the owner's ability to revoke it | Overridden to revert |
| L-02 | `CovenArb` fee changes applied to transactions already submitted, permitting the owner to capture up to 20% of profit above a searcher's stated floor | `Plan.maxFeeBps` records the maximum fee the caller accepts; execution reverts above it |
| L-03 | A failed integrator fee transfer reverted every swap nominating that integrator | Addressed by the M-03 accrual mechanism |
| L-04 | `_priceLimit` bounded price movement at 5.00% in one direction and 5.26% in the other for the same nominal ceiling | Both directions now bound at the stated percentage |
| L-05 | Daily caps use a fixed window that resets once a full period has elapsed since it opened, permitting up to twice the cap across a boundary | Retained as designed; documented |
| L-06 | `CovenSession` and `CovenArb` provided no mechanism to recover tokens transferred to them in error | `rescue` added to both, restricted to the owner |
| L-07 | `CovenArb` fees accrue as ERC-6909 claims redeemable only by calling the PoolManager within a lock | Operational requirement; the fee recipient must be an account capable of doing so |
| L-08 | The exact-fill invariant rejects hooks that take a fee from the input side of a swap via `BEFORE_SWAP_RETURNS_DELTA` | Retained; relaxing the invariant would weaken a load-bearing safety property |
| L-09 | `CovenSessionFactory` declared an error that was never used | Removed |
| L-10 | The `CovenSession` constructor accepted an expiry in the past and a session key equal to the owner | Both rejected |

### 6.5 Informational

The following were addressed alongside the findings above.

`CovenSessionFactory` held the router and lens addresses as compile-time constants, requiring a source modification before any redeployment. Both are now constructor arguments validated for code presence.

`_maskedCodeHash` copied the full candidate runtime code once per registered template, producing up to eight copies of as much as 24KB on a path executed during every hooked swap. The function now masks in place and restores, eliminating the copies.

Protocol documentation asserted two properties contradicted by H-01 and H-02 and described only two of the five contracts. Both have been corrected.

## 7. Residual Risk

The following conditions are known and accepted. They are not defects in the reviewed contracts.

**Hook repricing between quote and execution.** A hook admitted by the owner, whether individually or through a template, may alter the outcome of a swap between the point at which it is quoted and the point at which it executes. The minimum output enforced on every swap remains the operative protection. No allowlist alters this.

**Masked template constants.** A hook matching a registered template may assign any value to a masked constant. The Argus template masks six 2-byte values and eight addresses. Registration of a template is an approval of the range of behaviours those values permit.

**Minara hook input-side deltas.** The hook at `0xb6A65950534F061618B4AE102FBcbb8541a8e0cC` is explicitly allowlisted on the deployed router and its address carries all four swap-permission bits, including `BEFORE_SWAP_RETURNS_DELTA`. Where a hook takes its fee from the input side of a swap, the router's exact-fill invariant rejects the transaction, as recorded in L-08. Determining which side this hook operates on requires a forked-state test that was not performed. Pools using this hook should be treated as unverified until a swap has been executed against one successfully.

**Session window granularity.** Daily caps are enforced over fixed windows rather than rolling ones, as recorded in L-05.

**Role concentration.** The deployed guardian and fee recipient are the same account. This is materially less consequential than the owner and fee recipient sharing an account, the condition M-03 identified and this deployment corrected, but it places two roles on a single key. Separation is recommended.

**Superseded deployment.** The CovenRouter and CovenLens deployed on 19 September 2026 at `0xA13b8d54E2fD03319f0f7dB036090bD593f53161` and `0xc041C0748c5e5a5362E03097c53a59Dd0004Fa96` remain live and contain the unremediated forms of H-01, H-02, M-01, M-02, and M-03. They are outside the scope of this assessment and should not be integrated against.

## 8. Areas Reviewed Without Finding

The following were examined specifically and no defect was identified.

Delta accounting across the Uniswap v4 unlock boundary in both `CovenRouter.unlockCallback` and `CovenArb.unlockCallback`, including the conditions under which the PoolManager rejects an unsettled lock. The CCTP bridging path, including approval scoping and the handling of optional hook data. Fee-on-transfer handling in `_pull` and `_hop`, which derives amounts from measured balance deltas. The exact-fill invariant on every hop. Reentrancy across all external call sites in all five contracts, including calls into attacker-influenced hooks. Access control on both external callbacks.

`CovenArb._v3Leg` authenticates a Uniswap v3 pool by recomputing its address from the factory using both token addresses and the fee tier before honouring its callback. This check is correct and is a recurrent source of defects in comparable contracts.


## Appendix A. Argus Template Constants

The fourteen mask windows registered for the Argus hook at `0x399218a6395D79C695Ad4E95d53a6eD3914F2044`, resolved against its deployed runtime code (5,175 bytes). Each window covers the constant only; the lengths are load-bearing, and a 32-byte window at any of these offsets is rejected by `addHookTemplate` as described in M-02.

| Offset | Length | Value |
| --- | --- | --- |
| 488, 1886, 2163 | 20 | `0xa5f1d639337ffe6db68673897c8f17678156ec1e` |
| 1126, 1611, 1684, 3427, 3487 | 20 | `0x3600000000000000000000000000000000000000` (USDC) |
| 855, 944, 1764, 1802, 2783, 2829 | 2 | `100` |

Total masked: 172 bytes across eight addresses and six 2-byte values. Under the original 32-byte form the total would have been 448 bytes, of which 276 are executable.

## Appendix B. Test Inventory

Offline suite, 47 tests, executed with `forge test --match-path "test/audit/*" --no-match-path "test/audit/AdversarialHook.t.sol"`.

| File | Tests | Covers |
| --- | --- | --- |
| `test/audit/FindingsRegression.t.sol` | 8 | C-01, H-01, M-03 |
| `test/audit/ArgusTemplate.t.sol` | 4 | M-02 against deployed Argus bytecode |
| `test/audit/TemplateAudit.t.sol` | 16 | M-01, M-02, template registration bounds, admin controls |
| `test/audit/LensGasBench.t.sol` | 2 | H-02 gas measurements and the step budget |
| `test/audit/SwapAudit.t.sol` | 17 | Fee arithmetic, partial fill, bridging, pause, reentrancy |

`test/audit/AdversarialHook.t.sol` and the suites under `test/` require an Arc mainnet RPC endpoint and were not executed.

## Appendix C. Reproducing Deployment Verification

```sh
cast code <address> --rpc-url https://rpc.mainnet.arc.io
forge inspect <ContractName> deployedBytecode
```

Compare the two. For `CovenRouter` and `CovenArb` they are identical. For `CovenLens` and `CovenSessionFactory` the only differing bytes are the immutable slots listed in section 3.2, each holding the address of a contract deployed in the same run.
