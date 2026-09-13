-- Vector52 — wallet-flow graph persistence.
-- Design source: docs/SUPABASE_GRAPH_DATA_MODEL.md. Deviations from that
-- document are marked "DEVIATION" with the reason next to them.
--
-- Access model: only v52-backend writes and reads, using the service role.
-- RLS is enabled on every table with no policies, so the anon and
-- authenticated roles get nothing even though Supabase exposes `public`
-- through its Data API.

-- ── Enums ───────────────────────────────────────────────────────────────────

create type public.graph_direction as enum ('IN', 'OUT');
create type public.graph_access_channel as enum ('WEB', 'AGENT_X402', 'INTERNAL');
create type public.graph_investigation_status as enum ('PENDING', 'RUNNING', 'COMPLETED', 'FAILED');
create type public.graph_asset_category as enum ('native', 'erc20', 'erc721', 'erc1155', 'unknown');

-- ── Reference data ──────────────────────────────────────────────────────────

create table public.graph_chains (
  chain_id bigint primary key,
  network_slug text not null unique,
  display_name text not null,
  native_symbol text not null,
  explorer_tx_base_url text not null,
  created_at timestamptz not null default now()
);

-- Lives in the migration, not seed.sql: seed.sql only runs on local resets,
-- and production ingestion fails without this row.
insert into public.graph_chains
  (chain_id, network_slug, display_name, native_symbol, explorer_tx_base_url)
values
  (1, 'ethereum-mainnet', 'Ethereum Mainnet', 'ETH', 'https://etherscan.io/tx/')
on conflict (chain_id) do nothing;

-- ── Canonical on-chain observations ─────────────────────────────────────────

create table public.graph_wallets (
  id uuid primary key default gen_random_uuid(),
  chain_id bigint not null references public.graph_chains(chain_id),
  address text not null check (address ~ '^0x[0-9a-fA-F]{40}$'),
  address_normalized text generated always as (lower(address)) stored,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  unique (chain_id, address_normalized)
);

create table public.graph_assets (
  id uuid primary key default gen_random_uuid(),
  chain_id bigint not null references public.graph_chains(chain_id),
  category public.graph_asset_category not null,
  symbol text not null,
  contract_address text null check (
    contract_address is null or contract_address ~ '^0x[0-9a-fA-F]{40}$'
  ),
  contract_address_normalized text generated always as (lower(contract_address)) stored,
  decimals smallint null check (decimals between 0 and 255),
  token_id text null,
  -- DEVIATION: the doc uses two partial unique indexes over expressions,
  -- which cannot be targeted by a plain ON CONFLICT. One stored identity key
  -- encodes the same rule: contract + token_id when a contract exists,
  -- otherwise the (native/unknown) symbol.
  identity_key text generated always as (
    coalesce(
      'contract:' || lower(contract_address) || ':' || coalesce(token_id, ''),
      'symbol:' || lower(symbol)
    )
  ) stored,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (chain_id, identity_key)
);

create table public.graph_transactions (
  id uuid primary key default gen_random_uuid(),
  chain_id bigint not null references public.graph_chains(chain_id),
  tx_hash text not null check (tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  tx_hash_normalized text generated always as (lower(tx_hash)) stored,
  block_number bigint null check (block_number is null or block_number >= 0),
  block_timestamp timestamptz null,
  metadata jsonb not null default '{}'::jsonb,
  first_observed_at timestamptz not null default now(),
  unique (chain_id, tx_hash_normalized)
);

create table public.graph_transfers (
  id uuid primary key default gen_random_uuid(),
  chain_id bigint not null references public.graph_chains(chain_id),
  provider text not null,
  provider_transfer_id text not null,
  transaction_id uuid null references public.graph_transactions(id),
  from_wallet_id uuid not null references public.graph_wallets(id),
  to_wallet_id uuid not null references public.graph_wallets(id),
  asset_id uuid not null references public.graph_assets(id),
  category text not null,
  -- DEVIATION: unconstrained numeric instead of numeric(78,36). Spam ERC-20s
  -- report values like 1e+59, which overflow 42 integer digits and would abort
  -- the whole ingestion. Unconstrained numeric is still exact.
  value_decimal numeric null,
  value_text text null,
  token_id text null,
  -- Direction-independent fields only (see graph_ingest_wallet_flow): a
  -- transfer is shared by every investigation that observes it.
  raw_payload jsonb null,
  observed_at timestamptz not null default now(),
  unique (chain_id, provider, provider_transfer_id)
);

-- ── Investigation snapshots ─────────────────────────────────────────────────

create table public.graph_investigations (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid null references auth.users(id) on delete set null,
  channel public.graph_access_channel not null,
  external_request_id text null,
  actor_wallet_id uuid null references public.graph_wallets(id),
  target_wallet_id uuid not null references public.graph_wallets(id),
  chain_id bigint not null references public.graph_chains(chain_id),
  network text not null,
  status public.graph_investigation_status not null default 'PENDING',
  acquired_at timestamptz null,
  provider text not null default 'alchemy',
  provider_method text not null default 'alchemy_getAssetTransfers',
  source_authority text not null default 'L1_INDEXED',
  requested_per_direction smallint not null check (requested_per_direction between 1 and 100),
  returned_incoming integer not null default 0 check (returned_incoming >= 0),
  returned_outgoing integer not null default 0 check (returned_outgoing >= 0),
  truncated boolean not null default false,
  from_date date null,
  to_date date null,
  max_pages_per_direction smallint not null default 1 check (max_pages_per_direction >= 1),
  -- Methodological warnings exactly as the API returned them.
  warnings text[] not null default '{}',
  -- DEVIATION: notes produced while persisting (e.g. transfers without a valid
  -- tx hash) are kept apart so `warnings` still reconstructs the API response.
  ingest_warnings text[] not null default '{}',
  error_code text null,
  error_detail text null,
  is_public boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (from_date is null or to_date is null or from_date <= to_date),
  check (status <> 'COMPLETED' or acquired_at is not null)
);

create table public.graph_investigation_transfers (
  investigation_id uuid not null references public.graph_investigations(id) on delete cascade,
  transfer_id uuid not null references public.graph_transfers(id),
  direction public.graph_direction not null,
  counterparty_wallet_id uuid not null references public.graph_wallets(id),
  sort_index integer not null check (sort_index >= 0),
  created_at timestamptz not null default now(),
  primary key (investigation_id, transfer_id, direction)
);

-- ── Indexes ─────────────────────────────────────────────────────────────────

create index graph_investigations_target_time_idx
  on public.graph_investigations (target_wallet_id, acquired_at desc);
create index graph_investigations_owner_time_idx
  on public.graph_investigations (owner_user_id, created_at desc);
create index graph_investigations_actor_time_idx
  on public.graph_investigations (actor_wallet_id, created_at desc);
create index graph_transactions_block_time_idx
  on public.graph_transactions (chain_id, block_timestamp desc);
create index graph_transfers_from_idx on public.graph_transfers (from_wallet_id);
create index graph_transfers_to_idx on public.graph_transfers (to_wallet_id);
create index graph_transfers_asset_idx on public.graph_transfers (asset_id);
create index graph_transfers_transaction_idx on public.graph_transfers (transaction_id);
create index graph_investigation_transfers_lookup_idx
  on public.graph_investigation_transfers (investigation_id, direction, sort_index);
create index graph_investigation_transfers_counterparty_idx
  on public.graph_investigation_transfers (counterparty_wallet_id);

-- ── updated_at trigger ──────────────────────────────────────────────────────

create or replace function public.set_graph_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger graph_investigations_set_updated_at
before update on public.graph_investigations
for each row execute function public.set_graph_updated_at();

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Alchemy serialises values as Python floats ("0.5", "1e-05", "1.2e+59").
-- Anything that is not a finite decimal becomes NULL instead of aborting.
create or replace function public.graph_safe_numeric(p_value text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or p_value !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$' then
    return null;
  end if;
  return p_value::numeric;
exception when others then
  return null;
end;
$$;

create or replace function public.graph_asset_category_of(p_category text)
returns public.graph_asset_category
language sql
immutable
set search_path = ''
as $$
  select case lower(coalesce(p_category, ''))
    when 'external' then 'native'::public.graph_asset_category
    when 'erc20' then 'erc20'::public.graph_asset_category
    when 'erc721' then 'erc721'::public.graph_asset_category
    when 'erc1155' then 'erc1155'::public.graph_asset_category
    else 'unknown'::public.graph_asset_category
  end;
$$;

create or replace function public.graph_upsert_wallet(p_chain_id bigint, p_address text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.graph_wallets (chain_id, address)
  values (p_chain_id, p_address)
  on conflict (chain_id, address_normalized)
  do update set last_seen_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- ── Ingestion ───────────────────────────────────────────────────────────────

-- Persists one WalletFlowResponse (v52-backend app/models/wallet_flow.py) as a
-- COMPLETED investigation. The Data API runs each RPC call in a single
-- transaction, so any invalid row rolls back the whole investigation.
create or replace function public.graph_ingest_wallet_flow(
  p_result jsonb,
  p_channel public.graph_access_channel,
  p_actor_wallet text default null,
  p_external_request_id text default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_chain_id bigint := (p_result ->> 'chain_id')::bigint;
  v_target text := p_result ->> 'address';
  v_target_id uuid;
  v_actor_id uuid;
  v_investigation_id uuid;
  v_list text;
  v_item jsonb;
  v_ordinal bigint;
  v_direction public.graph_direction;
  v_counterparty text;
  v_counterparty_id uuid;
  v_asset_id uuid;
  v_category public.graph_asset_category;
  v_contract text;
  v_tx_hash text;
  v_tx_id uuid;
  v_transfer_id uuid;
  v_missing_tx integer := 0;
  v_ingest_warnings text[] := '{}';
begin
  if p_result is null or jsonb_typeof(p_result) <> 'object' then
    raise exception 'p_result must be a JSON object' using errcode = '22023';
  end if;
  if not exists (select 1 from public.graph_chains where chain_id = v_chain_id) then
    raise exception 'Unsupported chain_id %', v_chain_id using errcode = '22023';
  end if;
  if v_target is null or v_target !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'Invalid target address' using errcode = '22023';
  end if;
  if p_result ->> 'acquired_at' is null then
    raise exception 'acquired_at is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_result -> 'limits') is distinct from 'object' then
    raise exception 'limits is required' using errcode = '22023';
  end if;

  v_target_id := public.graph_upsert_wallet(v_chain_id, v_target);
  if p_actor_wallet is not null then
    if p_actor_wallet !~ '^0x[0-9a-fA-F]{40}$' then
      raise exception 'Invalid actor wallet' using errcode = '22023';
    end if;
    v_actor_id := public.graph_upsert_wallet(v_chain_id, p_actor_wallet);
  end if;

  insert into public.graph_investigations (
    channel, external_request_id, actor_wallet_id, target_wallet_id, chain_id, network,
    status, provider, provider_method, source_authority, requested_per_direction,
    truncated, from_date, to_date, max_pages_per_direction, warnings
  ) values (
    p_channel,
    p_external_request_id,
    v_actor_id,
    v_target_id,
    v_chain_id,
    coalesce(p_result ->> 'network', 'ethereum-mainnet'),
    'RUNNING',
    coalesce(p_result #>> '{source,provider}', 'alchemy'),
    coalesce(p_result #>> '{source,method}', 'alchemy_getAssetTransfers'),
    coalesce(p_result #>> '{source,authority}', 'L1_INDEXED'),
    (p_result #>> '{limits,requested_per_direction}')::smallint,
    coalesce((p_result #>> '{limits,truncated}')::boolean, false),
    (p_result #>> '{limits,from_date}')::date,
    (p_result #>> '{limits,to_date}')::date,
    coalesce((p_result #>> '{limits,max_pages_per_direction}')::smallint, 1),
    coalesce(
      array(select jsonb_array_elements_text(coalesce(p_result -> 'warnings', '[]'::jsonb))),
      '{}'
    )
  )
  returning id into v_investigation_id;

  foreach v_list in array array['incoming', 'outgoing'] loop
    for v_item, v_ordinal in
      select value, ordinality
      from jsonb_array_elements(coalesce(p_result -> v_list, '[]'::jsonb)) with ordinality
    loop
      v_direction := case when v_list = 'incoming' then 'IN' else 'OUT' end;
      if v_item ->> 'direction' is distinct from v_direction::text then
        raise exception 'Transfer % in % has direction %',
          v_item ->> 'transfer_id', v_list, v_item ->> 'direction'
          using errcode = '22023';
      end if;
      if coalesce(v_item ->> 'transfer_id', '') = '' then
        raise exception 'Transfer without transfer_id in %', v_list using errcode = '22023';
      end if;

      v_counterparty := v_item ->> 'counterparty';
      if v_counterparty is null or v_counterparty !~ '^0x[0-9a-fA-F]{40}$' then
        raise exception 'Invalid counterparty for transfer %', v_item ->> 'transfer_id'
          using errcode = '22023';
      end if;
      v_counterparty_id := public.graph_upsert_wallet(v_chain_id, v_counterparty);

      v_category := public.graph_asset_category_of(v_item ->> 'category');
      v_contract := nullif(v_item ->> 'contract_address', '');
      if v_contract is not null and v_contract !~ '^0x[0-9a-fA-F]{40}$' then
        v_contract := null;
      end if;
      insert into public.graph_assets (chain_id, category, symbol, contract_address, token_id)
      values (
        v_chain_id,
        v_category,
        coalesce(nullif(v_item ->> 'asset', ''), 'UNKNOWN'),
        v_contract,
        case when v_contract is null then null else v_item ->> 'token_id' end
      )
      on conflict (chain_id, identity_key) do update set symbol = public.graph_assets.symbol
      returning id into v_asset_id;

      v_tx_hash := v_item ->> 'tx_hash';
      if v_tx_hash ~ '^0x[0-9a-fA-F]{64}$' then
        insert into public.graph_transactions (chain_id, tx_hash, block_number, block_timestamp)
        values (
          v_chain_id,
          v_tx_hash,
          (v_item ->> 'block_number')::bigint,
          (v_item ->> 'timestamp')::timestamptz
        )
        on conflict (chain_id, tx_hash_normalized) do update set
          block_number = coalesce(public.graph_transactions.block_number, excluded.block_number),
          block_timestamp = coalesce(public.graph_transactions.block_timestamp, excluded.block_timestamp)
        returning id into v_tx_id;
      else
        v_tx_id := null;
        v_missing_tx := v_missing_tx + 1;
      end if;

      insert into public.graph_transfers (
        chain_id, provider, provider_transfer_id, transaction_id,
        from_wallet_id, to_wallet_id, asset_id, category,
        value_decimal, value_text, token_id, raw_payload
      ) values (
        v_chain_id,
        coalesce(p_result #>> '{source,provider}', 'alchemy'),
        v_item ->> 'transfer_id',
        v_tx_id,
        case when v_direction = 'IN' then v_counterparty_id else v_target_id end,
        case when v_direction = 'IN' then v_target_id else v_counterparty_id end,
        v_asset_id,
        coalesce(v_item ->> 'category', 'unknown'),
        public.graph_safe_numeric(v_item ->> 'value'),
        v_item ->> 'value',
        v_item ->> 'token_id',
        -- `direction` and `counterparty` are relative to one target wallet and
        -- stay on graph_investigation_transfers, never on the shared transfer.
        v_item - 'direction' - 'counterparty'
      )
      on conflict (chain_id, provider, provider_transfer_id) do nothing
      returning id into v_transfer_id;

      if v_transfer_id is null then
        select id into v_transfer_id
        from public.graph_transfers
        where chain_id = v_chain_id
          and provider = coalesce(p_result #>> '{source,provider}', 'alchemy')
          and provider_transfer_id = v_item ->> 'transfer_id';
      end if;

      insert into public.graph_investigation_transfers (
        investigation_id, transfer_id, direction, counterparty_wallet_id, sort_index
      ) values (
        v_investigation_id, v_transfer_id, v_direction, v_counterparty_id, v_ordinal - 1
      )
      on conflict (investigation_id, transfer_id, direction) do nothing;
    end loop;
  end loop;

  if v_missing_tx > 0 then
    v_ingest_warnings := array_append(
      v_ingest_warnings,
      format('%s transfer(s) had no valid tx hash and were stored without a transaction link.', v_missing_tx)
    );
  end if;

  update public.graph_investigations set
    status = 'COMPLETED',
    acquired_at = (p_result ->> 'acquired_at')::timestamptz,
    returned_incoming = coalesce(
      (p_result #>> '{limits,returned_incoming}')::integer,
      jsonb_array_length(coalesce(p_result -> 'incoming', '[]'::jsonb))
    ),
    returned_outgoing = coalesce(
      (p_result #>> '{limits,returned_outgoing}')::integer,
      jsonb_array_length(coalesce(p_result -> 'outgoing', '[]'::jsonb))
    ),
    ingest_warnings = v_ingest_warnings
  where id = v_investigation_id;

  return v_investigation_id;
end;
$$;

-- ── Read model ──────────────────────────────────────────────────────────────

-- Rebuilds the exact WalletFlowResponse the frontend already renders, so a
-- stored investigation can be fed to WalletFlowGraph with no UI changes.
create or replace function public.graph_get_wallet_flow_result(p_investigation_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with inv as (
    select i.*, w.address_normalized as target_address
    from public.graph_investigations i
    join public.graph_wallets w on w.id = i.target_wallet_id
    where i.id = p_investigation_id
  ),
  transfer_rows as (
    select
      it.direction,
      it.sort_index,
      jsonb_build_object(
        'transfer_id', t.provider_transfer_id,
        'direction', it.direction,
        'counterparty', cp.address,
        'tx_hash', coalesce(tx.tx_hash, t.raw_payload ->> 'tx_hash', 'unknown'),
        'block_number', coalesce(tx.block_number, (t.raw_payload ->> 'block_number')::bigint),
        'timestamp', coalesce(tx.block_timestamp, (t.raw_payload ->> 'timestamp')::timestamptz),
        'asset', a.symbol,
        'category', t.category,
        'value', t.value_text,
        'contract_address', a.contract_address,
        'token_id', t.token_id
      ) as transfer
    from public.graph_investigation_transfers it
    join public.graph_transfers t on t.id = it.transfer_id
    join public.graph_wallets cp on cp.id = it.counterparty_wallet_id
    join public.graph_assets a on a.id = t.asset_id
    left join public.graph_transactions tx on tx.id = t.transaction_id
    where it.investigation_id = p_investigation_id
  )
  select jsonb_build_object(
    'chain_id', inv.chain_id,
    'network', inv.network,
    'address', inv.target_address,
    'acquired_at', inv.acquired_at,
    'incoming', coalesce(
      (select jsonb_agg(r.transfer order by r.sort_index) from transfer_rows r where r.direction = 'IN'),
      '[]'::jsonb
    ),
    'outgoing', coalesce(
      (select jsonb_agg(r.transfer order by r.sort_index) from transfer_rows r where r.direction = 'OUT'),
      '[]'::jsonb
    ),
    'source', jsonb_build_object(
      'provider', inv.provider,
      'method', inv.provider_method,
      'authority', inv.source_authority
    ),
    'limits', jsonb_build_object(
      'requested_per_direction', inv.requested_per_direction,
      'returned_incoming', inv.returned_incoming,
      'returned_outgoing', inv.returned_outgoing,
      'truncated', inv.truncated,
      'from_date', inv.from_date,
      'to_date', inv.to_date,
      'max_pages_per_direction', inv.max_pages_per_direction
    ),
    'warnings', to_jsonb(inv.warnings)
  )
  from inv;
$$;

-- One graph relationship per counterparty + asset + direction, the same unit
-- WalletFlowGraph renders. DEVIATION: groups by asset id rather than symbol,
-- so two different contracts that share a symbol (a common spam pattern) stay
-- separate relationships instead of being summed together.
create or replace view public.graph_relationship_edges_v
with (security_invoker = true)
as
select
  it.investigation_id,
  it.direction,
  cp.id as counterparty_wallet_id,
  cp.address_normalized as counterparty,
  a.id as asset_id,
  a.symbol as asset,
  a.contract_address,
  count(*)::integer as transfer_count,
  case
    when count(*) filter (where t.value_decimal is null) > 0 then null
    else sum(t.value_decimal)
  end as total_value,
  min(coalesce(tx.block_timestamp, (t.raw_payload ->> 'timestamp')::timestamptz)) as first_transfer_at,
  max(coalesce(tx.block_timestamp, (t.raw_payload ->> 'timestamp')::timestamptz)) as last_transfer_at,
  (array_agg(tx.tx_hash order by it.sort_index))[1] as representative_tx_hash
from public.graph_investigation_transfers it
join public.graph_transfers t on t.id = it.transfer_id
join public.graph_wallets cp on cp.id = it.counterparty_wallet_id
join public.graph_assets a on a.id = t.asset_id
left join public.graph_transactions tx on tx.id = t.transaction_id
group by it.investigation_id, it.direction, cp.id, cp.address_normalized, a.id, a.symbol, a.contract_address;

-- The figures shown in the dashboard side panel ("Results overview").
-- *_visible mirrors the UI cap of 18 relationships per direction.
create or replace view public.graph_investigation_overview_v
with (security_invoker = true)
as
select
  i.id as investigation_id,
  i.channel,
  i.status,
  i.chain_id,
  i.network,
  target.address_normalized as target_address,
  actor.address_normalized as actor_wallet,
  i.acquired_at,
  i.created_at,
  i.returned_incoming as incoming_transfers,
  i.returned_outgoing as outgoing_transfers,
  coalesce(edges.incoming_relationships, 0) as incoming_relationships,
  coalesce(edges.outgoing_relationships, 0) as outgoing_relationships,
  least(coalesce(edges.incoming_relationships, 0), 18) as incoming_relationships_visible,
  least(coalesce(edges.outgoing_relationships, 0), 18) as outgoing_relationships_visible,
  least(coalesce(edges.incoming_relationships, 0), 18)
    + least(coalesce(edges.outgoing_relationships, 0), 18) + 1 as nodes_visible,
  coalesce(assets.asset_counts, '[]'::jsonb) as asset_counts,
  i.truncated,
  i.requested_per_direction,
  i.from_date,
  i.to_date,
  i.warnings,
  i.ingest_warnings,
  i.is_public
from public.graph_investigations i
join public.graph_wallets target on target.id = i.target_wallet_id
left join public.graph_wallets actor on actor.id = i.actor_wallet_id
left join lateral (
  select
    count(*) filter (where e.direction = 'IN')::integer as incoming_relationships,
    count(*) filter (where e.direction = 'OUT')::integer as outgoing_relationships
  from public.graph_relationship_edges_v e
  where e.investigation_id = i.id
) edges on true
left join lateral (
  -- Top 7 assets by transfer count, as in the UI tag cloud.
  select jsonb_agg(jsonb_build_object('asset', ac.asset, 'count', ac.transfers) order by ac.transfers desc, ac.asset) as asset_counts
  from (
    select a.symbol as asset, count(*)::integer as transfers
    from public.graph_investigation_transfers it
    join public.graph_transfers t on t.id = it.transfer_id
    join public.graph_assets a on a.id = t.asset_id
    where it.investigation_id = i.id
    group by a.symbol
    order by transfers desc, a.symbol
    limit 7
  ) ac
) assets on true;

-- ── Security ────────────────────────────────────────────────────────────────

alter table public.graph_chains enable row level security;
alter table public.graph_wallets enable row level security;
alter table public.graph_assets enable row level security;
alter table public.graph_transactions enable row level security;
alter table public.graph_transfers enable row level security;
alter table public.graph_investigations enable row level security;
alter table public.graph_investigation_transfers enable row level security;

revoke all on table
  public.graph_chains,
  public.graph_wallets,
  public.graph_assets,
  public.graph_transactions,
  public.graph_transfers,
  public.graph_investigations,
  public.graph_investigation_transfers,
  public.graph_relationship_edges_v,
  public.graph_investigation_overview_v
from anon, authenticated;

revoke execute on function
  public.graph_ingest_wallet_flow(jsonb, public.graph_access_channel, text, text),
  public.graph_get_wallet_flow_result(uuid),
  public.graph_upsert_wallet(bigint, text),
  public.graph_safe_numeric(text),
  public.graph_asset_category_of(text),
  public.set_graph_updated_at()
from public, anon, authenticated;

-- Helpers are included because the RPCs run with the caller's privileges.
grant execute on function
  public.graph_ingest_wallet_flow(jsonb, public.graph_access_channel, text, text),
  public.graph_get_wallet_flow_result(uuid),
  public.graph_upsert_wallet(bigint, text),
  public.graph_safe_numeric(text),
  public.graph_asset_category_of(text),
  public.set_graph_updated_at()
to service_role;
