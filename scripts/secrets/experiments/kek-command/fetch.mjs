// TRELLIS_KEK_COMMAND experiment (ADR-104): fetch the KEK from Vault with the pod's projected
// ServiceAccount token. Prints the key to stdout and nothing else; every failure exits non-zero
// with a message that names the step, never the value or the path.
import { readFileSync } from "node:fs";

const addr = process.env.VAULT_ADDR ?? "https://vault.vault.svc:8200";
const mount = process.env.VAULT_K8S_MOUNT ?? "kubernetes";
const role = process.env.VAULT_K8S_ROLE ?? "trellis-app";
const kvPath = process.env.VAULT_KEK_PATH ?? "secret-lab/data/trellis/kek";
const field = process.env.VAULT_KEK_FIELD ?? "TRELLIS_KEK";
const tokenFile = process.env.VAULT_SA_TOKEN_FILE ?? "/var/run/secrets/vault/token";

const fail = (msg) => { console.error(`kek-fetch: ${msg}`); process.exit(1); };

let jwt;
try { jwt = readFileSync(tokenFile, "utf8").trim(); } catch { fail("projected token unreadable"); }

const login = await fetch(`${addr}/v1/auth/${mount}/login`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ role, jwt }),
}).catch(() => fail("vault unreachable at login"));
if (!login.ok) fail(`vault login refused: HTTP ${login.status}`);
const token = (await login.json())?.auth?.client_token;
if (!token) fail("vault login returned no token");

const read = await fetch(`${addr}/v1/${kvPath}`, { headers: { "X-Vault-Token": token } })
  .catch(() => fail("vault unreachable at read"));
const body = read.ok ? await read.json() : null;
await fetch(`${addr}/v1/auth/token/revoke-self`, { method: "POST", headers: { "X-Vault-Token": token } }).catch(() => {});
if (!read.ok) fail(`vault read refused: HTTP ${read.status}`);
const value = body?.data?.data?.[field];
if (typeof value !== "string" || value.length === 0) fail("field missing from the KV entry");
process.stdout.write(value);
