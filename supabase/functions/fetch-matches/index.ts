import { createClient } from "npm:@supabase/supabase-js@2";

type FootballDataTeam = {
  id?: number | null;
  name?: string | null;
  shortName?: string | null;
  tla?: string | null;
  crest?: string | null;
};

type FootballDataScore = {
  duration?: string | null;
  winner?: string | null;
  fullTime?: { home?: number | null; away?: number | null } | null;
  regularTime?: { home?: number | null; away?: number | null } | null;
  penalties?: { home?: number | null; away?: number | null } | null;
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
  score?: FootballDataScore | null;
  venue?: string | null;
  area?: { name?: string | null } | null;
  [key: string]: unknown;
};

type FootballDataResponse = {
  count?: number;
  filters?: Record<string, unknown>;
  resultSet?: Record<string, unknown>;
  matches?: FootballDataMatch[];
};

type LocalMatch = {
  football_data_id: number;
  match_number: number | null;
  utc_date: string;
  status: string;
  stage: string | null;
  group_name: string | null;
  matchday: number | null;
  home_team_name: string;
  away_team_name: string;
  stadium?: string | null;
  city?: string | null;
  country?: string | null;
};

type MatchRow = {
  football_data_id: number;
  competition_code: string;
  season_year: number;
  utc_date: string;
  status: string;
  stage: string | null;
  group_name: string | null;
  matchday: number | null;
  home_team_id: number | null;
  home_team_name: string;
  home_team_tla: string | null;
  home_team_crest: string | null;
  away_team_id: number | null;
  away_team_name: string;
  away_team_tla: string | null;
  away_team_crest: string | null;
  score_home: number | null;
  score_away: number | null;
  score_duration: string | null;
  raw: FootballDataMatch;
  last_fetched_at: string;
  match_number: number;
  stadium: string | null;
  city: string | null;
  country: string | null;
  home_penalties: number | null;
  away_penalties: number | null;
  winner: string | null;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-admin-pin, x-cron-secret",
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

const STAGE_ALIASES: Record<string, string> = {
  GROUP_STAGE: "GROUP_STAGE",
  GROUP: "GROUP_STAGE",
  LAST_32: "ROUND_OF_32",
  ROUND_OF_32: "ROUND_OF_32",
  LAST_16: "ROUND_OF_16",
  ROUND_OF_16: "ROUND_OF_16",
  QUARTER_FINALS: "QUARTER_FINAL",
  QUARTER_FINAL: "QUARTER_FINAL",
  SEMI_FINALS: "SEMI_FINAL",
  SEMI_FINAL: "SEMI_FINAL",
  THIRD_PLACE: "THIRD_PLACE",
  PLAY_OFF_FOR_THIRD_PLACE: "THIRD_PLACE",
  FINAL: "FINAL",
};

const FALLBACK_CRON_SECRET = "wc2026-autopilot-cron-2026-rotate-before-public-use";

const FOOTBALL_DATA_2026_MATCH_NUMBER_BY_ID: Record<number, number> = {
  537369: 13,
  537335: 26,
  537372: 39,
  537338: 50,
  537374: 63,
  537408: 70,
  537415: 74,
  537418: 75,
  537423: 76,
  537416: 77,
  537424: 78,
  537425: 79,
  537426: 80,
  537421: 81,
  537422: 82,
  537419: 83,
  537420: 84,
  537429: 85,
  537427: 86,
  537428: 88,
  537376: 89,
  537375: 90,
  537378: 92,
  537379: 93,
  537380: 94,
  537381: 95,
  537382: 96,
};

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
    const adminPin = Deno.env.get("ADMIN_PIN") ?? "";
    const cronSecret = Deno.env.get("CRON_SECRET") ?? FALLBACK_CRON_SECRET;

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const admin = await authorizeAdmin(req, supabase, adminPin, cronSecret);
    if (!admin.ok) return json({ error: admin.error }, admin.status);

    const requestBody = await parseJson(req);
    const season = normalizeSeason(requestBody.season ?? Deno.env.get("WORLD_CUP_SEASON") ?? "2026");
    const dateFrom = normalizeDateFilter(requestBody.dateFrom);
    const dateTo = normalizeDateFilter(requestBody.dateTo);

    const [footballPayload, localMatches] = await Promise.all([
      fetchFootballData(footballDataApiKey, season, dateFrom, dateTo),
      loadLocalMatches(supabase),
    ]);

    const matches = Array.isArray(footballPayload.matches) ? footballPayload.matches : [];
    const localByApiId = new Map(localMatches.map((match) => [Number(match.football_data_id), match]));
    const localByNumber = new Map(
      localMatches
        .filter((match) => Number.isInteger(match.match_number))
        .map((match) => [Number(match.match_number), match]),
    );

    const rowsByMatchNumber = new Map<number, MatchRow>();
    const skipped: Array<{ api_id: number; reason: string; home?: string; away?: string; utcDate?: string }> = [];
    const duplicateMappings: Array<{
      match_number: number;
      kept_api_id: number;
      skipped_api_id: number;
      reason: string;
    }> = [];

    for (const match of matches) {
      const matchNumber = resolveMatchNumber(match, localMatches, localByApiId);
      if (!matchNumber) {
        skipped.push({
          api_id: match.id,
          reason: "Could not map API match to seeded match_number.",
          home: teamName(match.homeTeam ?? {}),
          away: teamName(match.awayTeam ?? {}),
          utcDate: match.utcDate,
        });
        continue;
      }

      const target = localByNumber.get(matchNumber);
      const duplicate = localByApiId.get(Number(match.id));
      if (duplicate && target && duplicate.football_data_id !== target.football_data_id) {
        console.warn("Merging duplicate API row before match_number upsert", {
          apiId: match.id,
          duplicateMatchNumber: duplicate.match_number,
          targetMatchNumber: matchNumber,
        });
        const { error: mergeError } = await supabase.rpc("merge_match_duplicate", {
          p_from_match_id: duplicate.football_data_id,
          p_to_match_id: target.football_data_id,
        });
        if (mergeError) {
          throw new Error(`Failed to merge duplicate API row ${match.id}: ${mergeError.message}`);
        }
      }

      const row = toMatchRow(match, season, matchNumber);
      const existingRow = rowsByMatchNumber.get(matchNumber);
      if (existingRow) {
        const preferredRow = choosePreferredRow(existingRow, row);
        const skippedRow = preferredRow === existingRow ? row : existingRow;
        rowsByMatchNumber.set(matchNumber, preferredRow);
        duplicateMappings.push({
          match_number: matchNumber,
          kept_api_id: preferredRow.football_data_id,
          skipped_api_id: skippedRow.football_data_id,
          reason: "Multiple API rows resolved to the same seeded match_number in one sync batch.",
        });
        continue;
      }

      rowsByMatchNumber.set(matchNumber, row);
    }

    const rows = [...rowsByMatchNumber.values()];

    if (rows.length > 0) {
      const { error: upsertError } = await supabase
        .from("matches")
        .upsert(rows, { onConflict: "match_number" });

      if (upsertError) {
        throw new Error(`Failed to upsert matches by match_number: ${upsertError.message}`);
      }
    }

    const { error: pointsError } = await supabase.rpc("recalculate_prediction_points");
    if (pointsError) {
      throw new Error(`Failed to recalculate prediction points: ${pointsError.message}`);
    }

    const { error: standingsError } = await supabase.rpc("refresh_group_standings");
    if (standingsError) {
      console.warn("refresh_group_standings failed or is not installed", standingsError.message);
    }

    console.log("fetch-matches sync completed", {
      season,
      fetched: matches.length,
      mapped: rows.length,
      skipped: skipped.length,
      triggeredBy: admin.triggeredBy,
    });

    return json({
      ok: true,
      competition: "WC",
      season,
      fetched: matches.length,
      upserted: rows.length,
      skipped,
      duplicateMappings,
      filters: footballPayload.filters ?? null,
      resultSet: footballPayload.resultSet ?? null,
      triggeredBy: admin.triggeredBy,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("fetch-matches failed", { message, error });
    return json({ error: message }, 500);
  }
});

async function fetchFootballData(
  apiKey: string,
  season: number,
  dateFrom: string | null,
  dateTo: string | null,
): Promise<FootballDataResponse> {
  const footballUrl = new URL("https://api.football-data.org/v4/competitions/WC/matches");
  footballUrl.searchParams.set("season", String(season));
  if (dateFrom) footballUrl.searchParams.set("dateFrom", dateFrom);
  if (dateTo) footballUrl.searchParams.set("dateTo", dateTo);

  const footballResponse = await fetch(footballUrl, {
    headers: { "X-Auth-Token": apiKey },
  });

  if (!footballResponse.ok) {
    const body = await footballResponse.text();
    throw new Error(`football-data.org request failed (${footballResponse.status}): ${body.slice(0, 1000)}`);
  }

  return await footballResponse.json() as FootballDataResponse;
}

async function loadLocalMatches(supabase: ReturnType<typeof createClient>): Promise<LocalMatch[]> {
  const { data, error } = await supabase
    .from("matches")
    .select("football_data_id,match_number,utc_date,status,stage,group_name,matchday,home_team_name,away_team_name,stadium,city,country")
    .not("match_number", "is", null)
    .order("match_number", { ascending: true });

  if (error) {
    throw new Error(`Failed to load local seeded matches: ${error.message}`);
  }

  return (data ?? []) as LocalMatch[];
}

function toMatchRow(match: FootballDataMatch, season: number, matchNumber: number): MatchRow {
  const fullTime = match.score?.fullTime;
  const regularTime = match.score?.regularTime;
  const penalties = match.score?.penalties;
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
    stage: normalizeStage(match.stage),
    group_name: normalizeGroup(match.group),
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
    match_number: matchNumber,
    stadium: extractVenue(match),
    city: extractCity(match),
    country: extractCountry(match),
    home_penalties: toNullableInt(penalties?.home),
    away_penalties: toNullableInt(penalties?.away),
    winner: normalizeWinner(match),
  };
}

function resolveMatchNumber(
  match: FootballDataMatch,
  localMatches: LocalMatch[],
  localByApiId: Map<number, LocalMatch>,
): number | null {
  const knownFootballDataMatchNumber = FOOTBALL_DATA_2026_MATCH_NUMBER_BY_ID[Number(match.id)];
  if (knownFootballDataMatchNumber) return knownFootballDataMatchNumber;

  const rawNumber = extractRawMatchNumber(match);
  if (rawNumber) return rawNumber;

  const existing = localByApiId.get(Number(match.id));
  if (existing?.match_number) return existing.match_number;

  const stage = normalizeStage(match.stage);
  const group = normalizeGroup(match.group);
  const matchday = toNullableInt(match.matchday);
  const home = normalizeTeam(teamName(match.homeTeam ?? {}));
  const away = normalizeTeam(teamName(match.awayTeam ?? {}));
  const kickoff = new Date(match.utcDate).getTime();
  const venue = normalizeText(extractVenue(match));

  const exactTeamCandidates = localMatches.filter((candidate) => {
    const candidateHome = normalizeTeam(candidate.home_team_name);
    const candidateAway = normalizeTeam(candidate.away_team_name);
    return (
      normalizeStage(candidate.stage) === stage &&
      (!group || normalizeGroup(candidate.group_name) === group) &&
      (!matchday || candidate.matchday === matchday) &&
      candidateHome === home &&
      candidateAway === away
    );
  });
  if (exactTeamCandidates.length === 1 && exactTeamCandidates[0].match_number) {
    return exactTeamCandidates[0].match_number;
  }

  const exactKickoffCandidates = localMatches.filter((candidate) => {
    const localKickoff = new Date(candidate.utc_date).getTime();
    return normalizeStage(candidate.stage) === stage && localKickoff === kickoff;
  });
  if (exactKickoffCandidates.length === 1 && exactKickoffCandidates[0].match_number) {
    return exactKickoffCandidates[0].match_number;
  }

  const kickoffCandidates = localMatches.filter((candidate) => {
    const localKickoff = new Date(candidate.utc_date).getTime();
    const sameStage = normalizeStage(candidate.stage) === stage;
    const nearKickoff = Math.abs(localKickoff - kickoff) <= 6 * 60 * 60 * 1000;
    const sameVenue = venue && normalizeText(candidate.stadium) === venue;
    const sameGroup = group && normalizeGroup(candidate.group_name) === group;
    return sameStage && nearKickoff && (sameVenue || sameGroup || stage !== "GROUP_STAGE");
  });
  if (kickoffCandidates.length === 1 && kickoffCandidates[0].match_number) {
    return kickoffCandidates[0].match_number;
  }

  const sameDayCandidates = localMatches.filter((candidate) => {
    const candidateDate = candidate.utc_date.slice(0, 10);
    const apiDate = match.utcDate.slice(0, 10);
    return (
      candidateDate === apiDate &&
      normalizeStage(candidate.stage) === stage &&
      (!group || normalizeGroup(candidate.group_name) === group) &&
      (!matchday || candidate.matchday === matchday)
    );
  });
  if (sameDayCandidates.length === 1 && sameDayCandidates[0].match_number) {
    return sameDayCandidates[0].match_number;
  }

  return null;
}

function choosePreferredRow(left: MatchRow, right: MatchRow): MatchRow {
  const leftScore = rowConfidence(left);
  const rightScore = rowConfidence(right);
  if (rightScore > leftScore) return right;
  return left;
}

function rowConfidence(row: MatchRow): number {
  let score = 0;
  if (row.home_team_name !== "TBD") score += 2;
  if (row.away_team_name !== "TBD") score += 2;
  if (row.status === "FINISHED") score += 3;
  if (row.status === "IN_PLAY" || row.status === "PAUSED" || row.status === "EXTRA_TIME" || row.status === "PENALTY_SHOOTOUT") score += 2;
  if (row.score_home !== null || row.score_away !== null) score += 2;
  if (FOOTBALL_DATA_2026_MATCH_NUMBER_BY_ID[row.football_data_id] === row.match_number) score += 5;
  return score;
}

function extractRawMatchNumber(match: FootballDataMatch): number | null {
  const candidateKeys = ["matchNumber", "match_number", "number", "matchNo", "match_no", "gameNumber", "game_number"];
  for (const key of candidateKeys) {
    const value = match[key];
    const parsed = typeof value === "number" ? value : Number.parseInt(String(value ?? ""), 10);
    if (Number.isInteger(parsed) && parsed >= 1 && parsed <= 104) return parsed;
  }

  const nestedCandidates = [
    (match.fixture as Record<string, unknown> | undefined)?.number,
    (match.match as Record<string, unknown> | undefined)?.number,
  ];
  for (const value of nestedCandidates) {
    const parsed = typeof value === "number" ? value : Number.parseInt(String(value ?? ""), 10);
    if (Number.isInteger(parsed) && parsed >= 1 && parsed <= 104) return parsed;
  }

  return null;
}

async function authorizeAdmin(
  req: Request,
  supabase: ReturnType<typeof createClient>,
  adminPin: string,
  cronSecret: string,
): Promise<{ ok: true; triggeredBy: string } | { ok: false; status: number; error: string }> {
  const requestCronSecret = req.headers.get("x-cron-secret") ?? "";
  if (cronSecret && requestCronSecret && timingSafeEqual(requestCronSecret, cronSecret)) {
    return { ok: true, triggeredBy: "pg-cron" };
  }

  const requestPin = req.headers.get("x-admin-pin") ?? "";
  if (adminPin && requestPin && timingSafeEqual(requestPin, adminPin)) {
    return { ok: true, triggeredBy: "admin-pin" };
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const accessToken = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!accessToken) {
    return { ok: false, status: 401, error: "Missing cron secret, admin PIN, or Authorization bearer token." };
  }

  const { data: authData, error: authError } = await supabase.auth.getUser(accessToken);
  if (authError || !authData.user) {
    return { ok: false, status: 401, error: "Invalid or expired session." };
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("role,email")
    .eq("id", authData.user.id)
    .single();

  if (profileError) {
    return { ok: false, status: 500, error: "Could not load user profile." };
  }

  if (profile?.role !== "admin") {
    return { ok: false, status: 403, error: "Admin role required." };
  }

  return { ok: true, triggeredBy: profile.email ?? authData.user.email ?? authData.user.id };
}

function timingSafeEqual(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  if (leftBytes.length !== rightBytes.length) return false;

  let diff = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    diff |= leftBytes[index] ^ rightBytes[index];
  }
  return diff === 0;
}

function normalizeStatus(status: string | null | undefined): string {
  if (status === "TIMED") return "SCHEDULED";
  if (status && VALID_STATUSES.has(status)) return status;
  return "SCHEDULED";
}

function normalizeStage(stage: string | null | undefined): string | null {
  if (!stage) return null;
  const key = String(stage).toUpperCase().replace(/[^A-Z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  return STAGE_ALIASES[key] ?? key;
}

function normalizeGroup(group: string | null | undefined): string | null {
  if (!group) return null;
  const text = String(group).toUpperCase();
  const letter = text.match(/GROUP[_\s-]?([A-L])/)?.[1] ?? text.match(/\b([A-L])\b/)?.[1];
  return letter ? `GROUP_${letter}` : text;
}

function normalizeWinner(match: FootballDataMatch): string | null {
  const winner = match.score?.winner;
  if (winner === "HOME_TEAM") return teamName(match.homeTeam ?? {});
  if (winner === "AWAY_TEAM") return teamName(match.awayTeam ?? {});
  if (winner === "DRAW") return "DRAW";
  return null;
}

function teamName(team: FootballDataTeam): string {
  return team.name?.trim() || team.shortName?.trim() || team.tla?.trim() || "TBD";
}

function normalizeTeam(name: string): string {
  const text = normalizeText(name);
  const aliases: Record<string, string> = {
    "bosnia and herzegovina": "bosnia herzegovina",
    "bosnia herzegovina": "bosnia herzegovina",
    "cape verde": "cape verde",
    "cape verde islands": "cape verde",
    "cabo verde": "cape verde",
    "congo dr": "dr congo",
    "democratic republic of congo": "dr congo",
    "dr congo": "dr congo",
    "cote d ivoire": "ivory coast",
    "cote divoire": "ivory coast",
    "ir iran": "iran",
    "korea republic": "south korea",
    "south korea": "south korea",
    "turkey": "turkiye",
    "turkiye": "turkiye",
    "usa": "united states",
    "united states": "united states",
  };
  return aliases[text] ?? text;
}

function normalizeText(value: string | null | undefined): string {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function extractVenue(match: FootballDataMatch): string | null {
  const raw = match["raw"] as Record<string, unknown> | undefined;
  const value = match.venue ?? raw?.venue;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function extractCity(match: FootballDataMatch): string | null {
  const city = (match as Record<string, unknown>).city;
  if (typeof city === "string" && city.trim()) return city.trim();
  return null;
}

function extractCountry(match: FootballDataMatch): string | null {
  const area = match.area?.name;
  return typeof area === "string" && area.trim() ? area.trim() : null;
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
  if (!value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
