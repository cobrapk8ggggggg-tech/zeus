import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto, timingSafeEqual } from 'node:crypto';
import worker, { MODELS, modelInput, validateInput, validateOutput } from './worker.mjs';
Object.defineProperty(globalThis, 'crypto', { value: webcrypto, configurable: true });
crypto.subtle.timingSafeEqual = (a, b) => timingSafeEqual(Buffer.from(a.buffer ?? a), Buffer.from(b.buffer ?? b));
const token = 'A'.repeat(43);
const hash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token))).toString('hex');
const segments = [{ id: 'p_1', text: 'The traveler opened the book.' }, { id: 'p_2', text: 'A new beginning.' }];
const body = { model: MODELS[0].id, target: 'ar', segments };
const req = (payload = body, auth = token) => new Request('https://example.workers.dev/v1/translate', { method: 'POST', headers: { authorization: `Bearer ${auth}`, 'content-type': 'application/json' }, body: JSON.stringify(payload) });
const valid = { translations: segments.map(s => ({ id: s.id, text: 'ترجمة: ' + s.text })) };
function env(result = { response: valid }) {
  const calls = [];
  return { CLIENT_TOKEN_HASH: hash, ACCOUNT_ID: 'fixture', calls, AI: { async run(model, input) { calls.push({ model, input }); return result; } } };
}
test('unauthorized requests cannot run inference or fetch models', async () => {
  const e = env(); assert.equal((await worker.fetch(req(body, 'B'.repeat(43)), e)).status, 401);
  assert.equal((await worker.fetch(new Request('https://example.workers.dev/v1/models'), e)).status, 401);
  assert.equal(e.calls.length, 0);
});
test('a visible batch uses exactly one inference and is returned in source order', async () => {
  const e = env({ choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({ translations: [...valid.translations].reverse() }) } }] });
  const response = await worker.fetch(req(), e); assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).translations.map(s => s.id), segments.map(s => s.id));
  assert.equal(e.calls.length, 1); assert.equal(e.calls[0].input.stream, false);
  assert.equal(e.calls[0].input.chat_template_kwargs.enable_thinking, false);
  assert.deepEqual(JSON.parse(e.calls[0].input.messages[1].content), segments);
});
test('IDs, lengths, model and target are checked before quota can be spent', async () => {
  for (const bad of [ { ...body, model: '@cf/unknown' }, { ...body, target: 'ar;execute' }, { ...body, segments: [segments[0], segments[0]] }, { ...body, segments: [{ id: 'p', text: 'x'.repeat(24001) }] }, { ...body, instruction: 'x'.repeat(2001) } ]) {
    const e = env(); const r = await worker.fetch(req(bad), e); assert.ok([400, 413].includes(r.status)); assert.equal(e.calls.length, 0);
  }
});
test('partial, duplicate, truncated output and reasoning never become a translation', () => {
  for (const r of [ { response: { translations: [valid.translations[0]] } }, { response: { translations: [valid.translations[0], valid.translations[0]] } }, { choices: [{ finish_reason: 'length', message: { content: JSON.stringify(valid) } }] }, { choices: [{ finish_reason: 'stop', message: { content: null, reasoning_content: JSON.stringify(valid) } }] } ]) assert.throws(() => validateOutput(r, segments));
});
test('provider quota and capacity are surfaced without retries or leaking prompts', async () => {
  for (const [code, expected] of [[3036, 'daily_quota'], [3040, 'capacity'], [5035, 'paid_plan_required']]) {
    let calls = 0; const e = env(); e.AI.run = async () => { calls++; throw Object.assign(new Error('private page text'), { code }); };
    const response = await worker.fetch(req(), e); const text = await response.text();
    assert.equal(calls, 1); assert.ok([403, 429].includes(response.status)); assert.equal(JSON.parse(text).error, expected); assert.ok(!text.includes('private page text'));
  }
});
test('oversized streamed bodies are rejected before inference even without content-length', async () => {
  const e = env(); const response = await worker.fetch(req({ ...body, padding: 'x'.repeat(262144) }), e);
  assert.equal(response.status, 413); assert.equal(e.calls.length, 0);
});
test('enabled models are real authenticated server choices', async () => {
  const request = new Request('https://example.workers.dev/v1/models', { headers: { authorization: `Bearer ${token}` } });
  const response = await worker.fetch(request, env()); const object = await response.json();
  assert.equal(response.status, 200); assert.equal(object.models.length, 2); assert.equal(object.defaultModel, MODELS[0].id);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});
test('rate limited client stops before inference', async () => {
  const e = env(); e.RATE_LIMITER = { async limit() { return { success: false }; } };
  const r = await worker.fetch(req(), e); assert.equal(r.status, 429); assert.equal(e.calls.length, 0);
});
