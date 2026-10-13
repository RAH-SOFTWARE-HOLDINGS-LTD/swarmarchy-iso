# Install-failure log upload (Cloudflare Worker + R2)

When an install fails, the installer can upload its logs here so you can read them on another
computer. `swarmarchy-upload-file` POSTs the log to this Worker with a bearer token; the Worker
stores it in a private R2 bucket under a random key and replies with a URL that works on any
computer. Nothing is sent anywhere else. Free tier covers this by a wide margin.

The ISO build **requires** the Worker URL and the upload token (see below), so deploy this first.

## One-time setup

```sh
cd log-worker
npx wrangler login
npx wrangler r2 bucket create swarmarchy-logs

# Pick the token (any long random string) and store it as a Worker secret:
openssl rand -base64 24
npx wrangler secret put UPLOAD_TOKEN      # paste the token when asked

npx wrangler deploy                       # prints https://swarmarchy-logs.<you>.workers.dev
```

Delete old logs automatically: in the dashboard, R2 > `swarmarchy-logs` > Settings > Object
lifecycle rules > add a rule that deletes objects 30 days after creation. (`wrangler r2 bucket
lifecycle` also exists; run `npx wrangler r2 bucket lifecycle --help` for the current flags.)

## Give the ISO build the URL and token

The build takes both from the environment, or from a hidden, gitignored file at the repo root:

```sh
# swarmarchy-iso/.log-upload.env   (chmod 600)
SWARMARCHY_LOG_UPLOAD_URL=https://swarmarchy-logs.<you>.workers.dev/
SWARMARCHY_LOG_UPLOAD_TOKEN=<the token you gave wrangler>
```

`swarmarchy-iso-make` aborts immediately if either is missing. Environment variables win over
the file. CI needs both as repository secrets (`SWARMARCHY_LOG_UPLOAD_URL`,
`SWARMARCHY_LOG_UPLOAD_TOKEN`).

## Trade-offs, plainly

- The token is **baked into the ISO** (`/root/swarmarchy_log_upload`, mode 0600), so anyone who
  holds the ISO or the USB can read it. Keep the ISOs private. A leaked token only lets someone
  upload files up to 10 MB (which expire); it cannot read, list or delete anything.
- Reading a log needs its URL: `YYYY-MM-DD/<32 random hex>.txt`. There is no listing endpoint.
  Anyone you give the URL to can read that one log. Logs contain hardware, package list and
  username, so share them accordingly.
- Rotate the token: `npx wrangler secret put UPLOAD_TOKEN`, update `.log-upload.env`, rebuild.
- WAF / rate-limit rules attach to a zone, so they need a custom domain on the Worker rather
  than the bare `workers.dev` URL (not verified here). The 10 MB cap and 30-day expiry bound
  what abuse could cost.

## Try it

```sh
curl -F file=@some.log -H "Authorization: Bearer $TOKEN" https://swarmarchy-logs.<you>.workers.dev/
```

## Tests (no Cloudflare account needed)

```sh
node --test log-worker/worker.test.mjs     # Node 20+; fake R2 binding
```

They cover wrong/missing token (401), fail-closed without a secret (500), the 10 MB limit
(413), key format, no listing, and that the token is never echoed or logged.
