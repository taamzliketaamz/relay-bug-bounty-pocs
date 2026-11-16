# WS5-01 — `force: true` solver-fill/refund attestation bypass

**Severity requested: S3 / L2 → $15,000** (per the Relay program matrix;
L-grade conditional — see "Honest limits" below).

**Target:** Relay oracle app, `relayprotocol/relay-protocol-oracle` @ main
— `POST /attestations/solver-fills/v1` and
`POST /attestations/solver-refunds/v1`, force branches in
`src/services/attestation/index.ts`
(`attestSolverFill` L1653–1729, `attestSolverRefund` L1877–1953).

## The bug

With `force: true`, the attestation endpoints return a signed Hub
`TRANSFER` execution paying the order's solver the full deposit amount
while:

- no fill transaction ever occurred (`fill.transactionId` is never read),
- the order signature is never verified (`orderSignature` is never read),
- deposit amounts/currency are never checked against the order,
- the solver's on-chain fill (`getSolverPaidAmount` / `verifySolverCalls`)
  is never checked.

The only checks that run in force mode are: (a) the API key exists in
the `API_KEYS` map, (b) deposits with `depositId === orderId` exist.

## Regression — this is not a Zellic known issue

At the audit commit (`7dbe806…`), the force option was gated to the
internal-only key named `"relay"` (comment: "Restrict the `force` option
to specific integrators"). The service-level bypass existed then too,
but was contained by that gate. Zellic's Oracle audit lists 10 findings,
none about `force`, and its §5.1 invariant states "Solver orders must
have a valid solver signature" — violated by the force path.

Commit `62ab912d4941b20d4642228574b13d2b44b0dce7`, PR #182, 16 Mar 2026,
"tweak: allow all valid api keys to set force option", changed both the
fills and refunds hunks from the `"relay"`-name check to any-valid-key —
undoing the Jul 2025 security fix ("ensure only authorized integrators
can use the force option").

## Attack (request shape)

```http
POST https://<oracle-host>/attestations/solver-fills/v1
x-api-key: <ANY_VALID_ORACLE_API_KEY>
Content-Type: application/json

{
  "order": { "<real order: version, solverChainId, solver, salt, inputs, output, fees>" },
  "orderSignature": "0x0000… (dummy — never read in force mode)",
  "inputs": [ { "transactionId": "<real deposit tx>", "onchainId": "<real onchain id>", "inputIndex": 0 } ],
  "fill": { "transactionId": "0x0000… (dummy — never read in force mode)" },
  "force": true,
  "requestPeerSignatures": true
}
```

The `order` must be the **real order** (same fields → same derived
orderId → matches the victim's existing deposit). The payout goes to
`order.solver` (via its Hub alias), so the attacker must be the order's
designated solver (or collude with them) — an arbitrary deposit cannot
be retargeted. `fees: []` avoids extra fee TRANSFER actions.
`requestPeerSignatures: true` fans the identical request out to
configured peers (`src/api/quorum.ts` L822–884); the forced execution
is deterministic, so every peer computes the identical execution and
signs it — collecting the 2-of-5 signatures the live multisig requires
(multisig `0x2a72eb8cf0233a3dc6198683c83b1078de6fa2b0`, threshold 2,
5 signers, verified live via `cast call` 2026-11-16).

Expected response: `200` with `execution` containing `actions` =
TRANSFER(s) from the order address to the solver's Hub alias for the
full deposit amount, plus `signatures`. Submitting it via
`RelayOracleV2.execute` (Relay chain 537713, oracle
`0xd180dc3b8cb71b185c563b6e4857592ca93dacaf`) moves the funds; there is
no deadline/expiry on the Execution, so a forced execution stays
submittable indefinitely. The same bypass exists on
`/attestations/solver-refunds/v1` (refund variant V-01, lower
confidence, ordering-dependent — noted, not separately scored).

## PoC

This folder contains a **static PoC** (code + diff + request trace).
No live request was sent: no oracle API key was held, no real
order/deposit was used, no funds moved.

1. `check-ws5-01.mjs` — automated gate check. Run it where network +
   Node are available; it prints PASS/FAIL per revision and writes no
   files:

   ```bash
   node check-ws5-01.mjs
   # Expected:
   # audit        {"relayOnlyGate":true, "anyValidKeyGate":false}
   # main-fills   {"relayOnlyGate":false,"anyValidKeyGate":true}
   # main-refunds {"relayOnlyGate":false,"anyValidKeyGate":true}
   ```

2. `POC-WS5-01-force-bypass.md` — the full writeup: exact request
   bodies for fills and refunds, full code trace, gate diff (audit
   commit vs regression commit vs main), on-chain submission steps, and
   the honest limits below.

3. Manual verification (all public GitHub URLs):
   - Audit commit `7dbe806a9ee9bbc0f32df8bc7e0b6da1de253799`,
     `src/api/attestations/solver-fills/v1.ts` — gate requires
     `config.apiKeys[apiKey] === "relay"`.
   - Regression commit `62ab912d4941b20d4642228574b13d2b44b0dce7`
     (PR #182) — both hunks change the `"relay"`-name check to
     any-valid-key.
   - Current main, `solver-fills/v1.ts` L284–300 and
     `solver-refunds/v1.ts` L312–328 — gate is only
     `isValidApiKey(apiKey)`.

## Honest limits

- **No live request was sent.** The end-to-end chain (force request →
  2-of-5 signatures → `RelayOracleV2.execute`) is traced in code and
  verified against live on-chain deployment data, but the final hop was
  not executed live.
- **Prerequisites not yet verified:** (a) oracle API-key issuance —
  self-serve vs vetted (Relay *platform* keys are self-serve via
  dashboard.relay.link, but oracle keys are a separate set);
  (b) solver onboarding — whether third-party solvers can be designated
  `order.solver`; (c) live peer topology — whether the production
  oracle has ≥2 peer instances so one force call collects 2-of-5
  (if no peers, only 1 signature is produced and on-chain execution
  reverts at threshold 2); (d) current multisig threshold re-query via
  `eth_call` (deployment value is 2; verified live threshold 2 and
  5 signers via `cast call`).
- **Attacker is the designated solver** (or their colluder), not an
  arbitrary third party: the payout beneficiary is `order.solver` and
  the orderId is derived from the order fields. This bounds impact to
  S3, not S4.

## Suggested fix

- Restore the internal-only force gate: a dedicated `FORCE_API_KEYS`
  allowlist (or restore the key-name check) so only Relay-operated keys
  can set `force`; external integrator keys must never enable it.
- Defense in depth: verify `orderSignature` against `order.solver`
  even in force mode, and require the fill/refund transaction to at
  least exist on-chain before signing.
- Alert on every force attestation (it should be rare and
  human-reviewed); consider removing `force` from the public API
  surface entirely.
