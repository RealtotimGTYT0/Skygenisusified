-- SkyGens core schema. All money-moving logic lives in SECURITY DEFINER functions
-- callable ONLY by service_role (Netlify functions). Browsers can never call them.

create table settings (key text primary key, value jsonb not null);
insert into settings values
 ('sky_per_hour','5'),('sky_per_diamond','50'),('diamond_per_netherite','50'),
 ('gift_allow_self','false'),('gift_daily_limit','10');

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  website_username text unique not null check (website_username ~ '^[A-Za-z0-9_]{3,16}$'),
  minecraft_username text unique check (minecraft_username ~ '^[A-Za-z0-9_]{3,16}$'),
  mc_uuid uuid unique,                      -- set ONLY via in-game link challenge
  role text not null default 'player' check (role in ('player','admin')),
  theme jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create table balances (
  user_id uuid primary key references profiles on delete cascade,
  sky bigint not null default 0 check (sky >= 0),
  diamond bigint not null default 0 check (diamond >= 0),
  netherite bigint not null default 0 check (netherite >= 0)
);
create table playtime (
  user_id uuid primary key references profiles on delete cascade,
  total_seconds bigint not null default 0,
  remainder_seconds int not null default 0 check (remainder_seconds between 0 and 3599)
);
create table ledger (  -- append-only
  id bigserial primary key,
  user_id uuid not null references profiles,
  currency text not null check (currency in ('sky','diamond','netherite')),
  amount bigint not null check (amount <> 0),
  reason text not null, ref_type text, ref_id text,
  idempotency_key text unique,
  created_at timestamptz not null default now()
);
create function ledger_immutable() returns trigger language plpgsql as
$$ begin raise exception 'ledger is append-only'; end $$;
create trigger ledger_no_change before update or delete on ledger
  for each row execute function ledger_immutable();

create table plugin_events (idempotency_key text primary key, server_id text not null, received_at timestamptz not null default now());
create table link_challenges (
  code text primary key, user_id uuid not null references profiles,
  mc_username text not null, expires_at timestamptz not null, used boolean not null default false);

create table store_items (
  id uuid primary key default gen_random_uuid(),
  name text not null, category text not null, rarity text not null default 'common',
  price bigint not null check (price > 0), currency text not null check (currency in ('sky','diamond','netherite')),
  stock int check (stock is null or stock >= 0),      -- null = unlimited
  gift_ok boolean not null default true,
  admin_only boolean not null default false,          -- animated decorations etc. never purchasable/giftable
  needs_delivery boolean not null default false, delivery_payload jsonb,
  active boolean not null default true);
create table orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles, item_id uuid not null references store_items,
  price bigint not null, currency text not null, gift_id uuid,
  idempotency_key text unique not null, created_at timestamptz not null default now());
create table gifts (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references profiles, recipient_id uuid not null references profiles,
  item_id uuid not null references store_items, price bigint not null, currency text not null,
  message text check (char_length(message) <= 120),
  status text not null default 'pending' check (status in ('pending','delivered','claimed','failed')),
  idempotency_key text unique not null, created_at timestamptz not null default now());
create table inventory (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles, item_id uuid not null references store_items,
  source_order uuid not null references orders unique, created_at timestamptz not null default now());
create table deliveries (   -- durable plugin queue; id is the delivery idempotency ID
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles, order_id uuid not null references orders unique,
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending','delivered','failed')),
  attempts int not null default 0, delivered_at timestamptz);
create table audit_log (
  id bigserial primary key, actor uuid, action text not null, target text, detail jsonb,
  created_at timestamptz not null default now());

-- RLS: users may only READ their own rows; every write goes through service_role functions.
do $$ declare t text; begin
 foreach t in array array['settings','profiles','balances','playtime','ledger','plugin_events','link_challenges',
  'store_items','orders','gifts','inventory','deliveries','audit_log'] loop
  execute format('alter table %I enable row level security', t); end loop; end $$;
create policy own_bal on balances for select using (auth.uid() = user_id);
create policy own_pt on playtime for select using (true);                 -- public leaderboard data
create policy own_ledger on ledger for select using (auth.uid() = user_id);
create policy own_orders on orders for select using (auth.uid() = user_id);
create policy own_inv on inventory for select using (auth.uid() = user_id);
create policy gifts_party on gifts for select using (auth.uid() in (sender_id, recipient_id));
create policy items_read on store_items for select using (active and not admin_only);
create policy profiles_read on profiles for select using (true);
-- Profile self-update limited to non-privileged columns (role/mc_uuid/balances can't be touched):
revoke update on profiles from anon, authenticated;
grant update (theme) on profiles to authenticated;
create policy profiles_self on profiles for update using (auth.uid() = id);
-- Admin-only decorations enforced in DB, not UI:
create function guard_theme() returns trigger language plpgsql as $$
begin
  if (new.theme ? 'animated') and coalesce((new.theme->>'animated')::bool,false)
     and (select role from profiles where id = new.id) <> 'admin'
  then raise exception 'animated themes are admin-only'; end if;
  return new; end $$;
create trigger theme_guard before insert or update of theme on profiles
  for each row execute function guard_theme();

create function setting_int(k text) returns bigint language sql stable as
$$ select (value #>> '{}')::bigint from settings where key = k $$;

-- Internal credit helper (ledger + balance in one statement path)
create function _move(p_user uuid, p_cur text, p_amt bigint, p_reason text, p_ref_type text, p_ref text, p_key text)
returns void language plpgsql as $$
begin
  insert into ledger(user_id,currency,amount,reason,ref_type,ref_id,idempotency_key)
    values (p_user,p_cur,p_amt,p_reason,p_ref_type,p_ref,p_key);
  execute format('update balances set %I = %I + $1 where user_id = $2', p_cur, p_cur) using p_amt, p_user;
end $$;  -- CHECK (>= 0) rejects overdraft and rolls back the whole transaction

-- Playtime: idempotent, incremental, partial hours carried in remainder_seconds.
create function apply_playtime(p_server text, p_user uuid, p_seconds int, p_key text)
returns bigint language plpgsql security definer set search_path = public as $$
declare rem int; hrs int; reward bigint := 0;
begin
  if p_seconds <= 0 or p_seconds > 3600 then raise exception 'invalid seconds'; end if;
  insert into plugin_events(idempotency_key, server_id) values (p_key, p_server)
    on conflict do nothing;
  if not found then return 0; end if;                      -- replay: no-op
  insert into playtime(user_id) values (p_user) on conflict do nothing;
  insert into balances(user_id) values (p_user) on conflict do nothing;
  update playtime set total_seconds = total_seconds + p_seconds,
         remainder_seconds = remainder_seconds + p_seconds
   where user_id = p_user returning remainder_seconds into rem;
  hrs := rem / 3600;
  if hrs > 0 then
    reward := hrs * setting_int('sky_per_hour');
    update playtime set remainder_seconds = rem % 3600 where user_id = p_user;
    perform _move(p_user,'sky',reward,'playtime_reward','playtime',p_key,'pt:'||p_key);
  end if;
  return reward;
end $$;

-- Exchange: p_qty = number of TARGET tokens wanted (whole numbers only).
create function exchange_currency(p_user uuid, p_to text, p_qty bigint, p_key text)
returns void language plpgsql security definer set search_path = public as $$
declare src text; cost bigint;
begin
  if p_qty <= 0 then raise exception 'invalid quantity'; end if;
  if p_to = 'diamond' then src := 'sky'; cost := p_qty * setting_int('sky_per_diamond');
  elsif p_to = 'netherite' then src := 'diamond'; cost := p_qty * setting_int('diamond_per_netherite');
  else raise exception 'invalid target'; end if;
  perform 1 from balances where user_id = p_user for update;      -- serialize concurrent spends
  perform _move(p_user, src, -cost, 'exchange_out', 'exchange', p_key, 'ex-out:'||p_key);
  perform _move(p_user, p_to, p_qty, 'exchange_in', 'exchange', p_key, 'ex-in:'||p_key);
end $$;

-- Purchase (self or as gift via p_gift). Price always read from DB, never from client.
create function _buy(p_payer uuid, p_owner uuid, p_item uuid, p_key text, p_gift uuid)
returns uuid language plpgsql as $$
declare it store_items; oid uuid;
begin
  select * into it from store_items where id = p_item and active for update;
  if not found or it.admin_only then raise exception 'item unavailable'; end if;
  if it.stock is not null then
    if it.stock < 1 then raise exception 'out of stock'; end if;
    update store_items set stock = stock - 1 where id = it.id; end if;
  perform 1 from balances where user_id = p_payer for update;
  perform _move(p_payer, it.currency, -it.price, 'purchase', 'item', it.id::text, 'buy:'||p_key);
  insert into orders(user_id,item_id,price,currency,gift_id,idempotency_key)
    values (p_owner,it.id,it.price,it.currency,p_gift,p_key) returning id into oid;
  insert into inventory(user_id,item_id,source_order) values (p_owner,it.id,oid);
  if it.needs_delivery then
    insert into deliveries(user_id,order_id,payload) values (p_owner,oid,coalesce(it.delivery_payload,'{}')); end if;
  return oid;
end $$;

create function purchase_item(p_user uuid, p_item uuid, p_key text)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  return coalesce((select id from orders where idempotency_key = p_key),   -- duplicate request
                  _buy(p_user, p_user, p_item, p_key, null));
end $$;

create function send_gift(p_sender uuid, p_recipient uuid, p_item uuid, p_msg text, p_key text)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid; it store_items;
begin
  select id into gid from gifts where idempotency_key = p_key;
  if found then return gid; end if;
  if p_sender = p_recipient and (select value from settings where key='gift_allow_self') = 'false'
    then raise exception 'self-gifting disabled'; end if;
  perform 1 from profiles where id = p_recipient;
  if not found then raise exception 'recipient not found'; end if;
  select * into it from store_items where id = p_item;
  if not found or not it.gift_ok or it.admin_only then raise exception 'item not giftable'; end if;
  if (select count(*) from gifts where sender_id = p_sender and created_at > now() - interval '1 day')
       >= setting_int('gift_daily_limit') then raise exception 'daily gift limit reached'; end if;
  gid := gen_random_uuid();
  insert into gifts(id,sender_id,recipient_id,item_id,price,currency,message,idempotency_key)
    values (gid,p_sender,p_recipient,p_item,it.price,it.currency,p_msg,p_key);
  perform _buy(p_sender, p_recipient, p_item, 'gift:'||p_key, gid);
  return gid;
end $$;

-- Only service_role (server-side functions) may execute these.
revoke all on function apply_playtime, exchange_currency, purchase_item, send_gift, _buy, _move
  from public, anon, authenticated;
grant execute on function apply_playtime, exchange_currency, purchase_item, send_gift to service_role;
