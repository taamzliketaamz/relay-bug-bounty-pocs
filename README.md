# Relay Bug Bounty — Proof-of-Concept Repositories

Two validated findings against the Relay settlement protocol (program at
https://docs.relay.link/security/bounties, reports submitted by email to
support@relay.link, one email per finding). Target repo:
relayprotocol/relay-settlement @
`b2f3e0e5fba9381293f030ef340ffb4872687fcf` (and
relayprotocol/relay-protocol-oracle @ main for WS5-01).

## Findings

### 1. `ws5-01/` — Oracle attestation `force: true` bypass (ask: S3/L2, $15,000)

`POST /attestations/solver-fills/v1` (and `/solver-refunds/v1`) with
`force: true` is gated only by any valid oracle API key. The force
branch skips order-signature verification, fill-existence checks and
amount checks, and returns a signed Hub TRANSFER execution paying the
order's solver the full deposit amount — with no fill ever happening.
Regression: PR #182 (16 Mar 2026) undid the Jul 2025 internal-only
gate. Attacker must be the order's designated solver (or collude with
them); payout is bounded per order, so S3, not S4.

Static PoC: `check-ws5-01.mjs` (run with Node, needs network) verifies
the gate regression across the audit commit, the regression commit and
current main; `POC-WS5-01-force-bypass.md` is the full writeup with
exact request bodies, code trace and on-chain submission steps. No live
request was sent (no API key held, no real order, no funds moved), and
three prerequisites are openly unverified: oracle API-key issuance
(self-serve vs vetted), solver onboarding, and live peer topology.

### 2. `c1/` — BasicCallResolver permissionless sweep (ask: S3/L3, $30,000)

`BasicCallResolver.execute()` has no access control: any address can run
arbitrary calls as the resolver and sweep its full Hub balance per
tokenId to any recipient. Leftovers are documented behaviour (solver may
retain funded input; funds left behind are not swept automatically).

Measured on a local Foundry chain: a fresh EOA with no roles drains
1,000,000 simulated USDC of solver-retained leftovers; resolver balance
→ 0 (`[PASS] test_attackerDrainsResolverLeftovers()`, gas 140503;
Foundry 1.9.0, solc 0.8.28, verified 2026-11-16).

Honest caveat: the reference resolver's live Hub balance was **0 across
the 10 major tokenIds checked** on 2026-11-16 ~11:18 WIB, so the amount
at risk in that instance is $0 right now — leftovers are transient by
design, so any future leftover is instantly sweepable, and solvers may
deploy their own instances. No at-risk amount is claimed that does not
exist.

## Layout

- `ws5-01/` — static PoC (Node check script + full writeup). No build
  step; run `node check-ws5-01.mjs`.
- `c1/` — standalone Foundry project. Run:
  `forge install foundry-rs/forge-std --no-commit`,
  `forge install OpenZeppelin/openzeppelin-contracts@v5.3.0 --no-commit`,
  then `forge test --match-contract POC01 -vvv`. Contracts under `c1/src/`
  are verbatim from relay-settlement @ `b2f3e0e` (only the files this PoC
  needs); the test file itself imports only `forge-std`.
