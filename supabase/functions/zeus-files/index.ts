// The service key stays inside Supabase. Railway receives a short-lived,
// owner-scoped capability and can never ask this endpoint to return that key.
export function createGateway(base: string, adminKey: string, send: typeof globalThis.fetch = globalThis.fetch) {
const fetch = send;
const ceiling = 8 * 1024 * 1024;
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const digestPattern = /^[a-f0-9]{64}$/;
const headers = { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" };
function json(value: unknown, status = 200) { return new Response(JSON.stringify(value), { status, headers: { ...headers, "Content-Type": "application/json" } }); }
async function sha(data: Uint8Array) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(data).buffer))).map(n => n.toString(16).padStart(2, "0")).join("");
}
async function bounded(request: Request, limit: number) {
  if (Number(request.headers.get("Content-Length") ?? 0) > limit) throw new Error("size");
  const reader = request.body?.getReader(); const chunks: Uint8Array[] = []; let length = 0;
  if (reader) {
    try {
      while (true) { const part = await reader.read(); if (part.done) break;
        length += part.value.length; if (length > limit) { await reader.cancel(); throw new Error("size"); }
        chunks.push(part.value);
      }
    } finally { reader.releaseLock(); }
  }
  const result = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}
async function admin(path: string, method = "GET", body?: unknown) {
  return await fetch(base + path, { method, headers: { apikey: adminKey, Authorization: "Bearer " + adminKey,
    "Content-Type": "application/json", Prefer: "return=representation" }, body: body === undefined ? undefined : JSON.stringify(body) });
}
async function verifiedUser(token: string) {
  const response = await fetch(base + "/auth/v1/user", { headers: { apikey: adminKey, Authorization: "Bearer " + token } });
  if (!response.ok) throw new Error("auth");
  const user = await response.json(); if (!uuid.test(user.id)) throw new Error("auth");
  // getUser above verifies this very JWT. The session claim is never trusted
  // merely because a client decoded it, nor read from editable user metadata.
  const encoded = token.split(".")[1]?.replaceAll("-", "+").replaceAll("_", "/");
  if (!encoded) throw new Error("auth");
  const claims = JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "=")));
  if (claims.sub !== user.id || !uuid.test(claims.session_id)) throw new Error("auth");
  return { id: user.id, session: claims.session_id };
}

async function storeObject(owner: string, hash: string, data: Uint8Array) {
  const reserved = await admin("/rest/v1/rpc/zeus_reserve_object", "POST", { user_id: owner, object_sha: hash, object_bytes: data.length });
  if (reserved.status === 507) return json({ error: "storage_allowance_reached" }, 507);
  if (!reserved.ok) throw new Error("storage");
  const path = "/storage/v1/object/zeus-private/" + owner + "/objects/" + hash;
  const upload = await fetch(base + path, { method: "POST", headers: { apikey: adminKey, Authorization: "Bearer " + adminKey,
    "Content-Type": "application/octet-stream", "x-upsert": "false" }, body: new Uint8Array(data).buffer });
  if (!upload.ok && upload.status !== 409 && upload.status !== 400) throw new Error("storage");
  const check = await fetch(base + path, { headers: { apikey: adminKey, Authorization: "Bearer " + adminKey } });
  if (!check.ok) throw new Error("storage");
  const blob = await check.blob();
  if (blob.size !== data.length || blob.size > ceiling || await sha(new Uint8Array(await blob.arrayBuffer())) !== hash) throw new Error("storage");
  return json({ sha256: hash, bytes: data.length, verified: true });
}

async function accountKey(owner: string, create: boolean) {
  const path = "/rest/v1/zeus_account_keyring?user_id=eq." + owner + "&select=key_b64&limit=1";
  let response = await admin(path); if (!response.ok) throw new Error("storage");
  let row = (await response.json())[0];
  if (!row && create) {
    const key = crypto.getRandomValues(new Uint8Array(32));
    const inserted = await admin("/rest/v1/zeus_account_keyring", "POST", { user_id: owner, key_b64: btoa(String.fromCharCode(...key)) });
    if (!inserted.ok && inserted.status !== 409) throw new Error("storage");
    response = await admin(path); if (!response.ok) throw new Error("storage");
    row = (await response.json())[0];
  }
  if (!row) throw new Error("cipher");
  const bytes = Uint8Array.from(atob(row.key_b64), ch => ch.charCodeAt(0));
  return await crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function seal(owner: string, input: Uint8Array, decrypt: boolean) {
  const key = await accountKey(owner, !decrypt), aad = new TextEncoder().encode(owner + "|native-secrets-v1");
  if (decrypt) {
    if (input.length < 32 || input[0] !== 0x5a || input[1] !== 0x53 || input[2] !== 0x43 || input[3] !== 1) throw new Error("cipher");
    try { return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: input.slice(4,16), additionalData: aad }, key, input.slice(16))); }
    catch { throw new Error("cipher"); }
  }
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, key, new Uint8Array(input).buffer));
  const result = new Uint8Array(16 + cipher.length); result.set([0x5a,0x53,0x43,1]); result.set(nonce,4); result.set(cipher,16); return result;
}

return async (request: Request): Promise<Response> => {
  try {
    const url = new URL(request.url), op = url.searchParams.get("op");
    if (request.method === "GET" && op === "health") return json({ service: "zeus-files", version: 1 });
    const token = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
    if (request.method === "GET" && op === "usage") {
      const user = await verifiedUser(token);
      const response = await admin("/rest/v1/rpc/zeus_storage_usage", "POST", { user_id: user.id });
      if (!response.ok) throw new Error("storage");
      return new Response(response.body, { headers: { ...headers, "Content-Type": "application/json" } });
    }
    if (request.method === "PUT" && op === "userput") {
      const user = await verifiedUser(token), hash = url.searchParams.get("sha") ?? "";
      if (!digestPattern.test(hash)) return json({ error: "invalid_object" }, 400);
      const data = await bounded(request, ceiling);
      if (await sha(data) !== hash) return json({ error: "digest_mismatch" }, 400);
      return await storeObject(user.id, hash, data);
    }
    if (request.method === "GET" && op === "userget") {
      const user = await verifiedUser(token), hash = url.searchParams.get("sha") ?? "";
      if (!digestPattern.test(hash)) return json({ error: "invalid_object" }, 400);
      const stored = await fetch(base + "/storage/v1/object/zeus-private/" + user.id + "/objects/" + hash,
        { headers: { apikey: adminKey, Authorization: "Bearer " + adminKey } });
      if (!stored.ok) return json({ error: "not_found" }, 404);
      const blob = await stored.blob(); if (blob.size > ceiling) throw new Error("size");
      const data = new Uint8Array(await blob.arrayBuffer()); if (await sha(data) !== hash) throw new Error("storage");
      return new Response(data, { headers: { ...headers, "Content-Type": "application/octet-stream" } });
    }
    if (request.method === "POST" && op === "runtime") {
      if (!/^zdb1_[a-f0-9]{64}$/.test(token)) return json({ error: "unauthorized" }, 401);
      const lookup = await admin("/rest/v1/zeus_runtime_access?token_sha256=eq." + await sha(new TextEncoder().encode(token)) + "&revoked_at=is.null&select=label&limit=1");
      if (!lookup.ok || !(await lookup.json())[0]) return json({ error: "unauthorized" }, 401);
      const input = JSON.parse(new TextDecoder().decode(await bounded(request, 2 * 1024 * 1024)));
      if (typeof input.command !== "string" || typeof input.args !== "object" || input.args === null) return json({ error: "invalid_command" }, 400);
      if (input.command === "gc_delete") {
        const args = input.args;
        if (!uuid.test(args.owner ?? "") || !digestPattern.test(args.sha256 ?? "")) return json({ error: "invalid_collection" }, 400);
        const check = await admin("/rest/v1/rpc/zeus_runtime_command", "POST", { command: "gc_check", args });
        if (!check.ok) return json({ error: "collection_conflict" }, check.status);
        if (!(await check.json()).allowed) return json({ deleted: false });
        const path = args.owner + "/objects/" + args.sha256;
        const removed = await admin("/storage/v1/object/zeus-private", "DELETE", { prefixes: [path] });
        if (!removed.ok) throw new Error("storage");
        const remaining = await admin("/storage/v1/object/zeus-private/" + path);
        let missing = remaining.status === 404;
        if (!missing && remaining.status === 400) {
          const detail = await remaining.json().catch(() => ({}));
          missing = Number(detail.statusCode) === 404 || detail.code === "NoSuchKey";
        }
        if (!missing) return json({ error: "gc_object_absence_unverified", status: remaining.status }, 503);
        const released = await admin("/rest/v1/rpc/zeus_runtime_command", "POST", { command: "gc_forget", args });
        if (!released.ok) throw new Error("storage");
        return new Response(released.body, { headers: { ...headers, "Content-Type": "application/json" } });
      }
      const result = await admin("/rest/v1/rpc/zeus_runtime_command", "POST", { command: input.command, args: input.args });
      if (!result.ok) return json({ error: "runtime_storage_failed" }, result.status);
      return new Response(result.body, { headers: { ...headers, "Content-Type": "application/json" } });
    }
    if (request.method === "POST" && ["issue", "revoke", "seal", "unseal"].includes(op ?? "")) {
      const user = await verifiedUser(token);
      if (op === "seal" || op === "unseal") {
        const data = await bounded(request, 1024 * 1024 + 32);
        return new Response(await seal(user.id, data, op === "unseal"), { headers: { ...headers, "Content-Type": "application/octet-stream" } });
      }
      const input = JSON.parse(new TextDecoder().decode(await bounded(request, 2048)));
      const conversation = input.conversation_id;
      if (typeof conversation !== "string" || !uuid.test(conversation)) return json({ error: "invalid_conversation" }, 400);
      if (op === "revoke") {
        const response = await admin("/rest/v1/zeus_runtime_grants?user_id=eq." + user.id + "&conversation_id=eq." + conversation, "DELETE");
        if (!response.ok) throw new Error("storage"); return json({ revoked: true });
      }
      const opaque = "zg1_" + Array.from(crypto.getRandomValues(new Uint8Array(32))).map(n => n.toString(16).padStart(2, "0")).join("");
      const now = new Date(), expires = new Date(now.getTime() + 24 * 3600 * 1000);
      const response = await admin("/rest/v1/zeus_runtime_grants", "POST", {
        user_id: user.id, session_id: user.session, conversation_id: conversation,
        token_sha256: await sha(new TextEncoder().encode(opaque)), created_at: now.toISOString(), expires_at: expires.toISOString(),
      });
      if (!response.ok) throw new Error("storage");
      return json({ token: opaque, user_id: user.id, conversation_id: conversation, expires_at: expires.toISOString() });
    }
    if (!/^zg1_[a-f0-9]{64}$/.test(token)) return json({ error: "unauthorized" }, 401);
    const response = await admin("/rest/v1/zeus_runtime_grants?token_sha256=eq." + await sha(new TextEncoder().encode(token)) +
      "&expires_at=gt." + encodeURIComponent(new Date().toISOString()) + "&select=user_id,conversation_id,expires_at&limit=1");
    if (!response.ok) throw new Error("storage");
    const grant = (await response.json())[0]; if (!grant) return json({ error: "expired_or_revoked" }, 401);
    if (request.method === "GET" && op === "check") return json(grant);
    const hash = url.searchParams.get("sha") ?? "";
    if (!digestPattern.test(hash)) return json({ error: "invalid_object" }, 400);
    const path = "/storage/v1/object/zeus-private/" + grant.user_id + "/objects/" + hash;
    if (request.method === "PUT" && op === "put") {
      const data = await bounded(request, ceiling);
      if (await sha(data) !== hash) return json({ error: "digest_mismatch" }, 400);
      return await storeObject(grant.user_id, hash, data);
    }
    if (request.method === "GET" && op === "get") {
      const stored = await fetch(base + path, { headers: { apikey: adminKey, Authorization: "Bearer " + adminKey } });
      if (!stored.ok) return json({ error: "not_found" }, 404);
      const blob = await stored.blob(); if (blob.size > ceiling) throw new Error("size");
      const data = new Uint8Array(await blob.arrayBuffer()); if (await sha(data) !== hash) throw new Error("storage");
      return new Response(data, { headers: { ...headers, "Content-Type": "application/octet-stream" } });
    }
    return json({ error: "invalid_operation" }, 400);
  } catch (error) {
    const code = error instanceof Error ? error.message : "storage";
    return json({ error: code === "auth" ? "unauthorized" : code === "size" ? "object_too_large" : code === "cipher" ? "invalid_encrypted_snapshot" : "operation_failed" }, code === "auth" ? 401 : code === "size" ? 413 : code === "cipher" ? 400 : 503);
  }
};
}
