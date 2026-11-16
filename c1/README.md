# C1 — BasicCallResolver permissionless sweep of stuck funds

**Severity requested: S3 / L3 → $30,000** (per the Relay program matrix).

**Target:** `BasicCallResolver.execute()` —
`smart-contracts/contracts/call-resolvers/BasicCallResolver.sol`,
relayprotocol/relay-settlement @ `b2f3e0e5fba9381293f030ef340ffb4872687fcf`.

## The bug

`BasicCallResolver.execute()` has **no access control**. It runs
caller-supplied arbitrary calls and then sweeps the resolver's **full** Hub
balance of every requested `tokenId` to caller-chosen recipients. Any Hub
funds left in the resolver can be stolen by **any address** with a single
call — no role, no signature, no order, no allowance.

Leftovers in the resolver are documented behaviour, not a corner case:
the resolver *"may retain the funded input or other execution value"*
(BasicCallResolver docs) and *"Any funds left behind are not swept
automatically"* (ICallResolver docs). A solver retaining input across
executions, or any direct transfer to the resolver address, leaves funds
that anyone can take.

Aggravating factor (not a separate finding): the same permissionless
`execute()` also lets anyone run arbitrary calls with `msg.sender` equal
to the resolver — the resolver doubles as a call proxy from its own
address. If it were ever granted a role, allowance or operator
permission, those calls would exercise it.

## Measured impact (Foundry, local chain)

`test/POC01_BasicCallResolverSweep.t.sol` — a fresh EOA with no roles
anywhere drains 1,000,000 simulated USDC of solver-retained leftovers
to itself; resolver balance 1,000,000 USDC → 0.

```
[PASS] test_attackerDrainsResolverLeftovers() (gas: 140503)
```

Verified 2026-11-16, Foundry 1.9.0, solc 0.8.28; re-run by the hunt
coordinator (full poc-ws2 suite 2/2 PASS — the second test is a
mechanism demonstration, NOT part of this finding, and is not included
here).

## Honest caveat — live amount at risk

The reference resolver IS deployed
(`utils.basicCallResolver = 0xb24ac15b9da6d88e283ffe048befe02e188ea64e`
in `prod.json`, contract code confirmed on-chain). Its live Hub balance
was **0 across the 10 major tokenIds checked** on 2026-11-16 ~11:18 WIB
(USDC/USDT/WETH/DAI on Ethereum, USDC on Arbitrum/Optimism/Polygon/Linea,
USDT on BNB, USDC on Avalanche). So the amount at risk in the reference
instance is **$0 right now** — but leftovers are transient by design
(solvers retain input across executions), so any future leftover is
instantly sweepable by anyone, and solvers may deploy their own
`BasicCallResolver` instances (not enumerable from `prod.json`). The
mechanism itself is fully validated; we claim no at-risk amount that
does not exist.

S4 is not claimed: the loss is bounded to one resolver's holdings, not
the Hub or all orders.

## Reproduction

```bash
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.3.0 --no-commit
forge test --match-contract POC01 -vvv
```

Contracts under `src/` are verbatim from
relayprotocol/relay-settlement @ `b2f3e0e` (only the files this PoC
needs: `RelayHub.sol`, `Utils.sol`, `ERC20View.sol`,
`call-resolvers/BasicCallResolver.sol`,
`call-resolvers/ICallResolver.sol`). The test file itself imports only
`forge-std`; the vendored Relay contracts import OpenZeppelin (hence the
second install line above). No mainnet interaction — everything runs on
a local Foundry chain; the USDC address is used only to derive a
realistic Hub tokenId.

## Suggested fix

Restrict `execute()` to a configured executor (as
`PoolResolverBase._requireExecutor` does for pool resolvers), or
restrict sweeps to the executor address only. The executor must still be
able to fund the resolver and receive the output — the fix is about who
may *invoke* the resolver, not about the executor↔resolver flow.
