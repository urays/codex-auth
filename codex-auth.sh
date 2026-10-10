#!/usr/bin/env bash
set -euo pipefail

# codex-auth.sh — manage multiple Codex CLI accounts from a single auth pool.
# Compatible with Bash 3.2+ on macOS and Linux (BSD/GNU utilities).
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
#     selected credential back to ~/.codex/auth.json. When the account changes,
#     the installation_id beside auth.json is removed and a running managed
#     daemon is restarted to load the new credentials.
#   - `codex-auth login` prepares a NEW account login: the live credential is
#     backed up into the pool first, auth.json is removed so the device-auth
#     flow starts clean (otherwise the browser just re-authorizes the account
#     it is already signed into), then the real `codex login` runs and the
#     resulting credential is captured back into the pool automatically. A
#     live credential whose mode the pool cannot store is never deleted.
#   - Session/history files stay in the same CODEX_HOME. Finish active work
#     before changing accounts: restarting the daemon can interrupt calls.
#     config.toml may be updated to enforce cli_auth_credentials_store = "file".

CODEX_AUTH_HOME="${CODEX_HOME:-$HOME/.codex}"
CURRENT_AUTH_FILE="${CURRENT_AUTH_FILE:-$CODEX_AUTH_HOME/auth.json}"
POOL_FILE="${AUTH_POOL_FILE:-$CODEX_AUTH_HOME/auth-poll.json}"
CONFIG_TOML="${CONFIG_TOML:-$CODEX_AUTH_HOME/config.toml}"

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
    shift
  else
    echo "Error: unknown command: $1 (supported: login, switch, or run without arguments)" >&2
    exit 1
  fi
fi

if [[ $# -gt 0 ]]; then
  echo "Error: unexpected argument: $1" >&2
  exit 1
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
  if [[ -n "${TMP_AUTH_FILE:-}" && -f "$TMP_AUTH_FILE" ]]; then
    rm -f "$TMP_AUTH_FILE"
  fi
  if [[ -n "${TMP_DAEMON_ERROR:-}" && -f "$TMP_DAEMON_ERROR" ]]; then
    rm -f "$TMP_DAEMON_ERROR"
  fi
}
trap cleanup EXIT

# ------------- auth pool helpers -------------
# Match AuthDotJson::resolved_mode in the current Codex CLI. auth_mode is optional.
AUTH_MODE_JQ='
  def auth_mode:
    .auth_mode // (
      if .personal_access_token != null then "personalAccessToken"
      elif .bedrock_api_key != null then "bedrockApiKey"
      elif .bedrock_access_keys != null then "bedrockAccessKeys"
      elif .OPENAI_API_KEY != null then "apikey"
      else "chatgpt" end
    );
'

get_auth_mode() {
  jq -r "$AUTH_MODE_JQ auth_mode" <<<"$1"
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
  local auth_file="${1:-$CURRENT_AUTH_FILE}"
  if ! jq -e "$AUTH_MODE_JQ"'
    type == "object"
    and (.auth_mode == null or (.auth_mode | type == "string"))
    and (.OPENAI_API_KEY == null or (.OPENAI_API_KEY | type == "string"))
    and (
      (
        auth_mode == "chatgpt"
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
        and (.tokens.id_token | type == "string" and length > 0)
        and (.last_refresh | type == "string" and length > 0)
      )
      or
      (
        auth_mode == "apikey"
        and .OPENAI_API_KEY
        and (.OPENAI_API_KEY | type == "string")
        and (.OPENAI_API_KEY | length > 0)
      )
    )
  ' "$auth_file" > /dev/null; then
    echo "Error: invalid chatgpt/apikey auth.json: $auth_file" >&2
    return 1
  fi
  # Codex deserializes the ID token's JWT claims and an RFC3339 last_refresh.
  # Checking just account_id would accept a file Codex cannot actually use.
  if ! python3 - "$auth_file" 3<<<"${2:-null}" <<'PY'
import base64
from datetime import datetime
import json
import os
import sys

def require(condition):
    if not condition:
        raise ValueError("invalid credentials")

def jwt_claims(token):
    parts = token.split(".")
    require(len(parts) >= 3 and all(parts[:3]))
    payload = parts[1]
    claims = json.loads(base64.b64decode(payload + "=" * (-len(payload) % 4), altchars=b"-_", validate=True))
    require(isinstance(claims, dict))
    return claims

def principal(claims):
    details = claims.get("https://api.openai.com/auth") or {}
    # A workspace selected in account_id may differ from a token's default
    # workspace. Compare user identifiers, not that default workspace claim.
    return {key: value for key, value in {
        "sub": claims.get("sub"),
        "user": details.get("chatgpt_user_id") or details.get("user_id"),
    }.items() if isinstance(value, str) and value}

try:
    with open(sys.argv[1]) as stream:
        auth = json.load(stream)
    tokens = auth.get("tokens")
    if tokens is not None:
        for key in ("id_token", "access_token", "refresh_token"):
            require(isinstance(tokens[key], str))
        require(tokens.get("account_id") is None or isinstance(tokens["account_id"], str))
        claims = jwt_claims(tokens["id_token"])
        for section in (claims, claims.get("https://api.openai.com/profile")):
            require(section is None or isinstance(section, dict))
            if section is not None:
                require(section.get("email") is None or isinstance(section["email"], str))
        details = claims.get("https://api.openai.com/auth")
        require(details is None or isinstance(details, dict))
        if details is not None:
            for key in ("chatgpt_user_id", "user_id", "chatgpt_account_id", "chatgpt_plan_type"):
                require(details.get(key) is None or isinstance(details[key], str))
            if "chatgpt_account_is_fedramp" in details:
                require(isinstance(details["chatgpt_account_is_fedramp"], bool))
    refreshed = auth.get("last_refresh")
    if refreshed is not None:
        require(datetime.fromisoformat(refreshed.replace("Z", "+00:00")).tzinfo is not None)
    with os.fdopen(3) as stream:
        expected = json.load(stream)
    if expected is not None:
        mode = lambda raw: raw.get("auth_mode") or ("apikey" if raw.get("OPENAI_API_KEY") is not None else "chatgpt")
        require(mode(auth) == mode(expected))
        if mode(expected) == "apikey":
            require(auth["OPENAI_API_KEY"] == expected["OPENAI_API_KEY"])
        else:
            previous = expected["tokens"]
            require(tokens["account_id"] == previous["account_id"])
            for key in ("id_token", "access_token"):
                if tokens[key] != previous[key]:
                    before, after = principal(jwt_claims(previous[key])), principal(jwt_claims(tokens[key]))
                    require(bool(before) and all(after.get(k) == v for k, v in before.items()))
except (KeyError, ValueError, TypeError, AttributeError, OSError):
    sys.exit(1)
PY
  then
    echo "Error: invalid token data or refresh timestamp in auth.json: $auth_file" >&2
    return 1
  fi
}

ensure_pool_file() {
  if [[ ! -f "$POOL_FILE" ]]; then
    echo '[]' > "$POOL_FILE" || return 1
  fi
  chmod 600 "$POOL_FILE" || return 1
  if ! jq -e 'type == "array"' "$POOL_FILE" > /dev/null; then
    echo "Error: auth pool file is not a JSON array: $POOL_FILE" >&2
    return 1
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
  live_mode="$(get_auth_mode "$(cat "$CURRENT_AUTH_FILE")")" || return 1
  if [[ "$live_mode" != "chatgpt" && "$live_mode" != "apikey" ]]; then
    printf "${YELLOW}[auth] unsupported auth_mode '%s' — skipped pool upsert${RESET}\n" "$live_mode"
    return 0
  fi

  validate_current_auth_file || return 1
  ensure_pool_file || return 1

  TMP_UPSERT_FILE="$(mktemp "${POOL_FILE}.XXXXXX")" || return 1

  jq --slurpfile new_auth "$CURRENT_AUTH_FILE" "$AUTH_MODE_JQ"'
    def auth_identity($a):
      if ($a | auth_mode) == "chatgpt" then
        ($a.tokens.account_id // "")
      elif ($a | auth_mode) == "apikey" then
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
  ' "$POOL_FILE" > "$TMP_UPSERT_FILE" || return 1

  chmod 600 "$TMP_UPSERT_FILE" || return 1
  mv -f -- "$TMP_UPSERT_FILE" "$POOL_FILE" || return 1
  unset TMP_UPSERT_FILE
}

# ------------- account changes + managed daemon -------------
codex_cli() {
  CODEX_HOME="$CODEX_AUTH_HOME" command codex "$@"
}

prepare_account_change() {
  local auth_dir config_dir
  if ! command -v codex >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "Error: account changes require the current Codex CLI and Python 3." >&2
    return 1
  fi
  mkdir -p -- "$CODEX_AUTH_HOME" || return 1
  CODEX_AUTH_HOME="$(cd -- "$CODEX_AUTH_HOME" && pwd -P)" || return 1
  auth_dir="$(cd -- "$(dirname -- "$CURRENT_AUTH_FILE")" && pwd -P)" || return 1
  config_dir="$(cd -- "$(dirname -- "$CONFIG_TOML")" && pwd -P)" || return 1
  # A CLI invocation always reads these names from CODEX_HOME. Refuse overrides
  # that would update one credential while restarting another home's daemon.
  if [[ "$auth_dir/$(basename -- "$CURRENT_AUTH_FILE")" != "$CODEX_AUTH_HOME/auth.json" ||
        "$config_dir/$(basename -- "$CONFIG_TOML")" != "$CODEX_AUTH_HOME/config.toml" ||
        -L "$CURRENT_AUTH_FILE" || ( -e "$CURRENT_AUTH_FILE" && ! -f "$CURRENT_AUTH_FILE" ) ]]; then
    echo "Error: account changes require auth.json and config.toml in CODEX_HOME; auth.json must be a regular file, not a symlink." >&2
    return 1
  fi
  CURRENT_AUTH_FILE="$CODEX_AUTH_HOME/auth.json"
  CONFIG_TOML="$CODEX_AUTH_HOME/config.toml"
  if ! codex_cli app-server daemon restart --help >/dev/null 2>&1; then
    echo "Error: the current Codex CLI daemon commands are required." >&2
    return 1
  fi
  probe_daemon
}

probe_daemon() {
  local output
  TMP_DAEMON_ERROR="$(mktemp)" || return 1
  if output="$(codex_cli app-server daemon version 2>"$TMP_DAEMON_ERROR")"; then
    if ! jq -e --arg socket "$CODEX_AUTH_HOME/app-server-control/app-server-control.sock" '
      .status == "running" and .backend == "pid" and .socketPath == $socket
      and (.appServerVersion | type == "string" and length > 0)
    ' <<<"$output" >/dev/null 2>&1; then
      echo "Error: unexpected daemon status or an unmanaged app-server; credentials were not synchronized." >&2
      return 1
    fi
    DAEMON_WAS_RUNNING=1
  else
    # The current CLI has no structured not-running response for `version`.
    # Accept only its exact missing-socket error AND absent runtime records.
    # Timeouts, permissions, stale records, startup reservations and malformed
    # settings remain errors. Never infer 'stopped' from an arbitrary failure.
    if ! python3 - "$CODEX_AUTH_HOME" "$TMP_DAEMON_ERROR" <<'PY'
import fcntl
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
message = Path(sys.argv[2]).read_text()
socket_path = root / "app-server-control/app-server-control.sock"
if f"failed to connect to {socket_path}" not in message or "(os error 2)" not in message:
    sys.exit(1)
try:
    for entry in (socket_path, root / "app-server-daemon/daemon.pid",
                  root / "app-server-daemon/app-server.pid"):
        try:
            entry.lstat()
        except FileNotFoundError:
            continue
        sys.exit(1)
    # Both PID namespaces are used by the current CLI, depending on installation.
    for name in ("daemon.pid.lock", "app-server.pid.lock", "daemon.lock"):
        try:
            fd = os.open(root / "app-server-daemon" / name, os.O_RDONLY)
        except FileNotFoundError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd)
except OSError:
    sys.exit(1)
PY
    then
      echo "Error: cannot confirm daemon state; account change cannot complete." >&2
      cat "$TMP_DAEMON_ERROR" >&2
      return 1
    fi
    DAEMON_WAS_RUNNING=0
  fi
  rm -f -- "$TMP_DAEMON_ERROR"
  unset TMP_DAEMON_ERROR
}

daemon_recovery_hint() {
  printf 'Credentials may already be updated. After finishing active work, retry: CODEX_HOME=%q codex app-server daemon restart\n' \
    "$CODEX_AUTH_HOME" >&2
}

finish_account_change() {
  local expected_auth="$1" output was_running="$DAEMON_WAS_RUNNING"
  # Login can take minutes. Recheck so a daemon started during that flow is
  # refreshed too. A daemon that stopped meanwhile stays stopped.
  if ! probe_daemon; then
    daemon_recovery_hint
    return 1
  fi
  if ! rm -f -- "$CODEX_AUTH_HOME/installation_id"; then
    echo "Error: credentials updated, but installation_id could not be removed." >&2
    daemon_recovery_hint
    return 1
  fi
  if [[ "$DAEMON_WAS_RUNNING" -eq 1 ]]; then
    printf '%b[daemon] restarting to load the new account...%b\n' "$DIM" "$RESET"
    if ! output="$(codex_cli app-server daemon restart)"; then
      echo "Error: credentials updated, but daemon restart failed." >&2
      daemon_recovery_hint
      return 1
    fi
    if ! jq -e --arg socket "$CODEX_AUTH_HOME/app-server-control/app-server-control.sock" '
      .status == "restarted" and .backend == "pid" and .socketPath == $socket
      and (.appServerVersion | type == "string" and length > 0)
    ' <<<"$output" >/dev/null 2>&1; then
      echo "Error: credentials updated, but daemon restart could not be verified." >&2
      daemon_recovery_hint
      return 1
    fi
  elif [[ "$was_running" -eq 1 ]]; then
    printf '%b[daemon] no longer running; the next start will load the account.%b\n' "$DIM" "$RESET"
  fi
  if ! validate_current_auth_file "$CURRENT_AUTH_FILE" "$expected_auth"; then
    echo "Error: credentials changed unexpectedly during account activation; retry after finishing other Codex activity." >&2
    return 1
  fi
}

activate_auth() {
  local raw="$1"
  prepare_account_change || return 1
  TMP_AUTH_FILE="$(mktemp "$CODEX_AUTH_HOME/.auth.json.XXXXXX")" || return 1
  if ! jq '.' <<<"$raw" > "$TMP_AUTH_FILE" ||
     ! validate_current_auth_file "$TMP_AUTH_FILE" ||
     ! chmod 600 "$TMP_AUTH_FILE"; then
    return 1
  fi
  # Capture tokens refreshed while the account picker was open.
  # Unlike listing, replacing a credential requires that the pool can back it up.
  if [[ -f "$CURRENT_AUTH_FILE" ]]; then
    validate_current_auth_file || return 1
  fi
  upsert_current_auth_if_present || return 1
  if ! mv -f -- "$TMP_AUTH_FILE" "$CURRENT_AUTH_FILE"; then
    echo "Error: could not replace auth.json; daemon was not restarted." >&2
    return 1
  fi
  unset TMP_AUTH_FILE
  finish_account_change "$raw"
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

  # Match Codex's account-scoped backend requests. A user token can access
  # multiple workspaces; without this header /wham/usage may return the
  # default workspace's quota instead of this pool entry's quota.
  tmp_body="$(mktemp)"
  http_code="$(
    curl -sS \
      -o "$tmp_body" \
      -w '%{http_code}' \
      "$USAGE_URL" \
      -H 'accept: */*' \
      -H 'accept-language: en-GB,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,en-US;q=0.6,ja;q=0.5' \
      -H "authorization: Bearer $access_token" \
      -H "ChatGPT-Account-Id: $account_id" \
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
        -H "ChatGPT-Account-Id: $account_id" \
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
    local w remaining after at resfmt label_display remaining_colored any_window

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
      # Capitalize via jq so macOS's Bash 3.2 works too (weekly -> Weekly).
      label_display="$(jq -r '.label | (.[0:1] | ascii_upcase) + .[1:]' <<<"$w")"
      remaining="$(jq -r '.remaining' <<<"$w")"
      after="$(jq -r '.reset_after_seconds' <<<"$w")"
      at="$(jq -r '.reset_at' <<<"$w")"
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
  local previous

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
  printf "\033[H\033[J"
  render_list_lines "$sorted_json"
  printf "\n${DIM}Finish active Codex/Lumen work first; switching restarts a running daemon.${RESET}\n"
  printf "${BOLD}Select account to switch${RESET}  ${DIM}(↑/↓ move, Enter confirm, q quit)${RESET}\n\n"
  # Buffer the picker and keep each option on one physical row so moving
  # back by $count rows also works when an email exceeds the terminal width.
  printf '\033[?7l%s\n\033[?7h' "$(render_picker_lines "$selected" "$sorted_json")"

  while true; do
    previous="$selected"

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

      activate_auth "$(jq '.raw_auth' <<<"$item")" || return 1
      CURRENT_AUTH_IDENTITY="$(get_auth_identity "$(cat "$CURRENT_AUTH_FILE")")"
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

    if [[ "$selected" -ne "$previous" ]]; then
      # Return to the picker, leaving the usage list above it untouched.
      printf '\033[%dA\r\033[J\033[?7l%s\n\033[?7h' \
        "$count" "$(render_picker_lines "$selected" "$sorted_json")"
    fi
  done
}

# ------------- config.toml guard -------------
ensure_file_store_config() {
  # The current Codex default is file storage; an absent config needs no edit.
  if [[ ! -f "$CONFIG_TOML" ]]; then
    if [[ -e "$CONFIG_TOML" || -L "$CONFIG_TOML" ]]; then
      echo "Error: config.toml is not a readable regular file." >&2
      return 1
    fi
    return 0
  fi
  if ! python3 - "$CONFIG_TOML" <<'PY'
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

try:
    import tomllib
except ImportError:
    tomllib = None

temporary = None
try:
    path = Path(sys.argv[1]).resolve(strict=True)
    original = path.read_text()
    if tomllib is not None:
        tomllib.loads(original)
    lines = original.splitlines(keepends=True)
    key = re.compile(r'''^([ \t]*(?:cli_auth_credentials_store|"cli_auth_credentials_store"|'cli_auth_credentials_store')[ \t]*=[ \t]*)(.*?)(\r?\n)?$''')
    quote, depth, found = None, 0, False
    for index, line in enumerate(lines):
        if quote is None and depth == 0:
            if line.lstrip().startswith("["):
                break  # Everything after a table header belongs to a table.
            match = key.match(line)
            if match:
                value = re.fullmatch(r'''(["'])([^"']*)\1([ \t]*(?:#.*)?)''', match[2])
                if value is None:
                    raise ValueError("credential store must be a single-line quoted value")
                if value[2] != "file":
                    lines[index] = match[1] + '"file"' + value[3] + (match[3] or "")
                found = True
                break
        # Locate real table/key boundaries without matching examples inside
        # multiline strings, arrays or inline tables. Preserve their text.
        pos = 0
        while pos < len(line):
            char = line[pos]
            if quote is not None:
                if quote[0] == '"' and char == "\\":
                    pos += 2
                    continue
                if line.startswith(quote, pos):
                    pos += len(quote)
                    quote = None
                    continue
            elif char == "#":
                break
            elif char in "\"'":
                quote = char * (3 if line.startswith(char * 3, pos) else 1)
                pos += len(quote)
                continue
            elif char in "[{":
                depth += 1
            elif char in "]}":
                depth -= 1
            pos += 1
    updated = "".join(lines)
    if not found:
        updated = 'cli_auth_credentials_store = "file"\n' + updated
    if tomllib is not None:
        tomllib.loads(updated)
    if updated != original:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".config.toml.", delete=False) as stream:
            temporary = stream.name
            os.fchmod(stream.fileno(), stat.S_IMODE(path.stat().st_mode))
            stream.write(updated)
        os.replace(temporary, path)
        temporary = None
except (OSError, ValueError) as error:
    print(f"Error: could not configure file credential storage: {error}", file=sys.stderr)
    sys.exit(1)
finally:
    if temporary is not None:
        os.unlink(temporary)
PY
  then
    return 1
  fi
  printf '%b[config] cli_auth_credentials_store = "file"%b\n' "$DIM" "$RESET"
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
  local expected_auth
  prepare_account_change || return 1

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
  printf "${DIM}Finish active Codex/Lumen work first; successful login restarts a running daemon.${RESET}\n"
  printf "${BOLD}Starting codex login...${RESET}\n"
  printf "${DIM}Tip: use a browser (or incognito window) where only the account you want is\n"
  printf "signed in, and complete the authorization — aborting mid-flow can revoke the\n"
  printf "current account's tokens server-side.${RESET}\n\n"

  if ! codex_cli login "$@"; then
    printf "\n${YELLOW}[login] login did not complete. The previous credential is still in the${RESET}\n"
    printf "${YELLOW}pool — run codex-auth switch to restore it (if the server revoked its tokens,${RESET}\n"
    printf "${YELLOW}re-login instead).${RESET}\n"
    return 1
  fi

  validate_current_auth_file || return 1
  chmod 600 "$CURRENT_AUTH_FILE" || return 1
  expected_auth="$(cat "$CURRENT_AUTH_FILE")" || return 1
  upsert_current_auth_if_present || return 1
  finish_account_change "$expected_auth" || return 1
  printf "\n${GREEN}[login] new account captured into the pool.${RESET}\n"
  codex_cli login status || true
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
