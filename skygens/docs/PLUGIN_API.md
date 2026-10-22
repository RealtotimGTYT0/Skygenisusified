# SkyGens Plugin API v1

**Target:** Paper 1.21.x, Java 21, Paper API (`io.papermc.paper:paper-api`). Use Folia-safe schedulers only if you move to Folia.
**Status:** Specification only. DB functions written; HTTP endpoints, plugin and tests NOT yet built. Nothing here is integrated until the plugin is tested against the API.

## Auth (every request)
Headers: `X-Server-Id`, `X-Timestamp` (unix ms), `X-Nonce` (uuid), `X-Signature` = hex HMAC-SHA256(secret, `METHOD\nPATH\nTIMESTAMP\nNONCE\nsha256(body)`).
Reject if |now − timestamp| > 60s or nonce reused. The secret lives only in the plugin `config.yml` and Netlify env; never log it or send it in chat.
Mutating calls also carry `Idempotency-Key`; the backend stores it in `plugin_events` so replays are no-ops.

## Endpoints (`/api/plugin/v1/...`)
| Method | Path | Purpose |
|---|---|---|
| POST | `/heartbeat` | online count, max players, uptime, TPS (every 30s) |
| POST | `/playtime` | `{mcUuid, seconds}` (≤3600) → `apply_playtime`; send every 60s, key = `uuid:sessionId:seq` |
| POST | `/link/verify` | `{code, mcUuid, mcName}` from `/skygens link <code>`; succeeds only if challenge unused, unexpired, and name matches |
| POST | `/generators` | `{mcUuid, level, stats{}}` |
| POST | `/achievements` | `{mcUuid, badgeKey}` (only keys allowed for automatic award) |
| GET | `/deliveries/pending` | durable queue, returns `{deliveryId, mcUuid, payload}` |
| POST | `/deliveries/{id}/ack` | `{status: delivered|failed, error?}`; re-ack is a no-op |

## Plugin requirements
- Track playtime by server-side time; persist unsent seconds to disk (SQLite/flat file) and flush on quit/shutdown/crash recovery.
- Offline-mode: key on name→UUID as given by the server; document that these are NOT verified identities.
- Delivery: store `deliveryId` as applied before ack; if the server restarts mid-delivery, check the applied-list so it never delivers twice. Hold items for offline recipients until they join.
- Retry with exponential backoff; never block the main thread (async HTTP, sync only for Bukkit API calls).
- Config: `api-url`, `server-id`, `secret`, `playtime-flush-seconds`, `mock-mode`.
- Mock mode: local fake backend for tests.
