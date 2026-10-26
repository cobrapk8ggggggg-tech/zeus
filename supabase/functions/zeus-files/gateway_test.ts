import { createGateway } from "./index.ts";
function assert(value: unknown): asserts value { if (!value) throw new Error("assertion failed"); }
const owner = "10000000-0000-4000-8000-000000000001", other = "20000000-0000-4000-8000-000000000002";
const conversation = "30000000-0000-4000-8000-000000000003", session = "40000000-0000-4000-8000-000000000004";
const jwt = "header." + btoa(JSON.stringify({ sub: owner, session_id: session })) + ".signature";
const grant = "zg1_" + "a".repeat(64);
Deno.test("unauthenticated access makes no privileged requests", async () => {
  let calls = 0;
  const app = createGateway("https://project.test", "admin-secret", async () => { calls++; throw new Error("unexpected"); });
  const response = await app(new Request("https://function.test?op=get&sha=" + "a".repeat(64)));
  assert(response.status === 401 && calls === 0);
});
Deno.test("issuing uses verified identity and never returns the admin key or stored token hash", async () => {
  let saved: Record<string, unknown> | undefined;
  const app = createGateway("https://project.test", "admin-secret", async (url, options) => {
    if (String(url).endsWith("/auth/v1/user")) return Response.json({ id: owner });
    saved = JSON.parse(String(options?.body)); return Response.json([saved]);
  });
  const response = await app(new Request("https://function.test?op=issue", { method: "POST", headers: { Authorization: "Bearer " + jwt },
    body: JSON.stringify({ conversation_id: conversation, user_id: other }) }));
  const text = await response.text(), value = JSON.parse(text);
  assert(response.status === 200 && saved?.user_id === owner && saved?.session_id === session);
  assert(value.user_id === owner && value.token.startsWith("zg1_"));
  assert(!text.includes("admin-secret") && !text.includes(String(saved?.token_sha256)));
});
Deno.test("unverified JWT cannot issue a capability", async () => {
  let calls = 0;
  const app = createGateway("https://project.test", "admin-secret", async () => { calls++; return new Response("", { status: 401 }); });
  const response = await app(new Request("https://function.test?op=issue", { method: "POST", headers: { Authorization: "Bearer " + jwt },
    body: JSON.stringify({ conversation_id: conversation }) }));
  assert(response.status === 401 && calls === 1);
});
Deno.test("revoked capability cannot reach Storage", async () => {
  let calls = 0;
  const app = createGateway("https://project.test", "admin-secret", async () => { calls++; return Response.json([]); });
  const response = await app(new Request("https://function.test?op=get&sha=" + "a".repeat(64), { headers: { Authorization: "Bearer " + grant } }));
  assert(response.status === 401 && calls === 1);
});
Deno.test("malformed object paths never reach Storage", async () => {
  let calls = 0;
  const app = createGateway("https://project.test", "admin-secret", async () => { calls++; return Response.json([{ user_id: owner, conversation_id: conversation }]); });
  const response = await app(new Request("https://function.test?op=get&sha=../" + other, { headers: { Authorization: "Bearer " + grant } }));
  assert(response.status === 400 && calls === 1);
});
Deno.test("oversize bodies stop before upload", async () => {
  let calls = 0;
  const app = createGateway("https://project.test", "admin-secret", async () => { calls++; return Response.json([{ user_id: owner, conversation_id: conversation }]); });
  const response = await app(new Request("https://function.test?op=put&sha=" + "a".repeat(64), { method: "PUT",
    headers: { Authorization: "Bearer " + grant, "Content-Length": String(9 * 1024 * 1024) }, body: "small" }));
  assert(response.status === 413 && calls === 1);
});
Deno.test("account secrets round-trip without exporting the key; tampered ciphertext is rejected", async () => {
  let stored: unknown[] = [];
  const app = createGateway("https://project.test", "admin-secret", async (url, options) => {
    if (String(url).endsWith("/auth/v1/user")) return Response.json({ id: owner });
    if (options?.method === "POST") { stored = [JSON.parse(String(options.body))]; return Response.json(stored); }
    return Response.json(stored);
  });
  const request = (op: string, body: Uint8Array) => new Request("https://function.test?op=" + op, {
    method: "POST", headers: { Authorization: "Bearer " + jwt }, body: new Uint8Array(body).buffer });
  const secret = new TextEncoder().encode("provider-secret-and-saved-form-value");
  const encrypted = await app(request("seal", secret)); assert(encrypted.status === 200);
  const cipher = new Uint8Array(await encrypted.arrayBuffer()); assert(cipher.length === secret.length + 32);
  assert(!new TextDecoder().decode(cipher).includes("provider-secret"));
  const restored = await app(request("unseal", cipher)); assert(restored.status === 200);
  assert(await restored.text() === new TextDecoder().decode(secret));
  cipher[cipher.length - 1] ^= 1;
  assert((await app(request("unseal", cipher))).status === 400);
});
Deno.test("fresh account identity reads only its own content-addressed archive", async () => {
  const bytes = new TextEncoder().encode("encrypted archive bytes");
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map(n => n.toString(16).padStart(2, "0")).join("");
  let storagePath = "";
  const app = createGateway("https://project.test", "admin-secret", async (url) => {
    if (String(url).endsWith("/auth/v1/user")) return Response.json({ id: owner });
    storagePath = String(url); return new Response(bytes);
  });
  const response = await app(new Request("https://function.test?op=userget&sha=" + digest + "&user_id=" + other, { headers: { Authorization: "Bearer " + jwt } }));
  assert(response.status === 200 && await response.text() === "encrypted archive bytes");
  assert(storagePath.includes("/" + owner + "/objects/" + digest) && !storagePath.includes(other));
  storagePath = "";
  const bad = await app(new Request("https://function.test?op=userget&sha=../" + other, { headers: { Authorization: "Bearer " + jwt } }));
  assert(bad.status === 400 && storagePath === "");
});
