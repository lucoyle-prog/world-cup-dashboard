#!/usr/bin/env python3
"""GitHub Actions updater for World Cup dashboard (scores + docs build)."""

from __future__ import annotations

import csv
import json
import re
import shutil
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WC_DIR = Path(__file__).resolve().parent
CSV_PATH = ROOT / "FIFA Draw(Draw Results).csv"
PROFILES_PATH = WC_DIR / "country-profiles.json"
HISTORY_PATH = WC_DIR / "world-cup-status-history.json"
DATA_JS_PATH = WC_DIR / "world-cup-data.js"
DOCS_DIR = ROOT / "docs"
HTML_SOURCE = WC_DIR / "World-Cup-Performance-Team-Dashboard.html"
CSS_SOURCE = ROOT / "assets" / "cisco-brand.css"

STANDINGS_URL = "https://site.api.espn.com/apis/v2/sports/soccer/fifa.world/standings"
SCOREBOARD_URL = "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/scoreboard?dates={date}"

COUNTRY_ALIASES = {
    "Congo DR": ["Congo DR", "DR Congo", "Democratic Republic of Congo"],
    "Cote d'Ivoire": ["Ivory Coast", "Cote d'Ivoire", "Côte d'Ivoire"],
    "Korea Republic": ["South Korea", "Korea Republic", "Korea"],
    "Cape Verde Islands": ["Cape Verde", "Cabo Verde"],
    "Turkey": ["Turkiye", "Türkiye", "Turkey"],
    "Czech Republic": ["Czechia", "Czech Republic"],
    "Curacao": ["Curacao", "Curaçao"],
    "Bosnia and Herzegovina": ["Bosnia-Herzegovina", "Bosnia and Herzegovina"],
    "United States": ["United States", "USA"],
    "Scotland": ["Scotland"],
}


def normalize_name(name: str) -> str:
    if not name:
        return ""
    n = name.strip().lower()
    n = re.sub(r"[\u2019'`]", "'", n)
    n = re.sub(r"[^a-z0-9\s-]", "", n)
    n = re.sub(r"\s+", " ", n)
    return n.strip()


def test_country_match(pick_name: str, espn_name: str) -> bool:
    pick_norm = normalize_name(pick_name)
    espn_norm = normalize_name(espn_name)
    if pick_norm == espn_norm:
        return True
    if "ivoire" in pick_norm and "ivory" in espn_norm:
        return True
    if pick_name in COUNTRY_ALIASES:
        for alias in COUNTRY_ALIASES[pick_name]:
            if normalize_name(alias) == espn_norm:
                return True
    for key, aliases in COUNTRY_ALIASES.items():
        if normalize_name(key) == pick_norm:
            for alias in aliases:
                if normalize_name(alias) == espn_norm:
                    return True
    return False


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "world-cup-dashboard/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise RuntimeError(f"ESPN request failed for {url}: {exc}") from exc


def get_stat(entry: dict, stat_name: str) -> int:
    stats = entry.get("stats") or []
    for stat in stats:
        if stat.get("name") == stat_name:
            try:
                return int(float(stat.get("value", 0)))
            except (TypeError, ValueError):
                return 0
    return 0


def resolve_country_status(entry: dict, group_name: str) -> dict:
    note = ""
    if entry.get("note") and entry["note"].get("description"):
        note = entry["note"]["description"]
    gp = get_stat(entry, "gamesPlayed")
    pts = get_stat(entry, "points")
    rank = get_stat(entry, "rank")
    advanced = get_stat(entry, "advanced")
    group_matches = 3

    if advanced > 0:
        return {
            "status": "IN",
            "detail": "Advanced - still in the World Cup",
            "note": note,
            "groupRank": rank,
            "points": pts,
            "played": gp,
        }

    group_stage_complete = gp >= group_matches
    elimination_confirmed = False
    if group_stage_complete:
        if re.search(r"Eliminated", note, re.I):
            elimination_confirmed = True
        if rank >= 4:
            elimination_confirmed = True

    if elimination_confirmed:
        return {
            "status": "OUT",
            "detail": "Eliminated from World Cup",
            "note": note,
            "groupRank": rank,
            "points": pts,
            "played": gp,
        }

    if gp < group_matches:
        progress = (
            f"In World Cup - {group_name}"
            if gp == 0
            else f"In World Cup - {group_name} (group stage in progress)"
        )
        return {
            "status": "IN",
            "detail": progress,
            "note": note,
            "groupRank": rank,
            "points": pts,
            "played": gp,
        }

    if re.search(r"Advance|Best 8", note, re.I):
        race = " - awaiting best third-place result" if re.search(r"Best 8", note, re.I) else ""
        return {
            "status": "IN",
            "detail": f"Still in World Cup{race}",
            "note": note,
            "groupRank": rank,
            "points": pts,
            "played": gp,
        }

    return {
        "status": "IN",
        "detail": f"Still in World Cup - {group_name}",
        "note": note,
        "groupRank": rank,
        "points": pts,
        "played": gp,
    }


def read_team_picks(path: Path) -> list[dict]:
    members = []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        for row in csv.DictReader(handle):
            name = (row.get("Name") or "").strip()
            if not name:
                continue
            if name == "Not Picked":
                raw = [part.strip() for part in (row.get("Country 1") or "").splitlines() if part.strip()]
                note = (row.get("Country 2") or "").strip()
                members.append({"name": "Not Picked (Pool)", "countries": raw, "note": note})
                continue
            countries = [
                (row.get("Country 1") or "").strip(),
                (row.get("Country 2") or "").strip(),
                (row.get("Country 3") or "").strip(),
            ]
            countries = [c for c in countries if c]
            if not countries:
                continue
            members.append({"name": name, "countries": countries, "note": ""})
    return members


def get_country_profile(pick_name: str, profiles: dict) -> dict | None:
    profile_map = profiles.get("profiles", {})
    if pick_name in profile_map:
        return profile_map[pick_name]
    pick_norm = normalize_name(pick_name)
    for key, value in profile_map.items():
        if normalize_name(key) == pick_norm:
            return value
    return None


def build_star_player(pick_name: str, profiles: dict) -> dict:
    profile = get_country_profile(pick_name, profiles)
    fifa_base = profiles.get("fifaBaseUrl", "https://www.fifa.com/en/tournaments/mens/worldcup/canadamexicousa2026/teams")
    if profile:
        fifa_slug = profile.get("fifaSlug") or re.sub(r"[^a-z0-9]+", "-", pick_name.lower()).strip("-")
        star_name = profile.get("starPlayer") or "Squad star TBD"
    else:
        fifa_slug = re.sub(r"[^a-z0-9]+", "-", pick_name.lower()).strip("-")
        star_name = "Squad star TBD"
    return {
        "name": star_name,
        "position": "",
        "headshot": None,
        "espnUrl": None,
        "fifaUrl": f"{fifa_base}/{fifa_slug}",
    }


def build_payload() -> dict:
    if not CSV_PATH.exists():
        raise FileNotFoundError(f"Missing team picks CSV: {CSV_PATH}")
    if not PROFILES_PATH.exists():
        raise FileNotFoundError(f"Missing country profiles: {PROFILES_PATH}")

    team_picks = read_team_picks(CSV_PATH)
    all_picks: list[str] = []
    for member in team_picks:
        for country in member["countries"]:
            if country not in all_picks:
                all_picks.append(country)

    profiles = json.loads(PROFILES_PATH.read_text(encoding="utf-8"))
    print("Fetching live World Cup standings from ESPN...")
    standings = fetch_json(STANDINGS_URL)

    country_lookup: dict[str, dict] = {}
    groups_out = []
    total_matches_played = 0

    for group in standings.get("children") or []:
        group_name = group.get("name", "")
        entries_out = []
        group_entries = ((group.get("standings") or {}).get("entries")) or []
        for entry in group_entries:
            team = entry.get("team") or {}
            if not team:
                continue
            resolved = resolve_country_status(entry, group_name)
            gp = resolved["played"]
            total_matches_played += gp
            record = ""
            for stat in entry.get("stats") or []:
                if stat.get("type") == "total":
                    record = stat.get("displayValue") or ""
                    break
            logos = team.get("logos") or []
            team_info = {
                "name": team.get("displayName"),
                "espnTeamId": team.get("id"),
                "abbreviation": team.get("abbreviation"),
                "logo": logos[0].get("href") if logos else None,
                "group": group_name,
                "status": resolved["status"],
                "detail": resolved["detail"],
                "note": resolved["note"],
                "rank": resolved["groupRank"],
                "points": resolved["points"],
                "played": resolved["played"],
                "record": record,
            }
            country_lookup[team_info["name"]] = team_info
            for pick in all_picks:
                if test_country_match(pick, team_info["name"]):
                    country_lookup[pick] = team_info
            entries_out.append(team_info)
        groups_out.append({"name": group_name, "teams": entries_out})

    countries = []
    unmatched = []
    for pick in all_picks:
        if pick in country_lookup:
            info = country_lookup[pick]
            star = build_star_player(pick, profiles)
            countries.append(
                {
                    "pickName": pick,
                    "displayName": info["name"],
                    "abbreviation": info["abbreviation"],
                    "logo": info["logo"],
                    "group": info["group"],
                    "status": info["status"],
                    "detail": info["detail"],
                    "note": info["note"],
                    "rank": info["rank"],
                    "points": info["points"],
                    "played": info["played"],
                    "record": info["record"],
                    "starPlayer": star,
                    "fifaUrl": star["fifaUrl"],
                }
            )
        else:
            unmatched.append(pick)
            star = build_star_player(pick, profiles)
            countries.append(
                {
                    "pickName": pick,
                    "displayName": pick,
                    "abbreviation": pick[:3].upper(),
                    "logo": None,
                    "group": "-",
                    "status": "PENDING",
                    "detail": "Not found in World Cup draw - may have missed qualification",
                    "note": "",
                    "rank": 0,
                    "points": 0,
                    "played": 0,
                    "record": "-",
                    "starPlayer": star,
                    "fifaUrl": star["fifaUrl"],
                }
            )

    today_matches = []
    today = datetime.now().strftime("%Y%m%d")
    print("Fetching today's matches...")
    try:
        scoreboard = fetch_json(SCOREBOARD_URL.format(date=today))
        for event in scoreboard.get("events") or []:
            competitions = event.get("competitions") or []
            if not competitions:
                continue
            comp = competitions[0]
            competitors = comp.get("competitors") or []
            home = next((c for c in competitors if c.get("homeAway") == "home"), None)
            away = next((c for c in competitors if c.get("homeAway") == "away"), None)
            if not home or not away:
                continue
            home_name = (home.get("team") or {}).get("displayName")
            away_name = (away.get("team") or {}).get("displayName")
            tracked = [
                name
                for name in (home_name, away_name)
                if name and any(test_country_match(pick, name) for pick in all_picks)
            ]
            if not tracked:
                continue
            status = ((comp.get("status") or {}).get("type") or {}).get("description") or ""
            state = ((comp.get("status") or {}).get("type") or {}).get("state") or ""
            home_logos = (home.get("team") or {}).get("logos") or []
            away_logos = (away.get("team") or {}).get("logos") or []
            today_matches.append(
                {
                    "name": event.get("name"),
                    "status": status,
                    "state": state,
                    "home": {
                        "name": home_name,
                        "score": home.get("score"),
                        "logo": home_logos[0].get("href") if home_logos else None,
                    },
                    "away": {
                        "name": away_name,
                        "score": away.get("score"),
                        "logo": away_logos[0].get("href") if away_logos else None,
                    },
                    "tracked": tracked,
                }
            )
    except RuntimeError as exc:
        print(f"Warning: could not load scoreboard: {exc}")

    previous_statuses = {}
    if HISTORY_PATH.exists():
        try:
            hist = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
            for item in hist.get("countries") or []:
                previous_statuses[item.get("pickName")] = item.get("status")
        except json.JSONDecodeError:
            print("Warning: could not read status history.")

    status_changes = []
    for country in countries:
        prev = previous_statuses.get(country["pickName"])
        if prev and prev != country["status"]:
            status_changes.append(
                {
                    "country": country["pickName"],
                    "from": prev,
                    "to": country["status"],
                    "detail": country["detail"],
                }
            )

    members_out = []
    for member in team_picks:
        member_countries = [c for c in countries if c["pickName"] in member["countries"]]
        members_out.append(
            {
                "name": member["name"],
                "note": member["note"],
                "countries": member_countries,
                "inCount": sum(1 for c in member_countries if c["status"] == "IN"),
                "outCount": sum(1 for c in member_countries if c["status"] == "OUT"),
            }
        )

    summary = {
        "total": len(countries),
        "inCount": sum(1 for c in countries if c["status"] == "IN"),
        "outCount": sum(1 for c in countries if c["status"] == "OUT"),
        "pendingCount": sum(1 for c in countries if c["status"] == "PENDING"),
        "members": len(team_picks),
        "matchesPlayedInTournament": int(total_matches_played / 2),
    }

    now = datetime.now().astimezone()
    return {
        "lastUpdated": now.isoformat(timespec="seconds"),
        "lastUpdatedDisplay": now.strftime("%A, %B %d, %Y %I:%M %p").replace(" 0", " "),
        "tournament": "2026 FIFA World Cup",
        "tournamentDates": "June 11 - July 19, 2026",
        "phase": "Tournament in progress" if total_matches_played > 0 else "Group stage - opening day",
        "summary": summary,
        "statusChanges": status_changes,
        "members": members_out,
        "countries": countries,
        "groups": groups_out,
        "todayMatches": today_matches,
        "unmatchedPicks": unmatched,
    }


def write_data_files(payload: dict) -> None:
    json_text = json.dumps(payload, ensure_ascii=False)
    DATA_JS_PATH.write_text(f"window.WC_DASHBOARD_DATA = {json_text};", encoding="utf-8")
    history = {
        "countries": [{"pickName": c["pickName"], "status": c["status"]} for c in payload["countries"]]
    }
    HISTORY_PATH.write_text(json.dumps(history), encoding="utf-8")
    print(
        f"Updated {payload['summary']['total']} countries - "
        f"IN: {payload['summary']['inCount']}, OUT: {payload['summary']['outCount']}, "
        f"PENDING: {payload['summary']['pendingCount']}"
    )


def build_docs() -> None:
    if not HTML_SOURCE.exists():
        raise FileNotFoundError(f"Missing dashboard HTML: {HTML_SOURCE}")
    if not CSS_SOURCE.exists():
        raise FileNotFoundError(f"Missing CSS: {CSS_SOURCE}")
    if not DATA_JS_PATH.exists():
        raise FileNotFoundError(f"Missing data file: {DATA_JS_PATH}")

    docs_assets = DOCS_DIR / "assets"
    docs_assets.mkdir(parents=True, exist_ok=True)

    html = HTML_SOURCE.read_text(encoding="utf-8")
    html = html.replace("../assets/cisco-brand.css", "assets/cisco-brand.css")
    (DOCS_DIR / "index.html").write_text(html, encoding="utf-8")
    shutil.copy2(DATA_JS_PATH, DOCS_DIR / "world-cup-data.js")
    shutil.copy2(CSS_SOURCE, docs_assets / "cisco-brand.css")
    print(f"GitHub Pages files ready in: {DOCS_DIR}")


def main() -> int:
    try:
        print("Reading team picks from CSV...")
        payload = build_payload()
        write_data_files(payload)
        build_docs()
        return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
