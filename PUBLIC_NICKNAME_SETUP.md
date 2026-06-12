# Public Nickname Setup

This is the no-email version. Members open one public Vercel URL, enter a display name, and predict from their phones. No Magic Link, no email limits.

Security tradeoff: this is easier, but weaker than real login. A player identity is stored in that browser only.

## 1. Update Supabase

You already ran the base schema. Now run this file in Supabase SQL Editor:

```text
supabase/public-nickname-mode.sql
```

After it succeeds, verify:

```sql
select public.participant_count();

select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('save_guest_prediction', 'leaderboard', 'participant_count')
order by routine_name;
```

Expected:

```text
participant_count = 0
leaderboard
participant_count
save_guest_prediction
```

## 2. Push The Updated App

Run:

```bash
cd /home/project/Desktop/2060
git add .
git commit -m "Switch to public nickname predictions"
git push
```

If GitHub asks for a password, paste your GitHub token again.

Vercel will redeploy automatically after the push.

## 3. Test On Phone

Open:

```text
https://world-cup-2026-predictions-two.vercel.app
```

Expected:

1. It asks for a display name, not an email.
2. After entering a name, future scheduled matches allow score predictions.
3. Leaderboard updates after predictions.

## 4. Add A Test Match

Run in Supabase SQL Editor:

```sql
insert into public.matches (
  football_data_id,
  utc_date,
  status,
  stage,
  group_name,
  home_team_name,
  home_team_tla,
  away_team_name,
  away_team_tla
) values (
  991001,
  now() + interval '10 minutes',
  'SCHEDULED',
  'GROUP_STAGE',
  'GROUP_A',
  'Test Home',
  'THM',
  'Test Away',
  'TAW'
)
on conflict (football_data_id) do update
set utc_date = excluded.utc_date,
    status = excluded.status,
    score_home = null,
    score_away = null;
```

Refresh the app. The test match should appear if it falls within today's Mecca-time window.

## 5. Admin Results Refresh

Set a private admin PIN secret:

```bash
supabase secrets set ADMIN_PIN='choose-a-private-pin'
supabase secrets set FOOTBALL_DATA_API_KEY='<football-data-key>'
supabase secrets set SUPABASE_URL='https://ojoroqmmvbhbqpugbkhy.supabase.co'
supabase secrets set SUPABASE_SERVICE_ROLE_KEY='<service-role-key>'
supabase functions deploy fetch-matches --no-verify-jwt
```

Only the admin should know the PIN. The app will ask for this PIN when clicking **Fetch official results**.
