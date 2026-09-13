# v52-supabase

Supabase/PostgreSQL project that persists Vector52 wallet-flow investigations so
the graph and dashboard shown in `v52` can be rebuilt from stored data instead
of only the live API response. Design source: [`docs/SUPABASE_GRAPH_DATA_MODEL.md`](../docs/SUPABASE_GRAPH_DATA_MODEL.md).

This is **not** part of the evidence chain. Acquisition (Alchemy), hashing and
the API response returned to the caller never depend on this database. If it
is unreachable or unconfigured, `v52-backend` keeps working exactly as before
— it just stops writing a copy of the result here.

```
v52-supabase/
└── supabase/
    ├── config.toml          # supabase CLI project config (local dev + link target)
    ├── migrations/
    │   └── 20260913120000_graph_investigations.sql   # full schema, RLS, RPCs
    └── seed.sql              # local-dev only; production seed data ships in the migration
```

## What the migration creates

Tables: `graph_chains`, `graph_wallets`, `graph_assets`, `graph_transactions`,
`graph_transfers`, `graph_investigations`, `graph_investigation_transfers`.

Two views used by the dashboard:
- `graph_relationship_edges_v` — one row per counterparty + asset + direction,
  the same unit `WalletFlowGraph.tsx` already renders.
- `graph_investigation_overview_v` — the "Results overview" panel figures
  (node/relationship counts, the 18-per-direction visible cap, top-7 asset tag
  cloud).

Two RPC functions, the only way anything ever writes here:
- `graph_ingest_wallet_flow(p_result, p_channel, p_actor_wallet, p_external_request_id)`
  — persists one `WalletFlowResponse` as a `COMPLETED` investigation, inside
  one transaction. An invalid transfer partway through rolls back the whole
  investigation; nothing partial is ever left behind.
- `graph_get_wallet_flow_result(p_investigation_id)` — reconstructs the exact
  `WalletFlowResponse` JSON shape (`incoming[]`, `outgoing[]`, `limits`,
  `warnings`, in original order) from stored rows.

Three intentional deviations from `docs/SUPABASE_GRAPH_DATA_MODEL.md`, each
marked `-- DEVIATION` in the SQL with its reason: an unconstrained `numeric`
instead of `numeric(78,36)` for `value_decimal` (spam ERC-20s report values
like `1e+59`, which overflow 42 integer digits and would abort ingestion — an
unconstrained `numeric` is still exact, never a float); an `identity_key`
generated column replacing the doc's two partial-unique-index approach for
assets (needed so `ON CONFLICT` has a single target); and the edges view
grouping by asset **id** rather than symbol, so two different contracts
sharing a symbol — a common spam pattern — never get summed into one edge.

## Security model

- Row Level Security is **on** for every table, with **no policies** — so
  even though Supabase's Data API exposes the `public` schema by default,
  `anon` and `authenticated` get nothing. `revoke all ... from anon,
  authenticated` on every table, view and function makes this explicit rather
  than relying on RLS alone.
- Only `service_role` can execute the two RPCs. Nothing else can write.
- `v52-backend` is the only writer, using the service role key. The frontend
  never receives it and never talks to Supabase directly.
- No private keys, signatures, session tokens or x402 headers are ever
  persisted here — only what `WalletFlowResponse` already contains.

## Verified before you deploy it

This schema was tested against a real embedded Postgres engine (not a
description of intent) before being handed to the backend: exact
`incoming[]`/`outgoing[]`/`limits`/`warnings` round-trip reconstruction,
correct decimal arithmetic (including the `1e-05` and `1.2e+59` edge cases
above), idempotent re-ingestion of the same investigation, a transfer shared
by two different investigations resolving `IN`/`OUT` independently per
investigation, edge/overview aggregation matching the frontend's own grouping
and 18-per-direction cap, full rollback on an invalid transfer mid-batch, and
`anon`/`authenticated` denial on every table, view and RPC. If you change the
migration, re-verify — the check script isn't part of this folder because it
isn't Supabase-specific tooling, but the same approach (any local Postgres,
or `@electric-sql/pglite` for a zero-install one) works.

## Set up the Supabase project

### 1. Create the project

Create a new project at [supabase.com](https://supabase.com/dashboard) (or
reuse an existing org's project). Note the **Project Reference ID**, the
**Project URL**, and the **service_role key** — Project Settings → API. The
service_role key bypasses RLS; treat it exactly like a database root password.

### 2. Apply the migration

**Option A — Supabase CLI (recommended):**

```bash
npm install -g supabase   # or: brew install supabase/tap/supabase
cd v52-supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase db push
```

`supabase db push` applies every file under `supabase/migrations/` in order
and records what's already applied, so it's safe to re-run.

**Option B — SQL Editor (no CLI):**

Open the project's SQL Editor in the Supabase dashboard, paste the contents
of [`supabase/migrations/20260913120000_graph_investigations.sql`](supabase/migrations/20260913120000_graph_investigations.sql), and run it once.

### 3. Verify

In the SQL Editor:

```sql
select * from public.graph_chains;
-- expect one row: chain_id=1, network_slug='ethereum-mainnet'

select p.proname, p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'graph_%';
-- expect graph_ingest_wallet_flow and graph_get_wallet_flow_result present
```

Confirm RLS is denying the anon key (safe to run from a terminal, no project
secrets needed beyond the public anon key shown in the dashboard):

```bash
curl -s "https://<project-ref>.supabase.co/rest/v1/graph_investigations" \
  -H "apikey: <anon-key>" -H "authorization: Bearer <anon-key>"
# expect: [] — RLS denies anon with no policies, not an error
```

### 4. Local development (optional)

Requires Docker running:

```bash
cd v52-supabase
supabase start     # spins up local Postgres + Data API + Studio
supabase db reset  # (re)applies migrations + seed.sql from scratch
```

`supabase start` prints a local `API URL` and `service_role key` — use those
in `v52-backend/.env` instead of the hosted project's while developing.

## Connect `v52-backend`

The backend already has the integration wired in (`app/storage/supabase_graph.py`,
called from `app/api/wallet_flow.py`'s `acquire_wallet_flow`, the function shared
by the web and agent channels — see `app/api/access.py` and `app/api/agent.py`).
It only needs configuration; **no code changes are required to enable it.**

In `v52-backend/.env`:

```dotenv
V52_SUPABASE_ENABLED=true
V52_SUPABASE_URL=https://<project-ref>.supabase.co
V52_SUPABASE_SERVICE_ROLE_KEY=<service-role-key>
```

Restart the backend. Every completed wallet-flow investigation (`WEB` channel
from the PWA, `AGENT_X402` from an MCP agent) is now also persisted as a
`graph_ingestion` background task — **fire-and-forget**: the HTTP response to
the caller is sent before ingestion is awaited, so a slow or unreachable
Supabase never adds latency or fails the investigation. Failures are logged
(`app.storage.supabase_graph`) as a warning, never raised.

Confirm it end-to-end: run a wallet-flow investigation from the PWA or
`curl -X POST .../v1/web/investigations/wallet-flow ...`, then in the SQL
Editor:

```sql
select id, channel, status, target_wallet_id, returned_incoming, returned_outgoing
from public.graph_investigations
order by created_at desc
limit 5;
```

If nothing appears: check the backend logs for `Supabase graph ingestion
failed` / `Supabase graph ingestion request failed`, and confirm
`GET /v1/providers/status` on the backend reports `data.supabase.status:
"CONFIGURED"` (added alongside `the_graph`/`rpc`/`x402` in
`app/api/providers.py` — never exposes the URL or key, just whether writes
are enabled). `CONFIGURED` only means the backend has valid settings, not
that the Supabase project is reachable right now — that only becomes
observable on the next actual ingestion attempt, logged as described above.

## Reading the data back

`graph_get_wallet_flow_result(investigation_id)` returns the same JSON shape
`WalletFlowGraph.tsx` already consumes, so a future "load a past investigation"
feature in `v52` can call it directly with no frontend changes to the graph
component:

```sql
select public.graph_get_wallet_flow_result('<investigation-id>');
```

There is currently no backend endpoint exposing this read path — only
ingestion is wired up. Add a `GET /v1/cases/.../graph` (or similar) in
`v52-backend` calling this RPC through the service role when that feature is
needed; RLS keeps it inaccessible from the frontend directly regardless.

## Open questions before this goes further

Same as `docs/SUPABASE_GRAPH_DATA_MODEL.md` §10 — still unresolved and worth
settling before building a read path or a "my investigations" UI: whether the
frontend will ever read Supabase directly (today it never does — only
`v52-backend` with the service role writes and, if extended, reads); whether
Supabase Auth replaces or coexists with the existing SIWE session
(`owner_user_id` is nullable and unused today — every investigation currently
persists with `owner_user_id = null`, distinguishable only by `channel` and
`actor_wallet_id`); whether investigations are private, public, or
share-by-link (`is_public` exists, defaults `false`, nothing sets it `true`
yet); and data retention for transfers/investigations/raw payloads.
