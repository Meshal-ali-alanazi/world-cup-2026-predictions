# World Cup 2026 Prediction App

No-email version: use `PUBLIC_NICKNAME_SETUP.md` for the current setup and deployment steps. Older Magic Link notes below are kept only for reference from the first version.

Static single-page app backed by Supabase Postgres, Realtime, and one Supabase Edge Function that fetches FIFA World Cup matches from football-data.org v4.

Current mode: public nickname access. Members open the single public URL, enter a display name, and predict without email. This is easier for phone access, but it is weaker than real authentication because identity is tied to browser storage on that device.

## Files

- `index.html`: public single-page app.
- `supabase/schema.sql`: tables, RLS, leaderboard RPCs, scoring RPC, Realtime publication.
- `supabase/public-nickname-mode.sql`: migration that converts the database from Magic Link users to public nickname users.
- `supabase/functions/fetch-matches/index.ts`: admin-only Edge Function.
- `.env.example`: Edge Function secrets reference.

## Public Nickname Mode Setup

If you already ran `supabase/schema.sql`, run this migration next in Supabase SQL Editor:

```sql
-- paste the full contents of supabase/public-nickname-mode.sql
```

Verification SQL:

```sql
select public.participant_count();
select * from public.leaderboard();

select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('save_guest_prediction', 'leaderboard', 'participant_count')
order by routine_name;
```

Expected:

- `participant_count()` returns `0` before predictions exist.
- `leaderboard()` returns no rows before predictions exist.
- `save_guest_prediction`, `leaderboard`, and `participant_count` all exist.

For the admin refresh button, set an admin PIN secret and deploy the function without JWT verification:

```bash
supabase secrets set ADMIN_PIN='choose-a-private-pin'
supabase functions deploy fetch-matches --no-verify-jwt
```

Only share the PIN with the admin.

## Step 1: Supabase SQL Setup

1. Open Supabase Dashboard > SQL Editor.
2. Paste the complete contents of `supabase/schema.sql`.
3. Click Run.

Verification SQL:

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('matches', 'profiles', 'predictions')
order by table_name;

select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('leaderboard', 'participant_count', 'recalculate_prediction_points')
order by routine_name;

select * from public.leaderboard();
select public.participant_count();
```

Expected result:

- Three tables are returned.
- Three functions are returned.
- `leaderboard()` returns zero rows before predictions exist.
- `participant_count()` returns `0` before predictions exist.

Make your admin user after that user has logged in once:

```sql
update public.profiles
set role = 'admin'
where email = 'you@example.com';
```

## Step 2: Auth Configuration

1. Supabase Dashboard > Authentication > Providers > Email.
2. Keep Email enabled. Magic Link is part of Supabase passwordless email auth.
3. Supabase Dashboard > Authentication > URL Configuration.
4. Set Site URL to your deployed public URL, for example `https://your-domain.vercel.app`.
5. Add every allowed redirect URL:
   - Local test URL, for example `http://localhost:3000`
   - Vercel URL, for example `https://your-domain.vercel.app`
   - GitHub Pages URL, for example `https://your-user.github.io/your-repo/`

Verification:

1. Put your project URL and anon key into `index.html`.
2. Open the page.
3. Enter a real email.
4. Click the Magic Link in the email.
5. Confirm the page shows your email or display name and the Sign out button.

If the link opens but does not log you in, the redirect URL is not allow-listed exactly.

## Step 3: Edge Function `fetch-matches`

Set secrets:

```bash
supabase login
supabase link --project-ref <project-ref>
supabase secrets set FOOTBALL_DATA_API_KEY=<football-data-key>
supabase secrets set SUPABASE_URL=https://<project-ref>.supabase.co
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<service-role-key>
supabase secrets set WORLD_CUP_SEASON=2026
supabase secrets set ADMIN_PIN=<private-admin-pin>
```

Deploy:

```bash
supabase functions deploy fetch-matches --no-verify-jwt
```

Get a user access token after logging into the app. In the browser console:

```js
(await window.supabase.createClient(
  'https://<project-ref>.supabase.co',
  '<anon-key>'
).auth.getSession()).data.session.access_token
```

Test the function:

```bash
curl -i -X POST 'https://<project-ref>.supabase.co/functions/v1/fetch-matches' \
  -H 'apikey: <anon-key>' \
  -H 'x-admin-pin: <private-admin-pin>' \
  -H 'Content-Type: application/json' \
  -d '{"season":2026}'
```

Expected response:

```json
{
  "ok": true,
  "competition": "WC",
  "season": 2026,
  "fetched": 0,
  "upserted": 0
}
```

`fetched` can be `0` until football-data.org exposes the 2026 World Cup schedule for your API tier. Verify DB writes with:

```sql
select count(*), min(utc_date), max(utc_date)
from public.matches
where season_year = 2026;
```

Security verification:

- Calling without `x-admin-pin` should return `401`.
- Calling with the wrong PIN should return `401`.
- Calling with the correct PIN should fetch matches and recalculate points.

## Step 4: HTML Page Development

Configure `index.html`:

```js
const SUPABASE_URL = "https://<project-ref>.supabase.co";
const SUPABASE_ANON_KEY = "<anon-key>";
```

Local static test:

```bash
python3 -m http.server 3000
```

Open `http://localhost:3000`. Add that exact URL to Auth redirect URLs.

Manual test data:

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
) values
  (990001, now() + interval '5 minutes', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 'Test Home', 'THM', 'Test Away', 'TAW'),
  (990002, now() - interval '1 day', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 'Yesterday Home', 'YHM', 'Yesterday Away', 'YAW'),
  (990003, now() + interval '1 day', 'SCHEDULED', 'GROUP_STAGE', 'GROUP_A', 'Tomorrow Home', 'TMH', 'Tomorrow Away', 'TMA')
on conflict (football_data_id) do update
set utc_date = excluded.utc_date,
    status = excluded.status,
    score_home = null,
    score_away = null;
```

Verification scenarios:

1. Open the page, request Magic Link, click the email link, and confirm you are signed in.
2. Confirm only match `990001` appears today. Matches `990002` and `990003` must not appear.
3. Save a prediction for `990001`. Refresh the page and confirm the saved score reloads.
4. Change `990001` to past kickoff and confirm the inputs lock:

```sql
update public.matches
set utc_date = now() - interval '1 minute'
where football_data_id = 990001;
```

5. Open the app in two browsers with two different users. Save a prediction as one user and confirm the other browser's leaderboard updates through Realtime.
6. Test scoring:

```sql
update public.matches
set status = 'FINISHED',
    score_home = 2,
    score_away = 1
where football_data_id = 990001;
```

Then click the admin `Fetch official results` button. It fetches official results and runs the scoring RPC. If you want to isolate scoring without calling football-data.org, run:

```sql
select public.recalculate_prediction_points();
select * from public.leaderboard();
```

## Step 5: Deployment

### Vercel

1. Push these files to GitHub.
2. Import the repository in Vercel.
3. Use the default static project settings. No build command is needed.
4. Deploy.
5. Add the deployed Vercel URL to Supabase Auth redirect URLs.

### GitHub Pages

1. Push these files to GitHub.
2. Repository Settings > Pages.
3. Source: Deploy from a branch.
4. Select the branch and root folder.
5. Add the GitHub Pages URL to Supabase Auth redirect URLs.

Deployment verification checklist:

- Public URL loads `index.html`.
- Magic Link email lands in the inbox.
- Magic Link returns to the same public URL and creates a session.
- Today's Mecca-time matches only are shown.
- Future `SCHEDULED` matches accept predictions.
- Finished, non-scheduled, and already-started matches are locked.
- Leaderboard shows participant count and total points.
- Realtime updates another signed-in browser after a prediction changes.
- Admin-only button refreshes results and recalculates points.

## Step 6: Final Integration Test

1. Deploy SQL, Edge Function, and static site.
2. Log in once with your admin email, then run:

```sql
update public.profiles
set role = 'admin'
where email = 'you@example.com';
```

3. Insert a test match that starts in 5 minutes:

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
  now() + interval '5 minutes',
  'SCHEDULED',
  'GROUP_STAGE',
  'GROUP_B',
  'Integration Home',
  'IHM',
  'Integration Away',
  'IAW'
)
on conflict (football_data_id) do update
set utc_date = excluded.utc_date,
    status = excluded.status,
    score_home = null,
    score_away = null;
```

4. Log in as user A and save `2 - 1`.
5. Log in as user B in another browser and save `1 - 1`.
6. Mark the match finished:

```sql
update public.matches
set status = 'FINISHED',
    score_home = 2,
    score_away = 1
where football_data_id = 991001;
```

7. Click the admin `Fetch official results` button, or run `select public.recalculate_prediction_points();` if you are testing without the football-data API.
8. Confirm:
   - User A receives 2 points.
   - User B receives 0 points.
   - Leaderboard participant count is 2.
   - The second browser updates live.

Troubleshooting:

- `401` from Edge Function: missing or expired user token.
- `403` from Edge Function: user profile is not `admin`.
- Magic Link loops or does not create a session: redirect URL mismatch.
- Realtime does not update: confirm `predictions` is in the `supabase_realtime` publication and the user is signed in.
- Prediction save fails after kickoff: expected; the database RLS policy is enforcing the lock.
- football-data.org returns an error: verify API key, free-tier coverage, rate limit, and whether `WC` season `2026` is available.

## Official References

- football-data.org v4 quickstart and endpoint list: https://www.football-data.org/documentation/quickstart
- football-data.org v4 lookup tables for `WC`, statuses, filters, and `X-Auth-Token`: https://docs.football-data.org/general/v4/lookup_tables.html
- Supabase Magic Link auth: https://supabase.com/docs/guides/auth/auth-email-passwordless
- Supabase Edge Function deployment: https://supabase.com/docs/guides/functions/deploy
- Supabase Edge Function secrets: https://supabase.com/docs/guides/functions/secrets
- Supabase Realtime Postgres changes: https://supabase.com/docs/guides/realtime/postgres-changes
