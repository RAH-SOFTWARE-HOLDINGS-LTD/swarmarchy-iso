// Receives install-failure logs from swarmarchy-upload-file and serves them back by an
// unguessable URL. Runs as a Cloudflare Worker with an R2 bucket bound as LOGS and a
// secret named UPLOAD_TOKEN. See README.md.

const MAX_BYTES = 10 * 1024 * 1024;
// <date>/<32 hex>.txt: the random part is the read capability, so keys are never listed.
const KEY_PATH = /^\/(\d{4}-\d{2}-\d{2}\/[0-9a-f]{32}\.txt)$/;

// Compare SHA-256 digests so the check takes the same time wherever the strings differ
// and never depends on token length.
async function tokensMatch(provided, expected) {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(provided)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

const text = (body, status = 200) =>
  new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

async function upload(request, env, url) {
  // Fail closed: never accept uploads from a deployment that has no token set.
  if (!env.UPLOAD_TOKEN) return text("Server not configured\n", 500);

  const auth = request.headers.get("authorization") || "";
  const provided = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!(await tokensMatch(provided, env.UPLOAD_TOKEN))) return text("Unauthorized\n", 401);

  const declared = Number(request.headers.get("content-length"));
  if (!Number.isFinite(declared) || declared <= 0) return text("Length required\n", 411);
  // Allow a little multipart overhead on top of the file itself.
  if (declared > MAX_BYTES + 4096) return text("Too large\n", 413);

  let form;
  try {
    form = await request.formData();
  } catch {
    return text("Bad request\n", 400);
  }
  const file = form.get("file");
  if (!file || typeof file === "string" || typeof file.arrayBuffer !== "function") {
    return text("Bad request\n", 400);
  }
  if (file.size > MAX_BYTES) return text("Too large\n", 413);

  const random = crypto.getRandomValues(new Uint8Array(16));
  const hex = Array.from(random, (b) => b.toString(16).padStart(2, "0")).join("");
  const key = `${new Date().toISOString().slice(0, 10)}/${hex}.txt`;

  await env.LOGS.put(key, await file.arrayBuffer(), {
    httpMetadata: { contentType: "text/plain; charset=utf-8" },
  });
  return text(`${url.origin}/${key}\n`);
}

async function download(url, env) {
  const match = KEY_PATH.exec(url.pathname);
  if (!match) return text("Not found\n", 404);
  const object = await env.LOGS.get(match[1]);
  if (!object) return text("Not found\n", 404);
  return new Response(object.body, {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      "x-robots-tag": "noindex",
      "x-content-type-options": "nosniff",
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/") return upload(request, env, url);
    if (request.method === "GET") return download(url, env);
    return text("Not found\n", 404);
  },
};
