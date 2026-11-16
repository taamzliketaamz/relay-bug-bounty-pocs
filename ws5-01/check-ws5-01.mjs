// check-ws5-01.mjs — static gate check for WS5-01
// Verifies the `force` gate regression without any API key, order, or funds:
// the audit commit gates `force` to the internal-only key "relay", while
// current main gates it to any valid API key, on both solver-fills and
// solver-refunds. Run with: node check-ws5-01.mjs
// Requires network access to raw.githubusercontent.com; writes no files.
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
