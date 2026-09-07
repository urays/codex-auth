#!/usr/bin/env bash
set -euo pipefail

# codex-auth.sh — manage multiple Codex CLI accounts from a single auth pool.
#
# Primary reference: show-codex-usage/show_codex_usage.sh
#
# Design:
#   - ALL credentials live in ONE pool file: ~/.codex/auth-poll.json (JSON array)
#   - Every run FIRST auto-upserts the current ~/.codex/auth.json into the
#     pool (when it exists), keyed by auth identity
#     (chatgpt account_id / api key) — no explicit save command.
#   - `codex-auth` (no arguments) prints the account list with live usage
#     windows fetched from ChatGPT's usage API and cached subscription dates.
#   - `codex-auth switch` shows the same list followed by an email-based
#     account picker (↑/↓ move, Enter confirm, q quit) that writes the
#     selected credential back to ~/.codex/auth.json.
#   - `codex-auth login` prepares a NEW account login: the live credential is
#     backed up into the pool first, auth.json is removed so the device-auth
#     flow starts clean (otherwise the browser just re-authorizes the account
#     it is already signed into), then the real `codex login` runs and the
#     resulting credential is captured back into the pool automatically. A
#     live credential whose mode the pool cannot store is never deleted.
#   - Sessions and history are never touched. config.toml may be updated only
#     to enforce cli_auth_credentials_store = "file"; account state changes
#     are confined to auth.json and auth-poll.json.

CURRENT_AUTH_FILE="${CURRENT_AUTH_FILE:-$HOME/.codex/auth.json}"
POOL_FILE="${AUTH_POOL_FILE:-$HOME/.codex/auth-poll.json}"
CONFIG_TOML="${CONFIG_TOML:-$HOME/.codex/config.toml}"

MODE="list"

if [[ $# -ge 1 ]]; then
  case "$1" in
    login)
      MODE="login"
      shift
      ;;
    switch)
      MODE="switch"
      shift
      ;;
  esac
fi

if [[ $# -ge 1 ]]; then
  # An optional positional argument is a custom pool file path. Accept it only
  # when it looks like a path; otherwise report an unknown command.
  if [[ "$1" == *.json || "$1" == */* ]]; then
    POOL_FILE="$1"
  else
    echo "Error: unknown command: $1 (supported: login, switch, or run without arguments)" >&2
    exit 1
  fi
fi

USAGE_URL="https://chatgpt.com/backend-api/wham/usage"
RESET_CREDITS_URL="https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
ORANGE='\033[38;5;208m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
REVERSE='\033[7m'

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not installed." >&2
  exit 1
fi

cleanup() {
  # ``if`` guards keep the failing tests from tripping ``set -e`` inside the
  # EXIT trap, which would otherwise override the script's real exit status.
  if [[ -n "${TMP_UPSERT_FILE:-}" && -f "${TMP_UPSERT_FILE:-}" ]]; then
    rm -f "$TMP_UPSERT_FILE"
  fi
  if [[ -n "${RESULTS_FILE:-}" && -f "${RESULTS_FILE:-}" ]]; then
    rm -f "$RESULTS_FILE"
  fi
}
trap cleanup EXIT

# ------------- auth pool helpers -------------
get_auth_mode() {
  jq -r '.auth_mode // "apikey"' <<<"$1"
}

get_auth_identity() {
  local raw="$1" mode
  mode="$(get_auth_mode "$raw")"
  case "$mode" in
    chatgpt) jq -r '.tokens.account_id // empty' <<<"$raw" ;;
    apikey)  jq -r '.OPENAI_API_KEY // empty' <<<"$raw" ;;
    *)       echo "" ;;
  esac
}

get_auth_label() {
  local raw="$1" mode key
  mode="$(get_auth_mode "$raw")"
  case "$mode" in
    chatgpt)
      jq -r '.tokens.account_id // "unknown-account"' <<<"$raw"
      ;;
    apikey)
      key="$(jq -r '.OPENAI_API_KEY // ""' <<<"$raw")"
      if [[ -z "$key" ]]; then
        echo "unknown-apikey"
      else
        printf "apikey:%s...%s" "${key:0:8}" "${key: -4}"
      fi
      ;;
    *) echo "unknown-auth" ;;
  esac
}

is_current_auth() {
  local raw="$1" id
  id="$(get_auth_identity "$raw")"
  [[ -n "$id" && "$id" == "$CURRENT_AUTH_IDENTITY" ]]
}

validate_current_auth_file() {
  if ! jq -e '
    type == "object"
    and (
      (
        (.auth_mode // "chatgpt") == "chatgpt"
        and .tokens
        and .tokens.account_id
        and (.tokens.account_id | type == "string")
        and (.tokens.account_id | length > 0)
        # A partial state (e.g. an aborted codex login) may keep the
        # account_id while tokens are empty or revoked — require both
        # tokens so a broken credential never overwrites a good pool entry.
        and .tokens.access_token
        and (.tokens.access_token | type == "string")
        and (.tokens.access_token | length > 0)
        and .tokens.refresh_token
        and (.tokens.refresh_token | type == "string")
        and (.tokens.refresh_token | length > 0)
      )
      or
      (
        (.auth_mode // "chatgpt") == "apikey"
        and .OPENAI_API_KEY
        and (.OPENAI_API_KEY | type == "string")
        and (.OPENAI_API_KEY | length > 0)
      )
    )
  ' "$CURRENT_AUTH_FILE" > /dev/null; then
    echo "Error: current auth file is not a valid chatgpt/apikey auth.json: $CURRENT_AUTH_FILE" >&2
    exit 1
  fi
}

ensure_pool_file() {
  if [[ ! -f "$POOL_FILE" ]]; then
    echo '[]' > "$POOL_FILE"
  fi
  chmod 600 "$POOL_FILE"
  if ! jq -e 'type == "array"' "$POOL_FILE" > /dev/null; then
    echo "Error: auth pool file is not a JSON array: $POOL_FILE" >&2
    exit 1
  fi
}

upsert_current_auth_if_present() {
  # If a live credential file exists, add/refresh its entry in the pool
  # (keyed by identity). When no auth.json exists (not logged in), do
  # nothing — list/switch still work so a pooled credential can be restored.
  [[ -f "$CURRENT_AUTH_FILE" ]] || return 0

  # Only chatgpt and apikey modes are pooled. Other modes (PAT, headers,
  # agentIdentity, bedrockApiKey, ...) are warned about and skipped: they
  # never reach the pool, so login refuses to delete them.
  local live_mode
  live_mode="$(get_auth_mode "$(cat "$CURRENT_AUTH_FILE")")"
  if [[ "$live_mode" != "chatgpt" && "$live_mode" != "apikey" ]]; then
    printf "${YELLOW}[auth] unsupported auth_mode '%s' — skipped pool upsert${RESET}\n" "$live_mode"
    return 0
  fi

  validate_current_auth_file
  ensure_pool_file

  TMP_UPSERT_FILE="$(mktemp)"

  jq --slurpfile new_auth "$CURRENT_AUTH_FILE" '
    def auth_identity($a):
      if (($a.auth_mode // "apikey")) == "chatgpt" then
        ($a.tokens.account_id // "")
      elif (($a.auth_mode // "apikey")) == "apikey" then
        ($a.OPENAI_API_KEY // "")
      else
        ""
      end;

    . as $pool
    | $new_auth[0] as $new
    | auth_identity($new) as $new_id
    | if ($new_id | length) == 0 then
        .
      elif any($pool[]?; auth_identity(.) == $new_id) then
        map(
          if auth_identity(.) == $new_id
          then $new
          else .
          end
        )
      else
        . + [$new]
      end
  ' "$POOL_FILE" > "$TMP_UPSERT_FILE"

  mv "$TMP_UPSERT_FILE" "$POOL_FILE"
  chmod 600 "$POOL_FILE"
  unset TMP_UPSERT_FILE
}

# ------------- formatting helpers -------------
# Render every absolute timestamp in a fixed UTC+8 timezone, independent of
# the host's local timezone (so neither UTC nor CST leaks into the output).
UTC_PLUS_8_OFFSET_SECONDS=$((8 * 60 * 60))
UTC_PLUS_8_LABEL="UTC+8"

is_number() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

format_abs_time() {
  local epoch="$1" shifted_epoch
  shifted_epoch=$(( epoch + UTC_PLUS_8_OFFSET_SECONDS ))

  # BSD/macOS date.
  if date -u -r "$shifted_epoch" "+%Y-%m-%d %H:%M ${UTC_PLUS_8_LABEL}" >/dev/null 2>&1; then
    date -u -r "$shifted_epoch" "+%Y-%m-%d %H:%M ${UTC_PLUS_8_LABEL}"
    return 0
  fi

  # GNU date.
  if date -u -d "@$shifted_epoch" "+%Y-%m-%d %H:%M ${UTC_PLUS_8_LABEL}" >/dev/null 2>&1; then
    date -u -d "@$shifted_epoch" "+%Y-%m-%d %H:%M ${UTC_PLUS_8_LABEL}"
    return 0
  fi

  echo "$epoch"
}

format_rfc3339_time() {
  local timestamp="${1:-}" formatted
  if [[ -z "$timestamp" || "$timestamp" == "null" ]] \
    || ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  if ! formatted="$(python3 - "$timestamp" 2>/dev/null <<'PYEOF'
import datetime
import sys

timestamp = sys.argv[1]
if timestamp.endswith("Z"):
    timestamp = timestamp[:-1] + "+00:00"

parsed = datetime.datetime.fromisoformat(timestamp)
if parsed.tzinfo is None:
    # RFC3339 normally carries an offset. Treat an offset-less value as UTC so
    # the result is still deterministic instead of inheriting the host zone.
    parsed = parsed.replace(tzinfo=datetime.timezone.utc)

utc_plus_8 = datetime.timezone(datetime.timedelta(hours=8))
print(parsed.astimezone(utc_plus_8).strftime("%Y-%m-%d %H:%M:%S") + " UTC+8")
PYEOF
)"; then
    return 1
  fi
  [[ -n "$formatted" ]] || return 1
  echo "$formatted"
}

format_relative_time() {
  local epoch="$1" now diff sign days hours mins
  now="$(date +%s)"
  diff=$(( epoch - now ))
  sign=""
  if (( diff < 0 )); then
    diff=$(( -diff ))
    sign="-"
  fi
  days=$(( diff / 86400 ))
  hours=$(( (diff % 86400) / 3600 ))
  mins=$(( (diff % 3600) / 60 ))
  if (( days > 0 )); then
    echo "${sign}${days}d ${hours}hr"
  elif (( hours > 0 )); then
    echo "${sign}${hours}hr ${mins}m"
  else
    echo "${sign}${mins}m"
  fi
}

format_reset_after() {
  # Relative countdown comes from the server-provided reset_after_seconds;
  # absolute time from reset_at. Falls back to computing the countdown from
  # reset_at when reset_after_seconds is missing.
  local after="${1:-}" at="${2:-}" abs rel
  abs="-"
  if [[ -n "$at" && "$at" != "null" ]] && is_number "$at"; then
    abs="$(format_abs_time "$at")"
  fi
  rel="-"
  if [[ -n "$after" && "$after" != "null" ]] && is_number "$after"; then
    rel="$(format_relative_time $(( $(date +%s) + after )))"
  elif [[ -n "$at" && "$at" != "null" ]] && is_number "$at"; then
    rel="$(format_relative_time "$at")"
  fi
  echo "${rel} (${abs})"
}

colorize_remaining() {
  local val="${1:-}"
  if [[ -z "$val" || "$val" == "-" ]]; then
    printf "%s" "$val"
    return
  fi
  if ! [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf "%s" "$val"
    return
  fi
  awk -v v="$val" -v red="$RED" -v yellow="$YELLOW" -v green="$GREEN" -v reset="$RESET" '
    BEGIN {
      if (v <= 10)      printf "%s%s%%%s", red, v, reset;
      else if (v <= 25) printf "%s%s%%%s", yellow, v, reset;
      else              printf "%s%s%%%s", green, v, reset;
    }
  '
}

http_error_text() {
  local code="${1:-}"
  case "$code" in
    401) echo "HTTP 401 Unauthorized" ;;
    403) echo "HTTP 403 Forbidden" ;;
    404) echo "HTTP 404 Not Found" ;;
    429) echo "HTTP 429 Too Many Requests" ;;
    500) echo "HTTP 500 Internal Server Error" ;;
    502) echo "HTTP 502 Bad Gateway" ;;
    503) echo "HTTP 503 Service Unavailable" ;;
    *) echo "HTTP $code" ;;
  esac
}

decode_id_token() {
  # Decode display metadata once per account. Subscription claims are present
  # in stored tokens but are not modeled by Codex v0.153.4; they are cached
  # observations, not a live billing query. JWT exp is not a subscription date.
  local raw="$1" jwt
  jwt="$(jq -r '.tokens.id_token // empty' <<<"$raw")"
  [[ -z "$jwt" || "$jwt" == "null" ]] && return 1
  python3 - "$jwt" <<'PYEOF'
import base64
import json
import sys

jwt = sys.argv[1]
try:
    payload = jwt.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    auth = claims.get("https://api.openai.com/auth")
    if not isinstance(auth, dict):
        auth = {}
    metadata = {
        "email": claims.get("email"),
        "subscription_active_until": auth.get("chatgpt_subscription_active_until"),
    }
    print(json.dumps({k: v if isinstance(v, str) else None for k, v in metadata.items()}))
except (AttributeError, IndexError, TypeError, ValueError):
    print("{}")
PYEOF
}

# ------------- usage query -------------
fetch_usage_for_account() {
  local raw_account="$1" token_email="$2"
  local auth_mode identity display_name is_current
  local access_token account_id email plan_type limit_reached
  local response_body http_code tmp_body
  local reset_count reset_details reset_response reset_response_body reset_http_code

  auth_mode="$(get_auth_mode "$raw_account")"
  identity="$(get_auth_identity "$raw_account")"
  display_name="$(get_auth_label "$raw_account")"
  is_current="false"
  is_current_auth "$raw_account" && is_current="true"

  if [[ "$auth_mode" == "apikey" ]]; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$display_name" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "apikey",
        limit_reached: "n/a",
        windows: [],
        credits_text: null,
        sort_key: 9998,
        query_error: "usage check skipped for apikey auth",
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  access_token="$(jq -r '.tokens.access_token // empty' <<<"$raw_account")"
  account_id="$(jq -r '.tokens.account_id // "unknown-account"' <<<"$raw_account")"

  if [[ -z "$access_token" ]]; then
    local fallback_email
    fallback_email="${token_email:-$account_id}"
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg email "$fallback_email" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $email,
        plan_type: "unknown",
        limit_reached: "error",
        windows: [],
        credits_text: null,
        sort_key: 9999,
        query_error: "missing access_token",
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  tmp_body="$(mktemp)"
  http_code="$(
    curl -sS \
      -o "$tmp_body" \
      -w '%{http_code}' \
      "$USAGE_URL" \
      -H 'accept: */*' \
      -H 'accept-language: en-GB,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,en-US;q=0.6,ja;q=0.5' \
      -H "authorization: Bearer $access_token" \
      -H 'priority: u=1, i' \
      -H 'referer: https://chatgpt.com/codex/settings/usage' \
      -H 'sec-ch-ua: "Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"' \
      -H 'sec-ch-ua-arch: "arm"' \
      -H 'sec-ch-ua-bitness: "64"' \
      -H 'sec-ch-ua-full-version: "146.0.7680.80"' \
      -H 'sec-ch-ua-full-version-list: "Chromium";v="146.0.7680.80", "Not-A.Brand";v="24.0.0.0", "Google Chrome";v="146.0.7680.80"' \
      -H 'sec-ch-ua-mobile: ?0' \
      -H 'sec-ch-ua-model: ""' \
      -H 'sec-ch-ua-platform: "macOS"' \
      -H 'sec-ch-ua-platform-version: "26.3.1"' \
      -H 'sec-fetch-dest: empty' \
      -H 'sec-fetch-mode: cors' \
      -H 'sec-fetch-site: same-origin' \
      -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
      -H 'x-openai-target-path: /backend-api/wham/usage' \
      || echo "000"
  )"
  response_body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body"

  if [[ "$http_code" != "200" ]]; then
    local fallback_email
    fallback_email="${token_email:-$account_id}"
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg email "$fallback_email" \
      --arg query_error "$(http_error_text "$http_code")" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $email,
        plan_type: "unknown",
        limit_reached: "error",
        windows: [],
        credits_text: null,
        sort_key: 9999,
        query_error: $query_error,
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  if [[ -z "$response_body" ]] || ! jq -e . >/dev/null 2>&1 <<<"$response_body"; then
    local fallback_email
    fallback_email="${token_email:-$account_id}"
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg email "$fallback_email" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $email,
        plan_type: "unknown",
        limit_reached: "error",
        windows: [],
        credits_text: null,
        sort_key: 9999,
        query_error: "invalid response body",
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  # /wham/usage exposes only the aggregate count. Codex fetches the detailed
  # expiry timestamps from this separate endpoint. Keep it
  # best-effort so a detail failure never hides otherwise valid usage data.
  reset_details='[]'
  reset_count="$(jq -r '.rate_limit_reset_credits.available_count // 0' <<<"$response_body")"
  if ! is_number "$reset_count"; then
    reset_count=0
  fi
  if is_number "$reset_count" && (( reset_count > 0 )); then
    reset_response="$(
      curl -sS \
        --connect-timeout 3 \
        --max-time 5 \
        -w $'\n%{http_code}' \
        "$RESET_CREDITS_URL" \
        -H 'accept: */*' \
        -H "authorization: Bearer $access_token" \
        -H 'referer: https://chatgpt.com/codex/settings/usage' \
        -H 'x-openai-target-path: /backend-api/wham/rate-limit-reset-credits' \
        2>/dev/null \
        || true
    )"
    reset_http_code="${reset_response##*$'\n'}"
    reset_response_body="${reset_response%$'\n'*}"
    if [[ "$reset_http_code" == "200" ]] \
      && jq -e '
        type == "object"
        and (.available_count | type == "number" and . >= 0 and floor == .)
        and (.available_count == ($usage_count | tonumber))
        and (.credits | type == "array")
        and all(.credits[];
          type == "object"
          and (.status | type == "string")
          and (.expires_at == null or (.expires_at | type == "string")))
      ' \
        --arg usage_count "$reset_count" \
        >/dev/null 2>&1 <<<"$reset_response_body"; then
      reset_details="$(jq -c '
        [.credits[]
         | select(.status == "available")
         | {
             expires_at: (.expires_at // null)
           }]
      ' <<<"$reset_response_body")"
    fi
  fi

  email="$(jq -r '
    .email //
    .account.email //
    .user.email //
    .viewer.email //
    .account_email //
    "unknown"
  ' <<<"$response_body")"
  if [[ -z "$email" || "$email" == "unknown" ]]; then
    email="${token_email:-unknown}"
  fi

  plan_type="$(jq -r '
    .plan_type //
    .account.plan_type //
    .subscription.plan_type //
    .plan.type //
    "unknown"
  ' <<<"$response_body")"

  limit_reached="$(jq -r '
    .rate_limit.limit_reached //
    .limit_reached //
    false
  ' <<<"$response_body")"

  # Map the raw /wham/usage response into codex's own model
  # (codex-backend-openapi-models: RateLimitStatusPayload /
  #  RateLimitWindowSnapshot). Windows are dynamic — labels are derived from
  #  limit_window_seconds with the same ±5% thresholds codex uses
  #  (tui/src/chatwidget/rate_limits.rs: get_limits_duration).
  jq -n \
    --arg auth_mode "$auth_mode" \
    --arg account_id "$account_id" \
    --arg identity "$identity" \
    --arg is_current "$is_current" \
    --arg email "$email" \
    --arg plan_type "$plan_type" \
    --arg limit_reached "$limit_reached" \
    --arg raw_auth "$(jq -c . <<<"$raw_account")" \
    --argjson reset_count "$reset_count" \
    --argjson reset_details "$reset_details" \
    --argjson usage "$response_body" '
    def label_for($seconds; $is_secondary):
      (($seconds // 0) / 60) as $m
      | if $m >= 285 and $m <= 315 then "5h"
        elif $m >= 1368 and $m <= 1512 then "daily"
        elif $m >= 9576 and $m <= 10584 then "weekly"
        elif $m >= 41040 and $m <= 45360 then "monthly"
        elif $m >= 499320 and $m <= 551880 then "annual"
        elif $is_secondary then "secondary usage"
        else "usage" end;

    # Display names mirror KnownPlan::display_name
    # (codex-rs/protocol/src/auth.rs).
    def plan_display($p):
      { "guest": "Guest",
        "free": "Free",
        "go": "Go",
        "plus": "Plus",
        "pro": "Pro",
        "prolite": "Pro Lite",
        "free_workspace": "Free Workspace",
        "team": "Team",
        "self_serve_business_prolite": "Self Serve Business ProLite",
        "self_serve_business_usage_based": "Self Serve Business Usage Based",
        "business": "Business",
        "ent26": "Enterprise",
        "enterprise_cbp_automation": "Enterprise (Automation)",
        "enterprise_cbp_usage_based": "Enterprise CBP Usage Based",
        "education": "Edu",
        "enterprise": "Enterprise",
        "edu": "Edu",
        "quorum": "Quorum",
        "k12": "K12",
        "unknown": "Unknown"
      }[$p] // $p;

    def win($w; $lbl):
      ($w // null) as $x
      | if $x == null or ($x | type) != "object" then empty
        else {
          label: $lbl,
          used_percent: ($x.used_percent // 0),
          remaining: ((100 - ($x.used_percent // 0)) | if . < 0 then 0 else . end),
          reset_after_seconds: ($x.reset_after_seconds // null),
          reset_at: ($x.reset_at // null)
        }
        end;

    def windows:
      [ win($usage.rate_limit.primary_window;
            label_for($usage.rate_limit.primary_window.limit_window_seconds; false)),
        win($usage.rate_limit.secondary_window;
            label_for($usage.rate_limit.secondary_window.limit_window_seconds; true)),
        ($usage.additional_rate_limits[]? // empty
          | win(.rate_limit.primary_window; .limit_name)) ];

    ($usage.credits.has_credits // false) as $hc
    | {
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $email,
        plan_type: plan_display($plan_type),
        limit_reached: $limit_reached,
        windows: windows,
        credits_text: (if $hc then
                        ("credits: " + (($usage.credits.balance // "?") | tostring))
                      else null end),
        # Mirrors the "Monthly credit limit" row from codex
        # (tui/src/status/rate_limits.rs) when spend-control limits exist.
        spend_text: (
          $usage.spend_control.individual_limit as $il
          | if $il != null and ($il | type) == "object" then
              ("monthly credit limit: " + (($il.remaining_percent // 0) | tostring)
               + "% remaining (" + (($il.used // "0") | tostring) + " of "
               + (($il.limit // "?") | tostring) + " credits used)")
            else null end
        ),
        reset_credits: ($reset_count | if . > 0 then . else null end),
        reset_credit_details: $reset_details,
        sort_key: ((windows | map(.remaining) | min) // 9999),
        query_error: null,
        raw_auth: ($raw_auth | fromjson)
      }'
}

build_results() {
  local metadata token_email
  RESULTS_FILE="$(mktemp)"
  jq -c '.[]' "$POOL_FILE" | while IFS= read -r account; do
    metadata="$(decode_id_token "$account" || echo '{}')"
    token_email="$(jq -r '.email // empty' <<<"$metadata")"
    fetch_usage_for_account "$account" "$token_email" \
      | jq --argjson metadata "$metadata" \
        '. + ($metadata | del(.email))' >> "$RESULTS_FILE"
    echo >> "$RESULTS_FILE"
  done
}

sort_results_to_json() {
  jq -s 'sort_by((if .is_current then 0 else 1 end), .sort_key, .email)' "$RESULTS_FILE"
}

# ------------- list section -------------
render_list_lines() {
  local sorted_json="$1"
  printf "${DIM}Codex auth pool: %s${RESET}\n" "$POOL_FILE"
  printf "${DIM}Current auth:    %s${RESET}\n\n" "$CURRENT_AUTH_FILE"

  jq -c '.[]' <<<"$sorted_json" | while IFS= read -r item; do
    local email plan_type limit_reached is_current query_error auth_mode
    local credits_text spend_text reset_credits reset_credit
    local expires_at expires_fmt reset_expiries reset_details_valid
    local subscription_until
    local w label remaining after at resfmt label_display remaining_colored any_window

    email="$(jq -r '.email' <<<"$item")"
    plan_type="$(jq -r '.plan_type' <<<"$item")"
    limit_reached="$(jq -r '.limit_reached' <<<"$item")"
    is_current="$(jq -r '.is_current' <<<"$item")"
    query_error="$(jq -r '.query_error // empty' <<<"$item")"
    auth_mode="$(jq -r '.auth_mode // "apikey"' <<<"$item")"
    credits_text="$(jq -r '.credits_text // empty' <<<"$item")"
    spend_text="$(jq -r '.spend_text // empty' <<<"$item")"
    reset_credits="$(jq -r '.reset_credits // empty' <<<"$item")"

    if [[ "$is_current" == "true" ]]; then
      # Active account is marked by its email in orange.
      printf ":) ${ORANGE}%s${RESET} [%s] (%s)" "$email" "$plan_type" "$auth_mode"
    else
      printf ":) %s [%s] (%s)" "$email" "$plan_type" "$auth_mode"
    fi

    if [[ "$auth_mode" == "chatgpt" ]]; then
      subscription_until="$(jq -r '.subscription_active_until // empty' <<<"$item")"
      printf " ${DIM}│ expires${RESET} "
      if expires_fmt="$(format_rfc3339_time "$subscription_until")"; then
        printf "${CYAN}%s${RESET} ${DIM}%s %s${RESET}" \
          "${expires_fmt%% *}" "${expires_fmt:11:5}" "$UTC_PLUS_8_LABEL"
      else
        printf "${DIM}unknown${RESET}"
      fi
    fi

    if [[ -n "$query_error" ]]; then
      if [[ "$query_error" == "usage check skipped for apikey auth" ]]; then
        # Informational note, not an error.
        printf "  ${DIM}%s${RESET}\n" "$query_error"
      else
        printf "  ${RED}%s${RESET}\n" "$query_error"
      fi
      printf "\n"
      continue
    else
      printf "\n"
    fi

    if [[ "$limit_reached" == "true" ]]; then
      printf "Rate Limit: ${RED}%s${RESET}\n" "$limit_reached"
    else
      printf "Rate Limit: ${GREEN}%s${RESET}\n" "$limit_reached"
    fi

    # One row per EXISTING usage window (primary / secondary / additional),
    # label derived from the window duration — mirrors codex's /status model.
    any_window=0
    while IFS= read -r w; do
      [[ -z "$w" ]] && continue
      any_window=1
      label="$(jq -r '.label' <<<"$w")"
      remaining="$(jq -r '.remaining' <<<"$w")"
      after="$(jq -r '.reset_after_seconds' <<<"$w")"
      at="$(jq -r '.reset_at' <<<"$w")"
      label_display="${label^}"   # capitalize first char: "weekly" -> "Weekly"
      remaining_colored="$(colorize_remaining "$remaining")"
      resfmt="$(format_reset_after "$after" "$at")"
      printf "  %s limit: %b remaining   resets in: %s\n" "$label_display" "$remaining_colored" "$resfmt"
    done < <(jq -c '.windows[]' <<<"$item")
    [[ "$any_window" -eq 0 ]] && printf "  ${DIM}(no usage windows)${RESET}\n"

    [[ -n "$credits_text" ]] && printf "  ${DIM}%s${RESET}\n" "$credits_text"
    [[ -n "$spend_text" ]] && printf "  ${DIM}%s${RESET}\n" "$spend_text"
    if [[ -n "$reset_credits" ]]; then
      reset_expiries=""
      reset_details_valid=1
      while IFS= read -r reset_credit; do
        [[ -z "$reset_credit" ]] && continue
        expires_at="$(jq -r '.expires_at // empty' <<<"$reset_credit")"
        if [[ -n "$expires_at" ]]; then
          if ! expires_fmt="$(format_rfc3339_time "$expires_at")"; then
            reset_details_valid=0
            break
          fi
        else
          expires_fmt="does not expire"
        fi
        if [[ -n "$reset_expiries" ]]; then
          reset_expiries+="; "
        fi
        reset_expiries+="$expires_fmt"
      done < <(jq -c '.reset_credit_details[]?' <<<"$item")
      if [[ "$reset_details_valid" -eq 1 && -n "$reset_expiries" ]]; then
        printf "  ${DIM}rate limit reset credits available: %s (%s)${RESET}\n" \
          "$reset_credits" "$reset_expiries"
      else
        printf "  ${DIM}rate limit reset credits available: %s${RESET}\n" "$reset_credits"
      fi
    fi

    printf "\n"
  done
}

# ------------- merged list + picker -------------
render_picker_lines() {
  local selected="$1" json="$2" count idx
  count="$(jq 'length' <<<"$json")"

  for (( idx=0; idx<count; idx++ )); do
    local item email line prefix

    item="$(jq -c ".[$idx]" <<<"$json")"
    email="$(jq -r '.email' <<<"$item")"

    prefix="  "
    [[ "$idx" -eq "$selected" ]] && prefix="> "

    # Minimal picker row: just the email. Full details (and the current
    # account marker) live in the list section above.
    line="${prefix}${email}"

    if [[ "$idx" -eq "$selected" ]]; then
      printf "${REVERSE}%s${RESET}\n" "$line"
    else
      printf "%s\n" "$line"
    fi
  done
}

run_merged() {
  local sorted_json count selected key item target_label is_current

  sorted_json="$(sort_results_to_json)"
  count="$(jq 'length' <<<"$sorted_json")"

  if [[ "$count" -eq 0 ]]; then
    render_list_lines "$sorted_json"
    printf "\n${YELLOW}No accounts in the pool yet — run 'codex-auth login', then this tool again.${RESET}\n"
    return 0
  fi

  # Usage-only mode, or non-interactive stdin → show the list only.
  if [[ "$MODE" != "switch" || ! -t 0 ]]; then
    render_list_lines "$sorted_json"
    return 0
  fi

  selected=0

  while true; do
    printf "\033[H\033[J"
    render_list_lines "$sorted_json"
    printf "\n${BOLD}Select account to switch${RESET}  ${DIM}(↑/↓ move, Enter confirm, q quit)${RESET}\n\n"
    render_picker_lines "$selected" "$sorted_json"

    IFS= read -rsn1 key || { printf "\n"; return 0; }

    if [[ "$key" == "q" || "$key" == "Q" ]]; then
      printf "\n${DIM}Cancelled — no changes made.${RESET}\n"
      return 0
    fi

    if [[ "$key" == "" ]]; then
      item="$(jq -c ".[$selected]" <<<"$sorted_json")"
      is_current="$(jq -r '.is_current' <<<"$item")"
      target_label="$(jq -r '.email' <<<"$item")"

      if [[ "$is_current" == "true" ]]; then
        # Enter on the active account: nothing changes; show the outcome in
        # the same dim style as the cancel message.
        printf "\033[H\033[J"
        printf "${DIM}Current account: %s${RESET}\n" "$target_label"
        return 0
      fi

      printf "\033[H\033[J"

      jq '.raw_auth' <<<"$item" > "$CURRENT_AUTH_FILE"
      chmod 600 "$CURRENT_AUTH_FILE"

      CURRENT_AUTH_IDENTITY="$(get_auth_identity "$(cat "$CURRENT_AUTH_FILE")")"

      # One-line outcome, same shape as the unchanged case; the orange email
      # is what marks that a switch happened.
      printf "Current account: ${ORANGE}%s${RESET}\n" "$target_label"
      return 0
    fi

    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 key || true
      case "$key" in
        "[A")
          (( selected > 0 )) && selected=$((selected - 1))
          ;;
        "[B")
          (( selected < count - 1 )) && selected=$((selected + 1))
          ;;
      esac
    fi
  done
}

# ------------- config.toml guard -------------
ensure_file_store_config() {
  # Make sure credentials are stored in ~/.codex/auth.json (file store).
  # This is the default since rust-v0.147.0, but set it explicitly so the
  # auth pool can always find the live credential as a file.
  local cfg="$CONFIG_TOML" tmpfile

  if [[ ! -f "$cfg" ]]; then
    # No config.toml yet — codex creates it on demand with the file-store
    # default, so there is nothing to patch.
    return 0
  fi

  if grep -qE '^("cli_auth_credentials_store"|cli_auth_credentials_store)[[:space:]]*=' "$cfg"; then
    if grep -qE '^("cli_auth_credentials_store"|cli_auth_credentials_store)[[:space:]]*=[[:space:]]*"file"' "$cfg"; then
      printf "${DIM}[config] cli_auth_credentials_store = \"file\" ${GREEN}✓${RESET}\n"
    else
      # Wrong value (keyring/auto/ephemeral) — fix in place.
      tmpfile="$(mktemp)"
      sed -E 's/^("?cli_auth_credentials_store"?)[[:space:]]*=.*/cli_auth_credentials_store = "file"/' "$cfg" > "$tmpfile"
      mv "$tmpfile" "$cfg"
      printf "${YELLOW}[config] fixed cli_auth_credentials_store → \"file\"${RESET}\n"
    fi
    return 0
  fi

  # Key missing — insert it into the TOP-LEVEL section: before the first
  # [table] header (or at EOF for table-free files). Appending after a table
  # header would silently put the key inside that table in TOML.
  if grep -qE '^[[:space:]]*\[' "$cfg"; then
    tmpfile="$(mktemp)"
    awk -v add1='# Credentials live in ~/.codex/auth.json (added by codex-auth.sh).' \
        -v add2='cli_auth_credentials_store = "file"' '
      !done && /^[[:space:]]*\[/ { print add1; print add2; print ""; done = 1 }
      { print }
    ' "$cfg" > "$tmpfile"
    mv "$tmpfile" "$cfg"
  else
    printf '\n# Credentials live in ~/.codex/auth.json (added by codex-auth.sh).\ncli_auth_credentials_store = "file"\n' >> "$cfg"
  fi
  printf "${YELLOW}[config] added cli_auth_credentials_store = \"file\"${RESET}\n"
}

check_current_auth_presence() {
  # An ACTIVE login already stored in auth.json needs no re-login. Only when
  # the credential file is missing (e.g. it lived in an OS keyring before the
  # store mode was switched to file) does codex need to authenticate again.
  if [[ ! -f "$CURRENT_AUTH_FILE" ]]; then
    printf "${YELLOW}[auth] no credential file at %s — run: ${BOLD}codex login${RESET}\n" "$CURRENT_AUTH_FILE"
  fi
}

# ------------- login flow -------------
cmd_login() {
  # Guide a NEW account login: back up the live credential into the pool,
  # remove auth.json so the device-auth flow starts fresh, run the real
  # `codex login`, then capture the result back into the pool. A live
  # credential whose mode the pool cannot store is never deleted.
  if ! command -v codex >/dev/null 2>&1; then
    echo "Error: codex CLI not found — install it first." >&2
    exit 1
  fi

  ensure_file_store_config
  check_current_auth_presence
  upsert_current_auth_if_present

  if [[ -f "$CURRENT_AUTH_FILE" ]]; then
    # The pool holds only chatgpt and apikey credentials, and the upsert
    # above skipped every other mode. Deleting such a file would destroy
    # the only copy of a credential nothing can restore, so refuse instead.
    local live_mode
    live_mode="$(get_auth_mode "$(cat "$CURRENT_AUTH_FILE")")"
    if [[ "$live_mode" != "chatgpt" && "$live_mode" != "apikey" ]]; then
      printf "${RED}Error: current auth.json uses unsupported auth_mode '%s', which the pool cannot store.${RESET}\n" "$live_mode" >&2
      printf "${RED}Refusing to delete the only credential copy; back it up or move it away manually, then re-run login.${RESET}\n" >&2
      exit 1
    fi
    rm -f "$CURRENT_AUTH_FILE"
    printf "${GREEN}[login] previous credential is safe in the pool; auth.json cleared.${RESET}\n"
  fi
  printf "${BOLD}Starting codex login...${RESET}\n"
  printf "${DIM}Tip: use a browser (or incognito window) where only the account you want is\n"
  printf "signed in, and complete the authorization — aborting mid-flow can revoke the\n"
  printf "current account's tokens server-side.${RESET}\n\n"

  if ! codex login "$@"; then
    printf "\n${YELLOW}[login] login did not complete. The previous credential is still in the${RESET}\n"
    printf "${YELLOW}pool — run codex-auth to restore it (if the server revoked its tokens,${RESET}\n"
    printf "${YELLOW}re-login instead).${RESET}\n"
    return 0
  fi

  upsert_current_auth_if_present
  printf "\n${GREEN}[login] new account captured into the pool.${RESET}\n"
  codex login status || true
}

# ------------- main -------------
if [[ "$MODE" == "login" ]]; then
  cmd_login "$@"
  exit 0
fi

printf "${DIM}> %s${RESET}\n" "$(format_abs_time "$(date +%s)")"
ensure_file_store_config
check_current_auth_presence
upsert_current_auth_if_present

if [[ -f "$CURRENT_AUTH_FILE" ]]; then
  CURRENT_AUTH_IDENTITY="$(get_auth_identity "$(cat "$CURRENT_AUTH_FILE")")"
else
  CURRENT_AUTH_IDENTITY=""
fi

ensure_pool_file
build_results

run_merged
