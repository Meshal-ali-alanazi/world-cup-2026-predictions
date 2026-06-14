-- Optional full-feature support for the current public-nickname app.
-- This file is compatible with the existing schema in supabase/schema.sql and
-- supabase/public-nickname-mode.sql. It does not replace the current public
-- display-name login flow.
--
-- Important: the prompt supplied dates but not kickoff times. The seed rows
-- below use 20:00:00 UTC placeholders. Update utc_date values when official
-- kickoff times are available for your source.

alter table public.matches
  add column if not exists match_number integer,
  add column if not exists stadium text,
  add column if not exists city text,
  add column if not exists country text,
  add column if not exists home_penalties integer,
  add column if not exists away_penalties integer,
  add column if not exists winner text;

create unique index if not exists matches_match_number_unique_idx
on public.matches (match_number)
where match_number is not null;

create table if not exists public.group_standings (
  id bigserial primary key,
  group_name text not null,
  team text not null,
  played integer not null default 0,
  won integer not null default 0,
  drawn integer not null default 0,
  lost integer not null default 0,
  goals_for integer not null default 0,
  goals_against integer not null default 0,
  goal_difference integer not null default 0,
  points integer not null default 0,
  position integer not null default 0,
  updated_at timestamptz not null default now(),
  constraint group_standings_unique_team unique (group_name, team)
);

alter table public.group_standings enable row level security;

drop policy if exists "group standings are visible to everyone" on public.group_standings;
create policy "group standings are visible to everyone"
on public.group_standings
for select
to anon, authenticated
using (true);

grant select on public.group_standings to anon, authenticated;

create or replace function public.refresh_group_standings()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.group_standings;

  insert into public.group_standings (group_name, team)
  select distinct group_name, team
  from (
    select group_name, home_team_name as team
    from public.matches
    where group_name is not null
    union
    select group_name, away_team_name as team
    from public.matches
    where group_name is not null
  ) teams
  where team is not null;

  with results as (
    select
      group_name,
      home_team_name,
      away_team_name,
      score_home,
      score_away
    from public.matches
    where group_name is not null
      and status = 'FINISHED'
      and score_home is not null
      and score_away is not null
  ),
  team_rows as (
    select
      group_name,
      home_team_name as team,
      1 as played,
      case when score_home > score_away then 1 else 0 end as won,
      case when score_home = score_away then 1 else 0 end as drawn,
      case when score_home < score_away then 1 else 0 end as lost,
      score_home as goals_for,
      score_away as goals_against,
      score_home - score_away as goal_difference,
      case when score_home > score_away then 3 when score_home = score_away then 1 else 0 end as points
    from results
    union all
    select
      group_name,
      away_team_name as team,
      1 as played,
      case when score_away > score_home then 1 else 0 end as won,
      case when score_away = score_home then 1 else 0 end as drawn,
      case when score_away < score_home then 1 else 0 end as lost,
      score_away as goals_for,
      score_home as goals_against,
      score_away - score_home as goal_difference,
      case when score_away > score_home then 3 when score_away = score_home then 1 else 0 end as points
    from results
  ),
  totals as (
    select
      group_name,
      team,
      sum(played)::integer as played,
      sum(won)::integer as won,
      sum(drawn)::integer as drawn,
      sum(lost)::integer as lost,
      sum(goals_for)::integer as goals_for,
      sum(goals_against)::integer as goals_against,
      sum(goal_difference)::integer as goal_difference,
      sum(points)::integer as points
    from team_rows
    group by group_name, team
  ),
  ranked as (
    select
      *,
      row_number() over (
        partition by group_name
        order by points desc, goal_difference desc, goals_for desc, team asc
      )::integer as position
    from totals
  )
  update public.group_standings gs
  set played = r.played,
      won = r.won,
      drawn = r.drawn,
      lost = r.lost,
      goals_for = r.goals_for,
      goals_against = r.goals_against,
      goal_difference = r.goal_difference,
      points = r.points,
      position = r.position,
      updated_at = now()
  from ranked r
  where gs.group_name = r.group_name
    and gs.team = r.team;

  with ranked_all as (
    select
      id,
      row_number() over (
        partition by group_name
        order by points desc, goal_difference desc, goals_for desc, team asc
      )::integer as new_position
    from public.group_standings
  )
  update public.group_standings gs
  set position = ranked_all.new_position
  from ranked_all
  where ranked_all.id = gs.id;
end;
$$;

grant execute on function public.refresh_group_standings() to service_role;

insert into public.matches (
  football_data_id, competition_code, season_year, utc_date, status, stage,
  group_name, matchday, home_team_name, away_team_name,
  match_number, stadium, city, country
) values
  (2026001, 'WC', 2026, '2026-06-11 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 1, 'Mexico', 'South Africa', 1, 'Estadio Azteca', 'Mexico City', 'Mexico'),
  (2026002, 'WC', 2026, '2026-06-11 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 1, 'South Korea', 'Czechia', 2, 'Estadio Akron', 'Zapopan', 'Mexico'),
  (2026003, 'WC', 2026, '2026-06-12 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_B', 1, 'Canada', 'Bosnia and Herzegovina', 3, 'BMO Field', 'Toronto', 'Canada'),
  (2026004, 'WC', 2026, '2026-06-12 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_D', 1, 'United States', 'Paraguay', 4, 'SoFi Stadium', 'Los Angeles (Inglewood)', 'USA'),
  (2026005, 'WC', 2026, '2026-06-13 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_B', 1, 'Qatar', 'Switzerland', 5, 'Levi''s Stadium', 'Santa Clara', 'USA'),
  (2026006, 'WC', 2026, '2026-06-13 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_C', 1, 'Brazil', 'Morocco', 6, 'MetLife Stadium', 'East Rutherford', 'USA'),
  (2026007, 'WC', 2026, '2026-06-13 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_C', 1, 'Haiti', 'Scotland', 7, 'Gillette Stadium', 'Foxborough', 'USA'),
  (2026008, 'WC', 2026, '2026-06-13 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_D', 1, 'Australia', 'Türkiye', 8, 'BC Place', 'Vancouver', 'Canada'),
  (2026009, 'WC', 2026, '2026-06-14 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_E', 1, 'Germany', 'Curaçao', 9, 'NRG Stadium', 'Houston', 'USA'),
  (2026010, 'WC', 2026, '2026-06-14 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_F', 1, 'Netherlands', 'Japan', 10, 'AT&T Stadium', 'Arlington (Dallas)', 'USA'),
  (2026011, 'WC', 2026, '2026-06-14 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_E', 1, 'Ivory Coast', 'Ecuador', 11, 'Lincoln Financial Field', 'Philadelphia', 'USA'),
  (2026012, 'WC', 2026, '2026-06-14 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_F', 1, 'Sweden', 'Tunisia', 12, 'Estadio BBVA', 'Guadalupe (Monterrey)', 'Mexico'),
  (2026013, 'WC', 2026, '2026-06-15 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_H', 1, 'Spain', 'Cape Verde', 13, 'Mercedes-Benz Stadium', 'Atlanta', 'USA'),
  (2026014, 'WC', 2026, '2026-06-15 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_G', 1, 'Belgium', 'Egypt', 14, 'Lumen Field', 'Seattle', 'USA'),
  (2026015, 'WC', 2026, '2026-06-15 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_H', 1, 'Saudi Arabia', 'Uruguay', 15, 'Hard Rock Stadium', 'Miami', 'USA'),
  (2026016, 'WC', 2026, '2026-06-16 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_G', 1, 'Iran', 'New Zealand', 16, 'SoFi Stadium', 'Los Angeles (Inglewood)', 'USA'),
  (2026017, 'WC', 2026, '2026-06-16 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_I', 1, 'France', 'Senegal', 17, 'MetLife Stadium', 'East Rutherford', 'USA'),
  (2026018, 'WC', 2026, '2026-06-16 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_I', 1, 'Iraq', 'Norway', 18, 'Gillette Stadium', 'Foxborough', 'USA'),
  (2026019, 'WC', 2026, '2026-06-16 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_J', 1, 'Argentina', 'Algeria', 19, 'Arrowhead Stadium', 'Kansas City', 'USA'),
  (2026020, 'WC', 2026, '2026-06-17 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_J', 1, 'Austria', 'Jordan', 20, 'Levi''s Stadium', 'Santa Clara', 'USA'),
  (2026021, 'WC', 2026, '2026-06-17 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_K', 1, 'Portugal', 'DR Congo', 21, 'NRG Stadium', 'Houston', 'USA'),
  (2026022, 'WC', 2026, '2026-06-17 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_L', 1, 'England', 'Croatia', 22, 'AT&T Stadium', 'Arlington (Dallas)', 'USA'),
  (2026023, 'WC', 2026, '2026-06-17 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_L', 1, 'Ghana', 'Panama', 23, 'BMO Field', 'Toronto', 'Canada'),
  (2026024, 'WC', 2026, '2026-06-17 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_K', 1, 'Uzbekistan', 'Colombia', 24, 'Estadio Azteca', 'Mexico City', 'Mexico'),
  (2026025, 'WC', 2026, '2026-06-18 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 2, 'Czechia', 'South Africa', 25, 'Mercedes-Benz Stadium', 'Atlanta', 'USA'),
  (2026026, 'WC', 2026, '2026-06-18 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_B', 2, 'Switzerland', 'Bosnia and Herzegovina', 26, 'SoFi Stadium', 'Los Angeles (Inglewood)', 'USA'),
  (2026027, 'WC', 2026, '2026-06-18 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_B', 2, 'Canada', 'Qatar', 27, 'BC Place', 'Vancouver', 'Canada'),
  (2026028, 'WC', 2026, '2026-06-18 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 2, 'Mexico', 'South Korea', 28, 'Estadio Akron', 'Zapopan (Guadalajara)', 'Mexico'),
  (2026029, 'WC', 2026, '2026-06-19 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_D', 2, 'United States', 'Australia', 29, 'Lumen Field', 'Seattle', 'USA'),
  (2026030, 'WC', 2026, '2026-06-19 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_C', 2, 'Scotland', 'Morocco', 30, 'Gillette Stadium', 'Foxborough', 'USA'),
  (2026031, 'WC', 2026, '2026-06-19 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_C', 2, 'Brazil', 'Haiti', 31, 'Lincoln Financial Field', 'Philadelphia', 'USA'),
  (2026032, 'WC', 2026, '2026-06-19 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_D', 2, 'Türkiye', 'Paraguay', 32, 'Levi''s Stadium', 'Santa Clara', 'USA'),
  (2026033, 'WC', 2026, '2026-06-20 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_F', 2, 'Netherlands', 'Sweden', 33, 'NRG Stadium', 'Houston', 'USA'),
  (2026034, 'WC', 2026, '2026-06-20 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_E', 2, 'Germany', 'Ivory Coast', 34, 'BMO Field', 'Toronto', 'Canada'),
  (2026035, 'WC', 2026, '2026-06-20 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_E', 2, 'Ecuador', 'Curaçao', 35, 'Arrowhead Stadium', 'Kansas City', 'USA'),
  (2026036, 'WC', 2026, '2026-06-20 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_F', 2, 'Tunisia', 'Japan', 36, 'Estadio BBVA', 'Guadalupe (Monterrey)', 'Mexico'),
  (2026037, 'WC', 2026, '2026-06-21 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_H', 2, 'Spain', 'Saudi Arabia', 37, 'Mercedes-Benz Stadium', 'Atlanta', 'USA'),
  (2026038, 'WC', 2026, '2026-06-21 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_G', 2, 'Belgium', 'Iran', 38, 'SoFi Stadium', 'Los Angeles (Inglewood)', 'USA'),
  (2026039, 'WC', 2026, '2026-06-21 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_H', 2, 'Uruguay', 'Cape Verde', 39, 'Hard Rock Stadium', 'Miami', 'USA'),
  (2026040, 'WC', 2026, '2026-06-21 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_G', 2, 'New Zealand', 'Egypt', 40, 'BC Place', 'Vancouver', 'Canada'),
  (2026041, 'WC', 2026, '2026-06-22 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_J', 2, 'Argentina', 'Austria', 41, 'AT&T Stadium', 'Arlington (Dallas)', 'USA'),
  (2026042, 'WC', 2026, '2026-06-22 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_I', 2, 'France', 'Iraq', 42, 'Lincoln Financial Field', 'Philadelphia', 'USA'),
  (2026043, 'WC', 2026, '2026-06-22 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_I', 2, 'Norway', 'Senegal', 43, 'MetLife Stadium', 'East Rutherford', 'USA'),
  (2026044, 'WC', 2026, '2026-06-22 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_J', 2, 'Jordan', 'Algeria', 44, 'Levi''s Stadium', 'Santa Clara', 'USA'),
  (2026045, 'WC', 2026, '2026-06-23 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_K', 2, 'Portugal', 'Uzbekistan', 45, 'NRG Stadium', 'Houston', 'USA'),
  (2026046, 'WC', 2026, '2026-06-23 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_L', 2, 'England', 'Ghana', 46, 'Gillette Stadium', 'Foxborough', 'USA'),
  (2026047, 'WC', 2026, '2026-06-23 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_L', 2, 'Panama', 'Croatia', 47, 'BMO Field', 'Toronto', 'Canada'),
  (2026048, 'WC', 2026, '2026-06-23 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_K', 2, 'Colombia', 'DR Congo', 48, 'Estadio Akron', 'Zapopan (Guadalajara)', 'Mexico'),
  (2026049, 'WC', 2026, '2026-06-24 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_B', 3, 'Switzerland', 'Canada', 49, 'BC Place', 'Vancouver', 'Canada'),
  (2026050, 'WC', 2026, '2026-06-24 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_B', 3, 'Bosnia and Herzegovina', 'Qatar', 50, 'Lumen Field', 'Seattle', 'USA'),
  (2026051, 'WC', 2026, '2026-06-24 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_C', 3, 'Scotland', 'Brazil', 51, 'Hard Rock Stadium', 'Miami', 'USA'),
  (2026052, 'WC', 2026, '2026-06-24 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_C', 3, 'Morocco', 'Haiti', 52, 'Mercedes-Benz Stadium', 'Atlanta', 'USA'),
  (2026053, 'WC', 2026, '2026-06-24 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 3, 'Czechia', 'Mexico', 53, 'Estadio Azteca', 'Mexico City', 'Mexico'),
  (2026054, 'WC', 2026, '2026-06-24 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 3, 'South Africa', 'South Korea', 54, 'Estadio BBVA', 'Guadalupe (Monterrey)', 'Mexico'),
  (2026055, 'WC', 2026, '2026-06-25 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_E', 3, 'Ecuador', 'Germany', 55, 'MetLife Stadium', 'East Rutherford', 'USA'),
  (2026056, 'WC', 2026, '2026-06-25 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_E', 3, 'Curaçao', 'Ivory Coast', 56, 'Lincoln Financial Field', 'Philadelphia', 'USA'),
  (2026057, 'WC', 2026, '2026-06-25 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_F', 3, 'Japan', 'Sweden', 57, 'AT&T Stadium', 'Arlington (Dallas)', 'USA'),
  (2026058, 'WC', 2026, '2026-06-25 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_F', 3, 'Tunisia', 'Netherlands', 58, 'Arrowhead Stadium', 'Kansas City', 'USA'),
  (2026059, 'WC', 2026, '2026-06-25 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_D', 3, 'Türkiye', 'United States', 59, 'SoFi Stadium', 'Los Angeles (Inglewood)', 'USA'),
  (2026060, 'WC', 2026, '2026-06-25 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_D', 3, 'Paraguay', 'Australia', 60, 'Levi''s Stadium', 'Santa Clara', 'USA'),
  (2026061, 'WC', 2026, '2026-06-26 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_I', 3, 'Norway', 'France', 61, 'Gillette Stadium', 'Foxborough', 'USA'),
  (2026062, 'WC', 2026, '2026-06-26 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_I', 3, 'Senegal', 'Iraq', 62, 'BMO Field', 'Toronto', 'Canada'),
  (2026063, 'WC', 2026, '2026-06-26 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_H', 3, 'Cape Verde', 'Saudi Arabia', 63, 'NRG Stadium', 'Houston', 'USA'),
  (2026064, 'WC', 2026, '2026-06-26 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_H', 3, 'Uruguay', 'Spain', 64, 'Estadio Akron', 'Zapopan (Guadalajara)', 'Mexico'),
  (2026065, 'WC', 2026, '2026-06-26 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_G', 3, 'Egypt', 'Iran', 65, 'Lumen Field', 'Seattle', 'USA'),
  (2026066, 'WC', 2026, '2026-06-26 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_G', 3, 'New Zealand', 'Belgium', 66, 'BC Place', 'Vancouver', 'Canada'),
  (2026067, 'WC', 2026, '2026-06-27 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_L', 3, 'Panama', 'England', 67, 'MetLife Stadium', 'East Rutherford', 'USA'),
  (2026068, 'WC', 2026, '2026-06-27 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_L', 3, 'Croatia', 'Ghana', 68, 'Lincoln Financial Field', 'Philadelphia', 'USA'),
  (2026069, 'WC', 2026, '2026-06-27 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_K', 3, 'Colombia', 'Portugal', 69, 'Hard Rock Stadium', 'Miami', 'USA'),
  (2026070, 'WC', 2026, '2026-06-27 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_K', 3, 'DR Congo', 'Uzbekistan', 70, 'Mercedes-Benz Stadium', 'Atlanta', 'USA'),
  (2026071, 'WC', 2026, '2026-06-27 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_J', 3, 'Algeria', 'Austria', 71, 'Arrowhead Stadium', 'Kansas City', 'USA'),
  (2026072, 'WC', 2026, '2026-06-27 20:00:00+00', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_J', 3, 'Jordan', 'Argentina', 72, 'AT&T Stadium', 'Arlington (Dallas)', 'USA')
on conflict (football_data_id) do update
set utc_date = excluded.utc_date,
    status = excluded.status,
    stage = excluded.stage,
    group_name = excluded.group_name,
    matchday = excluded.matchday,
    home_team_name = excluded.home_team_name,
    away_team_name = excluded.away_team_name,
    match_number = excluded.match_number,
    stadium = excluded.stadium,
    city = excluded.city,
    country = excluded.country,
    updated_at = now();

select public.refresh_group_standings();
