-- Convert the app from Magic Link auth to public nickname mode.
-- Run this once in Supabase SQL Editor after the original schema.sql.

create extension if not exists pgcrypto with schema extensions;

alter table public.predictions
  alter column user_id drop not null;

alter table public.predictions
  add column if not exists guest_id uuid,
  add column if not exists display_name text,
  add column if not exists edit_token_hash text;

update public.predictions
set guest_id = coalesce(guest_id, user_id)
where guest_id is null
  and user_id is not null;

create unique index if not exists predictions_unique_guest_match_idx
on public.predictions (guest_id, match_id)
where guest_id is not null;

create index if not exists predictions_guest_id_idx
on public.predictions (guest_id);

create table if not exists public.guest_players (
  id uuid primary key,
  display_name text not null,
  edit_token_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint guest_players_display_name_check check (char_length(display_name) between 2 and 40)
);

drop trigger if exists guest_players_set_updated_at on public.guest_players;
create trigger guest_players_set_updated_at
before update on public.guest_players
for each row execute function public.set_updated_at();

insert into public.guest_players (id, display_name, edit_token_hash)
select distinct on (guest_id)
  guest_id,
  coalesce(nullif(display_name, ''), 'Player'),
  edit_token_hash
from public.predictions
where guest_id is not null
  and edit_token_hash is not null
on conflict (id) do nothing;

drop function if exists public.leaderboard();

create function public.leaderboard()
returns table (
  player_key text,
  display_name text,
  total_points integer,
  exact_scores integer,
  correct_outcomes integer,
  predictions_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with guest_rows as (
    select
      gp.id::text as player_key,
      gp.display_name,
      coalesce(sum(p.points), 0)::integer as total_points,
      count(p.id) filter (where p.points = 2)::integer as exact_scores,
      count(p.id) filter (where p.points = 1)::integer as correct_outcomes,
      count(p.id)::integer as predictions_count
    from public.guest_players gp
    left join public.predictions p on p.guest_id = gp.id
    group by gp.id, gp.display_name
  ),
  auth_rows as (
    select
      p.user_id::text as player_key,
      coalesce(
        max(nullif(pr.display_name, '')),
        nullif(split_part(max(coalesce(pr.email, '')), '@', 1), ''),
        'Player'
      ) as display_name,
      coalesce(sum(p.points), 0)::integer as total_points,
      count(*) filter (where p.points = 2)::integer as exact_scores,
      count(*) filter (where p.points = 1)::integer as correct_outcomes,
      count(*)::integer as predictions_count
    from public.predictions p
    left join public.profiles pr on pr.id = p.user_id
    where p.guest_id is null
      and p.user_id is not null
    group by p.user_id
  )
  select * from guest_rows
  union all
  select * from auth_rows
  order by total_points desc, exact_scores desc, correct_outcomes desc, display_name asc;
$$;

create or replace function public.participant_count()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select (
    (select count(*) from public.guest_players)
    +
    (
      select count(distinct user_id)
      from public.predictions
      where guest_id is null
        and user_id is not null
    )
  )::integer;
$$;

create or replace function public.register_guest_player(
  p_guest_id uuid,
  p_edit_token text,
  p_display_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_display_name text;
  v_hash text;
  v_existing_hash text;
begin
  v_display_name := trim(regexp_replace(coalesce(p_display_name, ''), '\s+', ' ', 'g'));

  if p_guest_id is null then
    raise exception 'Missing player id.';
  end if;

  if length(coalesce(p_edit_token, '')) < 32 then
    raise exception 'Missing player edit token.';
  end if;

  if length(v_display_name) < 2 or length(v_display_name) > 40 then
    raise exception 'Display name must be 2 to 40 characters.';
  end if;

  v_hash := encode(extensions.digest(p_edit_token, 'sha256'::text), 'hex');

  select edit_token_hash
  into v_existing_hash
  from public.guest_players
  where id = p_guest_id
  for update;

  if found and v_existing_hash is distinct from v_hash then
    raise exception 'This name belongs to another browser.';
  end if;

  insert into public.guest_players (id, display_name, edit_token_hash)
  values (p_guest_id, v_display_name, v_hash)
  on conflict (id) do update set
    display_name = excluded.display_name,
    updated_at = now()
  where public.guest_players.edit_token_hash = excluded.edit_token_hash;

  if not found then
    raise exception 'This name belongs to another browser.';
  end if;
end;
$$;

create or replace function public.save_guest_prediction(
  p_guest_id uuid,
  p_edit_token text,
  p_display_name text,
  p_match_id bigint,
  p_home_score integer,
  p_away_score integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_display_name text;
  v_hash text;
  v_existing_hash text;
begin
  v_display_name := trim(regexp_replace(coalesce(p_display_name, ''), '\s+', ' ', 'g'));

  if p_guest_id is null then
    raise exception 'Missing player id.';
  end if;

  if length(coalesce(p_edit_token, '')) < 32 then
    raise exception 'Missing player edit token.';
  end if;

  if length(v_display_name) < 2 or length(v_display_name) > 40 then
    raise exception 'Display name must be 2 to 40 characters.';
  end if;

  perform public.register_guest_player(p_guest_id, p_edit_token, v_display_name);

  if p_home_score is null or p_away_score is null
    or p_home_score < 0 or p_home_score > 99
    or p_away_score < 0 or p_away_score > 99 then
    raise exception 'Scores must be whole numbers from 0 to 99.';
  end if;

  if not exists (
    select 1
    from public.matches m
    where m.football_data_id = p_match_id
      and m.status = 'SCHEDULED'
      and m.utc_date > now()
  ) then
    raise exception 'This match is locked.';
  end if;

  v_hash := encode(extensions.digest(p_edit_token, 'sha256'::text), 'hex');

  select edit_token_hash
  into v_existing_hash
  from public.predictions
  where guest_id = p_guest_id
    and match_id = p_match_id
  for update;

  if found and v_existing_hash is distinct from v_hash then
    raise exception 'This prediction belongs to another browser.';
  end if;

  update public.predictions
  set display_name = v_display_name,
      updated_at = now()
  where guest_id = p_guest_id
    and edit_token_hash = v_hash
    and display_name is distinct from v_display_name;

  insert into public.predictions (
    guest_id,
    display_name,
    edit_token_hash,
    match_id,
    home_score,
    away_score,
    points
  )
  values (
    p_guest_id,
    v_display_name,
    v_hash,
    p_match_id,
    p_home_score,
    p_away_score,
    0
  )
  on conflict (guest_id, match_id) where guest_id is not null
  do update set
    display_name = excluded.display_name,
    home_score = excluded.home_score,
    away_score = excluded.away_score,
    points = 0,
    updated_at = now()
  where public.predictions.edit_token_hash = excluded.edit_token_hash;

  if not found then
    raise exception 'This prediction belongs to another browser.';
  end if;
end;
$$;

alter table public.guest_players enable row level security;

drop policy if exists "guest players are visible to everyone" on public.guest_players;
create policy "guest players are visible to everyone"
on public.guest_players
for select
to anon, authenticated
using (true);

drop policy if exists "authenticated users can read predictions for realtime" on public.predictions;
drop policy if exists "public can read predictions for realtime" on public.predictions;
create policy "public can read predictions for realtime"
on public.predictions
for select
to anon, authenticated
using (true);

drop policy if exists "users can insert own open predictions" on public.predictions;
drop policy if exists "users can update own open predictions" on public.predictions;

revoke all on public.predictions from anon, authenticated;
grant select (
  id,
  user_id,
  guest_id,
  match_id,
  home_score,
  away_score,
  points,
  display_name,
  created_at,
  updated_at
) on public.predictions to anon, authenticated;

grant execute on function public.leaderboard() to anon, authenticated;
grant execute on function public.participant_count() to anon, authenticated;
grant execute on function public.register_guest_player(uuid, text, text) to anon, authenticated;
grant execute on function public.save_guest_prediction(uuid, text, text, bigint, integer, integer) to anon, authenticated;

revoke all on public.guest_players from anon, authenticated;
grant select (id, display_name, created_at, updated_at) on public.guest_players to anon, authenticated;

alter table public.predictions replica identity full;
alter table public.guest_players replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'predictions'
  ) then
    execute 'alter publication supabase_realtime add table public.predictions';
  end if;
exception
  when duplicate_object then
    null;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'guest_players'
  ) then
    execute 'alter publication supabase_realtime add table public.guest_players';
  end if;
exception
  when duplicate_object then
    null;
end;
$$;
