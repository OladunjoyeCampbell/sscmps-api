# Known Issues / Deferred Tasks

## Security (Deferred)

`wrangler` currently pulls in `esbuild`, `sharp`, `undici`, `ws`, and
`miniflare` versions with known advisories. These affect only the local
development toolchain and are NOT present in the deployed Cloudflare
Worker runtime.

Resolution requires a breaking upgrade to `wrangler@4`. Scheduled as a
separate task to avoid destabilising active feature work.

- `npm audit` reports 6 vulnerabilities, all transitively via `wrangler`.
- Production runtime is unaffected.
- Do NOT run `npm audit fix --force` — it will break the build.