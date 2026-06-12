-- World Cup 2026 prediction app schema for Supabase.
-- Run this whole file in the Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.matches (
  football_data_id bigint primary key,
  competition_code text not null default 'WC',
  season_year integer not null default 2026,
  utc_date timestamptz not null,
  status text not null,
  stage text,
  group_name text,
  matchday integer,
  home_team_id integer,
  home_team_name text not null default 'TBD',
  home_team_tla text,
  home_team_crest text,
  away_team_id integer,
  away_team_name text not null default 'TBD',
  away_team_tla text,
  away_team_crest text,
  score_home integer,
  score_away integer,
  score_duration text,
  raw jsonb not null default '{}'::jsonb,
  last_fetched_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint matches_status_check check (
    status in (
      'SCHEDULED',
      'TIMED',
      'IN_PLAY',
      'PAUSED',
      'EXTRA_TIME',
      'PENALTY_SHOOTOUT',
      'FINISHED',
      'SUSPENDED',
      'POSTPONED',
      'CANCELLED',
      'AWARDED'
    )
  ),
  constraint matches_score_home_check check (score_home is null or score_home >= 0),
  constraint matches_score_away_check check (score_away is null or score_away >= 0)
);

create index if not exists matches_utc_date_idx on public.matches (utc_date);
create index if not exists matches_status_idx on public.matches (status);
create index if not exists matches_stage_idx on public.matches (stage);

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text,
  role text not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_role_check check (role in ('user', 'admin'))
);

create index if not exists profiles_role_idx on public.profiles (role);

create table if not exists public.predictions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  match_id bigint not null references public.matches (football_data_id) on delete cascade,
  home_score integer not null,
  away_score integer not null,
  points integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint predictions_unique_user_match unique (user_id, match_id),
  constraint predictions_home_score_check check (home_score between 0 and 99),
  constraint predictions_away_score_check check (away_score between 0 and 99),
  constraint predictions_points_check check (points between 0 and 2)
);

create index if not exists predictions_user_id_idx on public.predictions (user_id);
create index if not exists predictions_match_id_idx on public.predictions (match_id);
create index if not exists predictions_points_idx on public.predictions (points desc);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists matches_set_updated_at on public.matches;
create trigger matches_set_updated_at
before update on public.matches
for each row execute function public.set_updated_at();

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists predictions_set_updated_at on public.predictions;
create trigger predictions_set_updated_at
before update on public.predictions
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1))
  )
  on conflict (id) do update
    set email = excluded.email,
        display_name = coalesce(public.profiles.display_name, excluded.display_name),
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.leaderboard()
returns table (
  user_id uuid,
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
  select
    p.user_id,
    coalesce(nullif(pr.display_name, ''), split_part(coalesce(pr.email, ''), '@', 1), 'Player') as display_name,
    coalesce(sum(p.points), 0)::integer as total_points,
    count(*) filter (where p.points = 2)::integer as exact_scores,
    count(*) filter (where p.points = 1)::integer as correct_outcomes,
    count(*)::integer as predictions_count
  from public.predictions p
  left join public.profiles pr on pr.id = p.user_id
  group by p.user_id, pr.display_name, pr.email
  order by total_points desc, exact_scores desc, correct_outcomes desc, display_name asc;
$$;

create or replace function public.participant_count()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(distinct user_id)::integer
  from public.predictions;
$$;

create or replace function public.recalculate_prediction_points()
returns void
language sql
security definer
set search_path = public
as $$
  update public.predictions p
  set points =
    case
      when m.status = 'FINISHED' and m.score_home is not null and m.score_away is not null then
        case
          when p.home_score = m.score_home and p.away_score = m.score_away then 2
          when sign(p.home_score - p.away_score) = sign(m.score_home - m.score_away) then 1
          else 0
        end
      else 0
    end,
    updated_at = now()
  from public.matches m
  where m.football_data_id = p.match_id;
$$;

alter table public.matches enable row level security;
alter table public.profiles enable row level security;
alter table public.predictions enable row level security;

drop policy if exists "matches are visible to everyone" on public.matches;
create policy "matches are visible to everyone"
on public.matches
for select
to anon, authenticated
using (true);

drop policy if exists "profiles are visible to owner" on public.profiles;
create policy "profiles are visible to owner"
on public.profiles
for select
to authenticated
using (id = auth.uid());

drop policy if exists "users can update own display name" on public.profiles;
create policy "users can update own display name"
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "authenticated users can read predictions for realtime" on public.predictions;
create policy "authenticated users can read predictions for realtime"
on public.predictions
for select
to authenticated
using (true);

drop policy if exists "users can insert own open predictions" on public.predictions;
create policy "users can insert own open predictions"
on public.predictions
for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.matches m
    where m.football_data_id = match_id
      and m.status = 'SCHEDULED'
      and m.utc_date > now()
  )
);

drop policy if exists "users can update own open predictions" on public.predictions;
create policy "users can update own open predictions"
on public.predictions
for update
to authenticated
using (
  user_id = auth.uid()
  and exists (
    select 1
    from public.matches m
    where m.football_data_id = match_id
      and m.status = 'SCHEDULED'
      and m.utc_date > now()
  )
)
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.matches m
    where m.football_data_id = match_id
      and m.status = 'SCHEDULED'
      and m.utc_date > now()
  )
);

revoke all on public.matches from anon, authenticated;
grant select on public.matches to anon, authenticated;

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;

revoke all on public.predictions from anon, authenticated;
grant select on public.predictions to authenticated;
grant insert (user_id, match_id, home_score, away_score) on public.predictions to authenticated;
grant update (home_score, away_score) on public.predictions to authenticated;

grant execute on function public.leaderboard() to anon, authenticated;
grant execute on function public.participant_count() to anon, authenticated;
revoke execute on function public.recalculate_prediction_points() from public, anon, authenticated;
grant execute on function public.recalculate_prediction_points() to service_role;

alter table public.predictions replica identity full;

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
