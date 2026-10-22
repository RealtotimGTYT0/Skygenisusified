# SkyGens (starter)
1. Supabase: run `supabase/migrations/0001_core.sql` then `0002_status.sql`.
2. Netlify: connect repo, set env vars from `.env.example`.
3. Plugin: `cd plugin && mvn package` -> `target/SkyGens.jar` into Paper 1.21.x `plugins/` (Java 21). Edit `config.yml` (api-url, secret).

## Status
Implemented (untested): playtime reporting, heartbeat, link verify, delivery queue, status + playtime leaderboard page, DB economy functions.
Not built yet: register/login, link-code creation endpoint, store/gifting/inventory/exchange UI, admin panel, rate limiting, Discord bot, tests.
Note: offline-mode usernames are not verified identities.
