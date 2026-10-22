create table server_status (id text primary key, online int, max_players int, uptime_seconds bigint, tps numeric, updated_at timestamptz not null default now());
alter table server_status enable row level security;
create policy status_read on server_status for select using (true);
create view leaderboard_playtime with (security_invoker = false) as
  select p.website_username, p.minecraft_username, t.total_seconds from playtime t join profiles p on p.id = t.user_id
  order by t.total_seconds desc limit 50;
grant select on leaderboard_playtime to anon, authenticated;
create function link_account(p_code text, p_uuid uuid, p_name text) returns boolean
language plpgsql security definer set search_path = public as $$
declare ch link_challenges;
begin
  select * into ch from link_challenges where code = p_code and not used and expires_at > now() for update;
  if not found or lower(ch.mc_username) <> lower(p_name) then return false; end if;
  if exists (select 1 from profiles where mc_uuid = p_uuid) then return false; end if;   -- one identity, one account
  update profiles set mc_uuid = p_uuid, minecraft_username = p_name where id = ch.user_id;
  update link_challenges set used = true where code = p_code;
  return true;
end $$;
revoke all on function link_account from public, anon, authenticated;
grant execute on function link_account to service_role;
