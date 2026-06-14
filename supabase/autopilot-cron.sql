-- One-time Supabase automation setup for the World Cup 2026 autopilot sync.
--
-- What this does:
-- 1. Enforces match_number uniqueness so sync cannot duplicate seeded matches.
-- 2. Rebuilds predictions.match_id FK with ON UPDATE CASCADE, allowing the
--    sync to replace seed football_data_id values with football-data.org IDs.
-- 3. Adds a safe duplicate-merge helper for old API-created duplicate rows.
-- 4. Installs pg_cron + pg_net and schedules fetch-matches every 15 minutes.

begin;

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

alter table public.matches
  add column if not exists match_number integer,
  add column if not exists stadium text,
  add column if not exists city text,
  add column if not exists country text,
  add column if not exists home_penalties integer,
  add column if not exists away_penalties integer,
  add column if not exists winner text;

do $$
begin
  if exists (
    select 1
    from public.matches
    where match_number is not null
    group by match_number
    having count(*) > 1
  ) then
    raise exception 'Duplicate match_number values exist. Resolve them before enabling autopilot sync.';
  end if;
end;
$$;

drop index if exists public.matches_match_number_unique_idx;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_match_number_key'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_match_number_key unique (match_number);
  end if;
end;
$$;

do $$
declare
  fk_name text;
begin
  select conname
  into fk_name
  from pg_constraint
  where conrelid = 'public.predictions'::regclass
    and confrelid = 'public.matches'::regclass
    and contype = 'f'
    and exists (
      select 1
      from unnest(conkey) with ordinality cols(attnum, ord)
      join pg_attribute a on a.attrelid = conrelid and a.attnum = cols.attnum
      where a.attname = 'match_id'
    )
  limit 1;

  if fk_name is not null then
    execute format('alter table public.predictions drop constraint %I', fk_name);
  end if;

  alter table public.predictions
    add constraint predictions_match_id_fkey
    foreign key (match_id)
    references public.matches (football_data_id)
    on update cascade
    on delete cascade;
end;
$$;

create or replace function public.merge_match_duplicate(
  p_from_match_id bigint,
  p_to_match_id bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_from_match_id is null or p_to_match_id is null then
    raise exception 'Both source and target match ids are required.';
  end if;

  if p_from_match_id = p_to_match_id then
    return;
  end if;

  if not exists (select 1 from public.matches where football_data_id = p_to_match_id) then
    raise exception 'Target match % does not exist.', p_to_match_id;
  end if;

  update public.predictions p
  set match_id = p_to_match_id,
      updated_at = now()
  where p.match_id = p_from_match_id
    and not exists (
      select 1
      from public.predictions existing
      where existing.match_id = p_to_match_id
        and (
          (existing.guest_id is not null and existing.guest_id = p.guest_id)
          or
          (existing.user_id is not null and existing.user_id = p.user_id)
        )
    );

  delete from public.predictions p
  where p.match_id = p_from_match_id;

  delete from public.matches
  where football_data_id = p_from_match_id;
end;
$$;

revoke all on function public.merge_match_duplicate(bigint, bigint) from public, anon, authenticated;
grant execute on function public.merge_match_duplicate(bigint, bigint) to service_role;

grant usage on schema public to service_role;
grant select, insert, update, delete on table public.matches to service_role;
grant select, insert, update, delete on table public.predictions to service_role;
grant usage, select, update on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

do $$
begin
  if to_regclass('public.group_standings') is not null then
    execute 'grant select, insert, update, delete on table public.group_standings to service_role';
  end if;
end;
$$;

-- A literal cron secret is used so the SQL and Edge Function are deployable as-is.
-- For a private production repository, rotate this by setting CRON_SECRET to a
-- new value in Supabase Edge Function secrets and updating this header.
select cron.unschedule('wc2026-fetch-matches-every-15-minutes')
where exists (
  select 1
  from cron.job
  where jobname = 'wc2026-fetch-matches-every-15-minutes'
);

select cron.schedule(
  'wc2026-fetch-matches-every-15-minutes',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://ojoroqmmvbhbqpugbkhy.supabase.co/functions/v1/fetch-matches',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', 'wc2026-autopilot-cron-2026-rotate-before-public-use'
    ),
    body := jsonb_build_object('season', 2026),
    timeout_milliseconds := 30000
  );
  $$
);

commit;

select jobid, jobname, schedule, active
from cron.job
where jobname = 'wc2026-fetch-matches-every-15-minutes';
