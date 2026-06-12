import { createClient } from "npm:@supabase/supabase-js@2";

type FootballDataTeam = {
  id?: number | null;
  name?: string | null;
  shortName?: string | null;
  tla?: string | null;
  crest?: string | null;
};

type FootballDataMatch = {
  id: number;
  utcDate: string;
  status?: string | null;
  stage?: string | null;
  group?: string | null;
  matchday?: number | null;
  homeTeam?: FootballDataTeam | null;
  awayTeam?: FootballDataTeam | null;
  score?: {
    duration?: string | null;
    fullTime?: { home?: number | null; away?: number | null } | null;
    regularTime?: { home?: number | null; away?: number | null } | null;
  } | null;
};

type FootballDataResponse = {
  count?: number;
  filters?: Record<string, unknown>;
  resultSet?: Record<string, unknown>;
  matches?: FootballDataMatch[];
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const VALID_STATUSES = new Set([
  "SCHEDULED",
  "TIMED",
  "IN_PLAY",
  "PAUSED",
  "EXTRA_TIME",
  "PENALTY_SHOOTOUT",
  "FINISHED",
  "SUSPENDED",
  "POSTPONED",
  "CANCELLED",
  "AWARDED",
]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed. Use POST." }, 405);
  }

  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const footballDataApiKey = requiredEnv("FOOTBALL_DATA_API_KEY");

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const authHeader = req.headers.get("Authorization") ?? "";
    const accessToken = authHeader.replace(/^Bearer\s+/i, "").trim();

    if (!accessToken) {
      return json({ error: "Missing Authorization bearer token." }, 401);
    }

    const { data: authData, error: authError } = await supabase.auth.getUser(accessToken);
    if (authError || !authData.user) {
      return json({ error: "Invalid or expired session.", detail: authError?.message }, 401);
    }

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("role,email")
      .eq("id", authData.user.id)
      .single();

    if (profileError) {
      return json({ error: "Could not load user profile.", detail: profileError.message }, 500);
    }

    if (profile?.role !== "admin") {
      return json({ error: "Admin role required." }, 403);
    }

    const requestBody = await parseJson(req);
    const season = normalizeSeason(requestBody.season ?? Deno.env.get("WORLD_CUP_SEASON") ?? "2026");
    const dateFrom = normalizeDateFilter(requestBody.dateFrom);
    const dateTo = normalizeDateFilter(requestBody.dateTo);

    const footballUrl = new URL("https://api.football-data.org/v4/competitions/WC/matches");
    footballUrl.searchParams.set("season", String(season));
    if (dateFrom) footballUrl.searchParams.set("dateFrom", dateFrom);
    if (dateTo) footballUrl.searchParams.set("dateTo", dateTo);

    const footballResponse = await fetch(footballUrl, {
      headers: {
        "X-Auth-Token": footballDataApiKey,
      },
    });

    if (!footballResponse.ok) {
      const body = await footballResponse.text();
      return json(
        {
          error: "football-data.org request failed.",
          status: footballResponse.status,
          body: body.slice(0, 1000),
        },
        502,
      );
    }

    const payload = (await footballResponse.json()) as FootballDataResponse;
    const matches = Array.isArray(payload.matches) ? payload.matches : [];
    const rows = matches.map((match) => toMatchRow(match, season));

    if (rows.length > 0) {
      const { error: upsertError } = await supabase
        .from("matches")
        .upsert(rows, { onConflict: "football_data_id" });

      if (upsertError) {
        return json({ error: "Failed to upsert matches.", detail: upsertError.message }, 500);
      }
    }

    const { error: pointsError } = await supabase.rpc("recalculate_prediction_points");
    if (pointsError) {
      return json({ error: "Failed to recalculate prediction points.", detail: pointsError.message }, 500);
    }

    return json({
      ok: true,
      competition: "WC",
      season,
      fetched: matches.length,
      upserted: rows.length,
      filters: payload.filters ?? null,
      resultSet: payload.resultSet ?? null,
      triggeredBy: profile.email ?? authData.user.email ?? authData.user.id,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    return json({ error: message }, 500);
  }
});

function toMatchRow(match: FootballDataMatch, season: number) {
  const fullTime = match.score?.fullTime;
  const regularTime = match.score?.regularTime;
  const scoreHome = toNullableInt(fullTime?.home ?? regularTime?.home);
  const scoreAway = toNullableInt(fullTime?.away ?? regularTime?.away);
  const homeTeam = match.homeTeam ?? {};
  const awayTeam = match.awayTeam ?? {};
  const status = normalizeStatus(match.status);

  return {
    football_data_id: match.id,
    competition_code: "WC",
    season_year: season,
    utc_date: match.utcDate,
    status,
    stage: match.stage ?? null,
    group_name: match.group ?? null,
    matchday: toNullableInt(match.matchday),
    home_team_id: toNullableInt(homeTeam.id),
    home_team_name: teamName(homeTeam),
    home_team_tla: homeTeam.tla ?? null,
    home_team_crest: homeTeam.crest ?? null,
    away_team_id: toNullableInt(awayTeam.id),
    away_team_name: teamName(awayTeam),
    away_team_tla: awayTeam.tla ?? null,
    away_team_crest: awayTeam.crest ?? null,
    score_home: scoreHome,
    score_away: scoreAway,
    score_duration: match.score?.duration ?? null,
    raw: match,
    last_fetched_at: new Date().toISOString(),
  };
}

function teamName(team: FootballDataTeam): string {
  return team.name?.trim() || team.shortName?.trim() || team.tla?.trim() || "TBD";
}

function normalizeStatus(status: string | null | undefined): string {
  if (status && VALID_STATUSES.has(status)) return status;
  return "SCHEDULED";
}

function toNullableInt(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.trunc(value);
}

function normalizeSeason(value: unknown): number {
  const season = typeof value === "number" ? value : Number.parseInt(String(value), 10);
  if (!Number.isInteger(season) || season < 1930 || season > 2100) {
    throw new Error("Invalid season. Use a four-digit year such as 2026.");
  }
  return season;
}

function normalizeDateFilter(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  const text = String(value);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) {
    throw new Error("dateFrom/dateTo must use YYYY-MM-DD format.");
  }
  return text;
}

async function parseJson(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (!text.trim()) return {};
  const parsed = JSON.parse(text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
  return parsed as Record<string, unknown>;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
