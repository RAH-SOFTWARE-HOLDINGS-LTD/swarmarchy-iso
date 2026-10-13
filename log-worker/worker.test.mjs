// Run with: node --test log-worker/worker.test.mjs   (Node 20+; uses web-standard Request/Response/FormData)
import test from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.mjs";

const TOKEN = "correct-horse-battery-staple";
const ORIGIN = "https://logs.example.workers.dev";

function fakeEnv(overrides = {}) {
  const store = new Map();
  return {
    UPLOAD_TOKEN: TOKEN,
    LOGS: {
      async put(key, value, opts) { store.set(key, { value, opts }); },
      async get(key) {
        const hit = store.get(key);
        return hit ? { body: new Blob([hit.value]).stream() } : null;
      },
    },
    _store: store,
    ...overrides,
  };
}

// Encode the form ourselves so the request carries a real Content-Length, as curl's does.
async function encode(form, headers = {}) {
  const encoded = new Response(form);
  const body = await encoded.arrayBuffer();
  return new Request(`${ORIGIN}/`, {
    method: "POST",
    body,
    headers: {
      "content-type": encoded.headers.get("content-type"),
      "content-length": String(body.byteLength),
      ...headers,
    },
  });
}

async function post(content, { token = TOKEN, field = "file", extra = {} } = {}) {
  const form = new FormData();
  if (field) form.append(field, new File([content], "log.txt", { type: "text/plain" }));
  const headers = { ...extra };
  if (token !== null) headers.authorization = `Bearer ${token}`;
  return encode(form, headers);
}

test("rejects missing and wrong tokens with 401 and stores nothing", async () => {
  const env = fakeEnv();
  for (const token of [null, "", "wrong", TOKEN + "x", TOKEN.slice(1)]) {
    const res = await worker.fetch(await post("secret log", { token }), env);
    assert.equal(res.status, 401, `token ${JSON.stringify(token)}`);
  }
  assert.equal(env._store.size, 0);
});

test("fails closed when the deployment has no UPLOAD_TOKEN", async () => {
  const env = fakeEnv({ UPLOAD_TOKEN: undefined });
  const res = await worker.fetch(await post("x", { token: "anything" }), env);
  assert.equal(res.status, 500);
  assert.equal(env._store.size, 0);
});

test("accepts a valid upload and serves it back from the returned URL", async () => {
  const env = fakeEnv();
  const res = await worker.fetch(await post("line one\nline two\n"), env);
  assert.equal(res.status, 200);
  const url = (await res.text()).trim();
  assert.match(url, new RegExp(`^${ORIGIN}/\\d{4}-\\d{2}-\\d{2}/[0-9a-f]{32}\\.txt$`));

  const got = await worker.fetch(new Request(url), env);
  assert.equal(got.status, 200);
  assert.equal(await got.text(), "line one\nline two\n");
  assert.equal(got.headers.get("cache-control"), "no-store");
  assert.equal(got.headers.get("x-robots-tag"), "noindex");
  assert.match(got.headers.get("content-type"), /^text\/plain/);
});

test("each upload gets a distinct unguessable key", async () => {
  const env = fakeEnv();
  const a = (await (await worker.fetch(await post("a"), env)).text()).trim();
  const b = (await (await worker.fetch(await post("a"), env)).text()).trim();
  assert.notEqual(a, b);
});

test("only exact keys are readable; there is no listing", async () => {
  const env = fakeEnv();
  await worker.fetch(await post("hello"), env);
  for (const path of ["/", "/2026-10-13/", "/2026-10-13/ABC.txt", "/../etc/passwd",
    "/2026-10-13/00000000000000000000000000000000.txt", "/x/y/z", "/favicon.ico"]) {
    const res = await worker.fetch(new Request(`${ORIGIN}${path}`), env);
    assert.equal(res.status, 404, path);
  }
  const put = await worker.fetch(new Request(`${ORIGIN}/`, { method: "PUT", body: "x" }), env);
  assert.equal(put.status, 404);
});

test("rejects files over 10 MB with 413 and stores nothing", async () => {
  const env = fakeEnv();
  const res = await worker.fetch(await post("x".repeat(10 * 1024 * 1024 + 1)), env);
  assert.equal(res.status, 413);
  assert.equal(env._store.size, 0);
});

test("rejects a request whose declared length is far over the limit before reading it", async () => {
  const env = fakeEnv();
  const req = await post("small", { extra: { "content-length": String(50 * 1024 * 1024) } });
  assert.equal((await worker.fetch(req, env)).status, 413);
});

test("rejects a body without a file field", async () => {
  const env = fakeEnv();
  const form = new FormData();
  form.append("file", "just a string, not a file");
  const res = await worker.fetch(await encode(form, { authorization: `Bearer ${TOKEN}` }), env);
  assert.equal(res.status, 400);
  assert.equal((await worker.fetch(await post("x", { field: null }), env)).status, 400);
});

test("never echoes or logs the token", async () => {
  const env = fakeEnv();
  const logged = [];
  const originals = {};
  for (const m of ["log", "error", "warn", "info", "debug"]) {
    originals[m] = console[m];
    console[m] = (...a) => logged.push(a.join(" "));
  }
  try {
    const ok = await worker.fetch(await post("x"), env);
    const bad = await worker.fetch(await post("x", { token: "wrong" }), env);
    for (const res of [ok, bad]) assert.ok(!(await res.text()).includes(TOKEN));
  } finally {
    for (const m of Object.keys(originals)) console[m] = originals[m];
  }
  assert.equal(logged.filter((l) => l.includes(TOKEN)).length, 0);
});
