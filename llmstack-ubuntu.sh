#!/bin/bash
#
# llmstack-ubuntu.sh  v1.0.0
#
# A self-contained, private LLM stack for Ubuntu 24.04 and 26.04.
#
#   Ollama       local inference engine (systemd service)
#   Open WebUI   web front-end (Docker container or uv-managed venv)
#   SearXNG      private metasearch, for web search in Open WebUI
#
# Everything starts at boot with nobody logged in. Model recommendations
# are sized to the largest usable GPU's VRAM, or to system RAM and memory
# bandwidth when there is no usable discrete GPU.
#
# Run  ./llmstack-ubuntu.sh --help  for full documentation.
#
# Port of MacOS-Local-LLM-Stack v3.6.1:
#   https://github.com/cautionespn/MacOS-Local-LLM-Stack
#
# License: GNU General Public License v3.0. See the LICENSE file in
# https://github.com/cautionespn/Linux-Local-LLM-Stack for the full text.
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"
CATALOG_DATE="2026-09-30"
# Shared with the macOS and Windows repositories: the MacOS-Local-LLM-Stack
# version in which the built-in catalogue rows last changed. Keep the three
# in step; bump only when the rows in write_default_catalog change.
CATALOG_GENERATION="3.4.0"
CATALOG_WARN_DAYS=90
CATALOG_STALE_DAYS=180

# Dense-model speed gate, applied only when no discrete GPU sizes the picks
# (CPU-only or integrated GPU): tok/s ~= memory bandwidth / model size, and
# real runs reach roughly 65 percent of that.
DENSE_MIN_TPS=8
DENSE_EFFICIENCY_PCT=65
# Share of the sizing pool usable for weights. VRAM keeps a quarter back for
# the KV cache and Ollama's per-GPU reservation; system RAM keeps 30 percent
# for the OS and everything else.
VRAM_BUDGET_PCT=75
RAM_BUDGET_PCT=70
# Fallback CPU memory bandwidth when DIMM speed cannot be read: DDR4-3200,
# two channels.
DEFAULT_RAM_MTS=3200
ASSUMED_CHANNELS=2

SUPPORTED_UBUNTU="24.04 26.04"

# ---------------------------------------------------------------------------
# Paths and defaults
# ---------------------------------------------------------------------------
# LLMSTACK_CONFIG_DIR and LLMSTACK_ROOT exist for tests and unusual layouts:
# the first moves /etc/llmstack, the second prefixes every hardware read
# (/sys, /proc, /dev, /etc/os-release) so detection can be exercised against
# a fake tree.
CONFIG_DIR="${LLMSTACK_CONFIG_DIR:-/etc/llmstack}"
HW_ROOT="${LLMSTACK_ROOT:-}"
CONFIG_FILE="$CONFIG_DIR/config"
CATALOG="$CONFIG_DIR/models.catalog"
ENV_FILE="$CONFIG_DIR/openwebui.env"
SEARXNG_DIR="$CONFIG_DIR/searxng"
SEARXNG_SETTINGS="$SEARXNG_DIR/settings.yml"
OPT_DIR="/opt/llmstack"
COMPOSE_FILE="$OPT_DIR/compose.yaml"
VENV_DIR="$OPT_DIR/openwebui-venv"
UV_PYTHON_DIR="$OPT_DIR/python"
DATA_DIR="/var/lib/llmstack/open-webui"
OLLAMA_UNIT="/etc/systemd/system/ollama.service"
OLLAMA_DROPIN_DIR="/etc/systemd/system/ollama.service.d"
OLLAMA_DROPIN="$OLLAMA_DROPIN_DIR/llmstack.conf"
OLLAMA_HOME="/usr/share/ollama"
OLLAMA_MODELS_DIR="$OLLAMA_HOME/.ollama/models"
WEBUI_UNIT="/etc/systemd/system/llmstack-openwebui.service"
WEBUI_USER="open-webui"
CMD_DIR="/usr/local/bin"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
SEARXNG_IMAGE="docker.io/searxng/searxng:latest"
OLLAMA_API="http://127.0.0.1:11434"

# Defaults, overridable by flags or an existing config file.
WEBUI_RUNTIME="docker"
SEARXNG_MODE="local"
SEARXNG_HOST_PORT="8888"
SEARXNG_URL="http://127.0.0.1:${SEARXNG_HOST_PORT}"
WEBUI_PORT="8080"
SKIP_MODEL="no"
FORCE_MODEL=""
OLLAMA_VERSION_PIN=""
NVIDIA_DRIVER_ANSWER=""
ASSUME_YES="no"
DISCOVER="no"

# ---------------------------------------------------------------------------
# Colour and logging (colour only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  C_BOLD="$(tput bold)"; C_RED="$(tput setaf 1)"; C_YELLOW="$(tput setaf 3)"
  C_GREEN="$(tput setaf 2)"; C_RESET="$(tput sgr0)"
else
  C_BOLD="" C_RED="" C_YELLOW="" C_GREEN="" C_RESET=""
fi

log()   { printf '\n%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$1"; }
warn()  { printf '\n%sWARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
error() { printf '\n%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }

# Every prompt defaults to no.
confirm() {
  local reply
  printf '\n%s [y/N]: ' "$1"
  read -r reply || reply=""
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# For the install's own go-ahead questions only: --yes answers these.
# Removal and uninstall prompts always use confirm().
confirm_install() {
  if [ "$ASSUME_YES" = "yes" ]; then
    printf '\n%s [y/N]: y (--yes)\n' "$1"
    return 0
  fi
  confirm "$1"
}

validate_port() {
  local p="$1"
  if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    error "Invalid port: '$p' (must be 1–65535)"
  fi
}

# Echoes "process pid" holding a TCP port and returns 0, or returns 1.
port_in_use() {
  local port="$1" line
  line="$(ss -ltnpH "sport = :$port" 2>/dev/null | head -1)" || true
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | sed -n 's/.*users:((\("[^"]*"\),pid=\([0-9]*\).*/\1 \2/p' | tr -d '"' | grep . || echo "unknown process"
  return 0
}

# Run a command as root: directly when already root, otherwise via sudo.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Install a file with a mode, as root, creating its directory.
put_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  as_root install -D -m "$mode" "$src" "$dest"
}

# True when the config directory can be written (as root, or by this user).
config_writable() {
  [ "$(id -u)" -eq 0 ] && return 0
  [ -w "$CONFIG_DIR" ] && return 0
  [ ! -e "$CONFIG_DIR" ] && [ -w "$(dirname "$CONFIG_DIR")" ] && return 0
  sudo -n true 2>/dev/null
}

# ---------------------------------------------------------------------------
# Error trap — report partial state on unexpected exit during install
# ---------------------------------------------------------------------------
INSTALL_STARTED="no"
on_error() {
  local rc=$?
  [ -z "${CATALOG_TMP:-}" ] || rm -f "$CATALOG_TMP" "${CATALOG_TMP}.proposed"
  if [ "$INSTALL_STARTED" = "yes" ] && [ "$rc" -ne 0 ]; then
    printf '\n%s==========================================================%s\n' "$C_RED" "$C_RESET"
    printf '%sThe script exited with an error (code %d).%s\n' "$C_RED" "$rc" "$C_RESET"
    printf '%sPartial state may remain. Re-running is safe (the script is idempotent).%s\n' "$C_RED" "$C_RESET"
    printf 'Logs:  journalctl -u ollama -n 50\n'
    printf '       journalctl -u llmstack-openwebui -n 50    (venv runtime)\n'
    printf '       sudo docker compose -f %s logs --tail 50   (containers)\n' "$COMPOSE_FILE"
    printf '%s==========================================================%s\n' "$C_RED" "$C_RESET"
  fi
}
trap on_error EXIT

# ===========================================================================
# MODEL CATALOGUE
# ===========================================================================
# Model tags verified against https://ollama.com/library on 2026-09-30.
# SIZE_GB is the download size of that exact tag, which is not always a
# q4 quantization; it may be a decimal.
# Writes the built-in catalogue to the file named in $1.
write_default_catalog() {
  cat > "$1" <<CATALOG_EOF
# ===========================================================================
# Model catalogue for llmstack-ubuntu.sh
# ===========================================================================
#
# Last-Updated: ${CATALOG_DATE}
# Catalogue-Generation: ${CATALOG_GENERATION}
#
# Last-Updated is when a person last reviewed this file; the script grades
# staleness from it. Catalogue-Generation records which built-in catalogue
# this file descends from; --sync-models offers to replace the file when
# the script ships a newer generation. If you maintain your own catalogue,
# keep the Catalogue-Generation line current to stop that offer.
#
# Local model releases move quickly. Treat this file as a starting point,
# not an authority, and revise it as new models appear. When you do, update
# the Last-Updated line above; the script reads it and will tell you how
# stale the file has become.
#
# Selection rule used by the script
# -----------------------------------------------------------------------
# Within each role, the largest entry that passes all three gates wins:
#   1. SIZE_GB fits the budget: ${VRAM_BUDGET_PCT} percent of the largest usable
#      GPU's VRAM, or ${RAM_BUDGET_PCT} percent of system RAM without one.
#   2. The machine has at least MIN_RAM_GB of system RAM.
#   3. Dense entries only, and only without a discrete GPU: estimated
#      RAM bandwidth can generate at ${DENSE_MIN_TPS} tok/s or better. MoE
#      entries are exempt.
# Because the largest passing entry wins, keep size tracking quality within
# a role, and do not list several quantizations of the same model.
#
# Why architecture matters without a GPU
# -----------------------------------------------------------------------
# On a CPU, token generation is limited by memory bandwidth. A dense
# model reads every parameter for every token. A mixture-of-experts model
# reads only its active experts, so it generates far faster while still
# needing the full weight set resident in memory. Gate 3 is what keeps
# large dense models off machines too slow to drive them. A model that
# fits in a discrete GPU's VRAM is fast either way, so gate 3 is off there.
#
# The VERIFIED column
# -----------------------------------------------------------------------
# yes  the tag was confirmed to exist in the Ollama registry
# no   the tag is plausible but unconfirmed and may fail to pull
#
# Check current tags at https://ollama.com/library and correct this file.
#
# Format: MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
# ===========================================================================
# --- Light (fallback for the smallest machines) ----------------------------
4|granite4.2:3b|2.2|dense|light|yes|IBM Granite 4.2 3B. Tiny and fast, with a thinking mode. The floor: fits machines under 8 GB, such as small VMs.
# --- Daily drivers ---------------------------------------------------------
8|qwen3.5:4b|3.4|dense|daily|yes|Qwen 3.5 4B. Strongest general model under 5 GB. Text and image input.
16|gemma4:12b|7.6|dense|daily|yes|Google Gemma 4 12B. Strong all-rounder for 16 GB machines. Multimodal.
24|gemma4:26b-a4b-it-qat|16|moe|daily|yes|Gemma 4 26B MoE, about 4B active, QAT build. The strong MoE that fits a 24 GB budget.
32|qwen3.6:35b-a3b|23|moe|daily|yes|Qwen 3.6 35B MoE, 3B active. Fast even on a CPU. Multimodal. Needs 32 GB of RAM or more.
# --- Reasoning -------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|reasoning|yes|Qwen 3.5 4B with its thinking mode.
16|gemma4:12b|7.6|dense|reasoning|yes|Gemma 4 12B. Strong maths and reasoning for its size.
24|gemma4:26b-a4b-it-qat|16|moe|reasoning|yes|Gemma 4 26B MoE. Reasoning on machines too slow for a dense 27B.
32|qwen3.8:27b|18|dense|reasoning|yes|Qwen 3.8 27B. Top small open model on independent indexes. Dense: fits a 24 GB GPU; on a CPU only fast memory clears the speed gate. Uses many tokens.
# --- Coding ----------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|coding|yes|Qwen 3.5 4B. Best coding option under 5 GB.
16|qwen3.5:9b|6.6|dense|coding|yes|Qwen 3.5 9B. Stronger agentic coding than Gemma 4 12B.
24|devstral-small-2:24b|15|dense|coding|yes|Mistral Devstral Small 2 24B. Strong agentic coding. Dense: best on a 24 GB GPU.
32|qwen3.6:35b-a3b-coding|23|moe|coding|yes|Qwen 3.6 35B MoE with its coding sampling preset. Same weights as the daily tag.
# --- Vision ----------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|vision|yes|Qwen 3.5 4B. Image input on the smallest machines.
16|gemma4:12b|7.6|dense|vision|yes|Gemma 4 12B. Image input.
24|gemma4:26b-a4b-it-qat|16|moe|vision|yes|Gemma 4 26B MoE. Image input.
32|qwen3.6:35b-a3b|23|moe|vision|yes|Qwen 3.6 35B MoE. Leads Gemma 4 26B on vision evals.
CATALOG_EOF
}

# The catalogue lives in root-owned /etc/llmstack. Writes to it go through
# these helpers. Read-only modes run by a user without sudo (--recommend)
# get a private temporary copy instead, so they never prompt for a password;
# CATALOG then points at that copy and CATALOG_PATH at the real file.
CATALOG_PATH="$CATALOG"
CATALOG_TMP=""

catalog_is_real() { [ "$CATALOG" = "$CATALOG_PATH" ]; }

install_default_catalog() {
  local t; t="$(mktemp)"
  write_default_catalog "$t"
  put_file "$t" "$CATALOG_PATH" 0644
  rm -f "$t"
}

ensure_catalog() {
  [ -f "$CATALOG" ] && return 0
  if config_writable; then
    log "Writing the default model catalogue to $CATALOG_PATH"
    install_default_catalog
    CATALOG="$CATALOG_PATH"
  else
    CATALOG_TMP="$(mktemp)"
    write_default_catalog "$CATALOG_TMP"
    CATALOG="$CATALOG_TMP"
    log "No catalogue at $CATALOG_PATH yet; using the built-in one (installing writes it)."
  fi
}

# Once sudo is available, make the real catalogue exist.
settle_catalog() {
  if ! catalog_is_real; then
    rm -f "$CATALOG_TMP"; CATALOG_TMP=""
    CATALOG="$CATALOG_PATH"
  fi
  if ! as_root test -f "$CATALOG_PATH"; then
    log "Writing the default model catalogue to $CATALOG_PATH"
    install_default_catalog
  fi
}

# Timestamped backup of the real catalogue (a temporary copy needs none).
catalog_backup() {
  catalog_is_real || return 0
  as_root cp "$CATALOG" "${CATALOG}.backup-$(date +%Y%m%d-%H%M%S)"
}

# Move file $1 into place at $2 beside the catalogue: as root for the real
# catalogue, directly for a temporary copy.
catalog_install() {
  if catalog_is_real; then
    put_file "$1" "$2" 0644
    rm -f "$1"
  else
    mv "$1" "$2"
  fi
}


# These lookups feed $(...) assignments, and under `set -o pipefail` a grep
# that matches nothing fails the whole pipeline, which `set -e` then turns
# into a silent exit. "Not found" is a normal answer here, so they always
# succeed and print nothing instead.
catalog_date() {
  [ -f "$CATALOG" ] || return 0
  grep -m1 '^# Last-Updated:' "$CATALOG" 2>/dev/null | awk '{print $3}' || true
}

catalog_generation() {
  [ -f "$CATALOG" ] || return 0
  grep -m1 '^# Catalogue-Generation:' "$CATALOG" 2>/dev/null | awk '{print $3}' || true
}

# True if dotted version $1 is older than $2 (e.g. 3.3.0 < 3.4.0).
_version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = (n > m) ? n : m
    for (i = 1; i <= k; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}

# True when the live catalogue does not descend from the current built-in
# generation: its marker is missing or older.
catalog_predates_builtin() {
  local gen; gen="$(catalog_generation)"
  [ -z "$gen" ] || _version_lt "$gen" "$CATALOG_GENERATION"
}

# Date to days-ago with GNU date.
catalog_age_days() {
  local d cat_epoch now_epoch
  d="$(catalog_date)"
  [ -n "$d" ] || return 0
  cat_epoch="$(date -d "$d" "+%s" 2>/dev/null)" || return 0
  now_epoch="$(date "+%s")"
  echo $(( (now_epoch - cat_epoch) / 86400 ))
}

report_catalog_age() {
  local d age
  d="$(catalog_date)"
  age="$(catalog_age_days)"
  if [ -z "$d" ]; then
    warn "The catalogue has no readable 'Last-Updated:' line."
    echo "    Add one in the form:  # Last-Updated: YYYY-MM-DD"
    return 0
  fi
  if [ -z "$age" ]; then
    warn "Could not parse the catalogue date '$d'. Expected YYYY-MM-DD."
    return 0
  fi
  printf '\nModel catalogue last updated: %s (%s days ago)\n' "$d" "$age"
  if [ "$age" -ge "$CATALOG_STALE_DAYS" ]; then
    printf '\n'
    printf '  This catalogue is over %s days old and is very likely stale.\n' "$CATALOG_STALE_DAYS"
    printf '  Local model releases move fast; better options almost certainly\n'
    printf '  exist now. Review https://ollama.com/library, edit\n'
    printf '  %s, and bump its Last-Updated line.\n' "$CATALOG_PATH"
  elif [ "$age" -ge "$CATALOG_WARN_DAYS" ]; then
    printf '\n'
    printf '  Worth a look. Over %s days old, so newer models may be a\n' "$CATALOG_WARN_DAYS"
    printf '  better fit for this machine. See https://ollama.com/library\n'
  else
    printf '  Recent enough. No action needed.\n'
  fi
  printf '\n'
}

# ===========================================================================
# MODEL REGISTRY VALIDATION & CATALOGUE REFRESH  (from the macOS script)
# ===========================================================================
# All registry access uses the Ollama manifest endpoint. Its behaviour was
# confirmed by direct probe: a live tag returns HTTP 200, a non-existent tag
# returns 404, and no auth handshake is required.
#
#   https://registry.ollama.ai/v2/library/<n>/manifests/<tag>
#
# Every function here is FAIL-SOFT: a network error, timeout, or any status
# other than 200/404 is treated as "unknown" and never changes the live
# catalogue. This keeps --update reliable when the registry is unreachable,
# and keeps CI (which has no registry access) green: --check-models and
# --refresh-catalog both exit 0 even when every probe fails.
REGISTRY_BASE="https://registry.ollama.ai/v2/library"
REGISTRY_ACCEPT="application/vnd.docker.distribution.manifest.v2+json"
# Common size tokens probed when looking for newer variants within a family
# already in the catalogue. Each candidate is manifest-confirmed before it is
# ever proposed, so a wrong guess simply 404s and is discarded.
PROBE_SIZES="1.5b 3b 4b 7b 8b 9b 11b 12b 14b 22b 27b 30b 32b 34b 70b 72b"

# Trim leading/trailing whitespace safely. Never use xargs for this: it
# treats quotes specially and mangles NOTES containing apostrophes.
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Probe one tag. Echoes LIVE, DEAD, or UNKNOWN.
registry_probe() {
  local tag="$1" name ver code
  name="${tag%%:*}"
  ver="${tag##*:}"
  if [ "$name" = "$ver" ]; then echo "UNKNOWN"; return 0; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Accept: ${REGISTRY_ACCEPT}" \
    "${REGISTRY_BASE}/${name}/manifests/${ver}" 2>/dev/null || echo "000")"
  case "$code" in
    200) echo "LIVE" ;;
    404) echo "DEAD" ;;
    *)   echo "UNKNOWN" ;;
  esac
}

# True if the registry is reachable at all (one cheap probe of a known tag).
registry_reachable() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Accept: ${REGISTRY_ACCEPT}" \
    "${REGISTRY_BASE}/llama3.3/manifests/70b" 2>/dev/null || echo "000")"
  [ "$code" = "200" ] || [ "$code" = "404" ]
}

# Unique family prefixes (text before the colon) from the live catalogue.
catalog_families() {
  [ -f "$CATALOG" ] || return 0
  grep -v '^#' "$CATALOG" | grep -v '^$' \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); split($2,a,":"); print a[1]}' \
    | sort -u || true
}

# All tags currently in the catalogue, one per line, trimmed.
catalog_tags() {
  [ -f "$CATALOG" ] || return 0
  grep -v '^#' "$CATALOG" | grep -v '^$' \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' || true
}

# ---------------------------------------------------------------------------
# Part A: validate every catalogue tag against the registry.
# Reports LIVE/DEAD/UNKNOWN. With argument "fix", rewrites the live catalogue
# in place to correct the VERIFIED column (200 -> yes, 404 -> no), preserving
# every other column, after taking a timestamped backup. UNKNOWN never
# changes anything. Always returns 0 (fail-soft).
# ---------------------------------------------------------------------------
validate_catalog_tags() {
  local fix="${1:-report}"
  ensure_catalog
  if ! registry_reachable; then
    warn "Cannot reach the Ollama registry. Skipping tag validation."
    echo "    The existing catalogue is unchanged; this is not an error."
    return 0
  fi
  local live=0 dead=0 unknown=0 changed=0 tmp
  tmp="$(mktemp)"
  log "Validating catalogue tags against the Ollama registry"
  while IFS= read -r rawline; do
    case "$rawline" in
      '#'*|'') printf '%s\n' "$rawline" >> "$tmp"; continue ;;
    esac
    local ram tag size arch role ver notes status trimtag
    IFS='|' read -r ram tag size arch role ver notes <<< "$rawline"
    trimtag="$(_trim "$tag")"
    status="$(registry_probe "$trimtag")"
    case "$status" in
      LIVE)
        live=$((live+1)); ok "  LIVE  $trimtag"
        if [ "$(_trim "$ver")" != "yes" ]; then ver="yes"; changed=$((changed+1)); fi
        ;;
      DEAD)
        dead=$((dead+1)); warn "  DEAD  $trimtag  (404 — retired or renamed)"
        if [ "$(_trim "$ver")" != "no" ]; then ver="no"; changed=$((changed+1)); fi
        ;;
      *)
        unknown=$((unknown+1)); printf '  ????  %s  (registry unreachable for this tag)\n' "$trimtag"
        ;;
    esac
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$(_trim "$ram")" "$trimtag" "$(_trim "$size")" "$(_trim "$arch")" \
      "$(_trim "$role")" "$(_trim "$ver")" "$(_trim "$notes")" >> "$tmp"
  done < "$CATALOG"
  printf '\nValidation summary: %d live, %d dead, %d unknown.\n' "$live" "$dead" "$unknown"
  if [ "$fix" = "fix" ] && [ "$changed" -gt 0 ]; then
    catalog_backup
    catalog_install "$tmp" "$CATALOG"
    ok "Corrected the VERIFIED column on $changed entries. Backup kept."
  else
    rm -f "$tmp"
    if [ "$dead" -gt 0 ]; then
      echo "Run --refresh-catalog to produce a cleaned proposal you can review."
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Part B-lite: probe common tag patterns within each catalogue family for
# variants not already present. Registry-only; every hit is manifest-
# confirmed. Echoes confirmed new "family:tag" candidates, one per line.
# ---------------------------------------------------------------------------
probe_family_variants() {
  local families existing fam base suffix cand
  families="$(catalog_families)"
  existing="$(catalog_tags)"
  for fam in $families; do
    for base in $PROBE_SIZES; do
      for suffix in "" "-instruct"; do
        cand="${fam}:${base}${suffix}"
        printf '%s\n' "$existing" | grep -qx "$cand" && continue
        if [ "$(registry_probe "$cand")" = "LIVE" ]; then
          printf '%s\n' "$cand"
        fi
      done
    done
  done
}

# ---------------------------------------------------------------------------
# Part B-full (optional, --discover): scrape ollama.com/library for family
# names not in the catalogue. FRAGILE (HTML), so wholly fail-soft: any
# failure yields no candidates and a note, never an error. Every scraped
# name is manifest-confirmed before being emitted.
# ---------------------------------------------------------------------------
discover_new_families() {
  local html names fam known
  html="$(curl -s --max-time 15 "https://ollama.com/library" 2>/dev/null || true)"
  if [ -z "$html" ]; then
    warn "Could not fetch the library index; skipping discovery." >&2
    echo "    Proposal is based on validated tags and the family watchlist." >&2
    return 0
  fi
  names="$(printf '%s' "$html" \
    | grep -oE 'href="/library/[a-zA-Z0-9._-]+"' \
    | sed -E 's#href="/library/([^"]+)"#\1#' \
    | sort -u)"
  known="$(catalog_families)"
  for fam in $names; do
    printf '%s\n' "$known" | grep -qx "$fam" && continue
    if [ "$(registry_probe "${fam}:latest")" = "LIVE" ]; then
      printf '%s\n' "$fam"
    fi
  done
}

# ---------------------------------------------------------------------------
# Part B/C core: build models.catalog.proposed next to the live file.
#   - Walks the live file IN ORDER. Comments and blank lines pass through
#     untouched, so section headings keep their rows. (Up to macOS v3.5.0 every
#     comment was hoisted to the top, and each refresh degraded the file.)
#   - Re-validates every data row in place: VERIFIED corrected, judgment
#     columns MIN_RAM/ARCH/ROLE/NOTES preserved, dead tags commented out.
#   - New candidates (family variants; with $1 = "discover", new families)
#     are appended as commented "# REVIEW:" lines, never as live rows, and
#     a candidate already suggested that way is not suggested again.
#   - Leaves Last-Updated alone: that line records human review, which a
#     proposal is not. apply_catalog_proposal stamps it on confirmation.
# Never touches the live catalogue. Returns 0.
# ---------------------------------------------------------------------------
REVIEW_HEADER="# --- Suggested by --refresh-catalog: set every REVIEW field, then delete '# REVIEW: ' ---"
PROPOSAL_BUILT="no"

build_catalog_proposal() {
  local discover="${1:-no}"
  ensure_catalog
  local proposed="${CATALOG}.proposed"
  if ! registry_reachable; then
    warn "Cannot reach the Ollama registry. No proposal was written."
    echo "    Try again when the network can reach registry.ollama.ai."
    return 0
  fi
  log "Building a catalogue proposal (live file is not touched)"
  local tmp; tmp="$(mktemp)"
  local live=0 dead=0 added=0 rawline ram tag size arch role ver notes trimtag status
  while IFS= read -r rawline || [ -n "$rawline" ]; do
    case "$rawline" in
      '#'*|'') printf '%s\n' "$rawline" >> "$tmp"; continue ;;
    esac
    IFS='|' read -r ram tag size arch role ver notes <<< "$rawline"
    trimtag="$(_trim "$tag")"
    status="$(registry_probe "$trimtag")"
    ram="$(_trim "$ram")"; size="$(_trim "$size")"; arch="$(_trim "$arch")"
    role="$(_trim "$role")"; notes="$(_trim "$notes")"
    case "$status" in
      LIVE) live=$((live+1))
        printf '%s|%s|%s|%s|%s|yes|%s\n' "$ram" "$trimtag" "$size" "$arch" "$role" "$notes" >> "$tmp" ;;
      DEAD) dead=$((dead+1))
        printf '# DEAD (404 at registry, review/remove): %s|%s|%s|%s|%s|no|%s\n' \
          "$ram" "$trimtag" "$size" "$arch" "$role" "$notes" >> "$tmp" ;;
      *)  # unknown: pass through unchanged
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$ram" "$trimtag" "$size" "$arch" "$role" "$(_trim "$ver")" "$notes" >> "$tmp" ;;
    esac
  done < "$CATALOG"

  local cands="" fams fam cand
  cands="$(probe_family_variants)"
  if [ "$discover" = "discover" ]; then
    fams="$(discover_new_families)"
    while IFS= read -r fam; do
      [ -n "$fam" ] && cands="${cands}"$'\n'"${fam}:latest"
    done <<< "$fams"
  fi
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # Suggested by an earlier refresh and not yet acted on: don't repeat it.
    grep -qF "# REVIEW: REVIEW|${cand}|" "$CATALOG" && continue
    grep -qxF "$REVIEW_HEADER" "$tmp" || printf '%s\n' "$REVIEW_HEADER" >> "$tmp"
    printf '# REVIEW: REVIEW|%s|REVIEW|REVIEW|REVIEW|yes|Confirmed in the registry. Set MIN_RAM, SIZE, ARCH, ROLE and NOTES.\n' \
      "$cand" >> "$tmp"
    added=$((added+1))
  done <<< "$cands"

  catalog_install "$tmp" "$proposed"
  PROPOSAL_BUILT="yes"
  printf '\n'
  ok "Wrote proposal: $proposed"
  printf 'Summary: %d live, %d dead, %d new suggestion(s) added as "# REVIEW:" comments.\n' "$live" "$dead" "$added"
  printf '\nSuggestions never become live rows on their own: set every REVIEW\n'
  printf 'field and delete the leading "# REVIEW: " to adopt one.\n'
  printf '\nCompare against the live file:\n'
  printf '  diff "%s" "%s"\n' "$CATALOG" "$proposed"
  printf 'Apply it with --refresh-catalog-apply, or by hand:\n'
  printf '  sudo mv "%s" "%s"\n\n' "$proposed" "$CATALOG"
  return 0
}

# ---------------------------------------------------------------------------
# Part C: apply the proposal over the live catalogue, after backup + confirm.
# Only a proposal built in this run is applied: a leftover .proposed file
# from an earlier run (e.g. when the registry is now unreachable) is not.
# Confirming the diff is a human review, so Last-Updated is stamped here.
# ---------------------------------------------------------------------------
apply_catalog_proposal() {
  local discover="${1:-no}"
  build_catalog_proposal "$discover"
  local proposed="${CATALOG}.proposed"
  if [ "$PROPOSAL_BUILT" != "yes" ] || [ ! -f "$proposed" ]; then
    warn "No new proposal was built, so nothing was applied."
    return 0
  fi
  printf '\n'
  diff "$CATALOG" "$proposed" || true
  printf '\n'
  if confirm "Replace the live catalogue with this proposal?"; then
    local dated; dated="$(mktemp)"
    catalog_backup
    sed "s/^# Last-Updated:.*/# Last-Updated: $(date +%Y-%m-%d)/" "$proposed" > "$dated"
    catalog_install "$dated" "$CATALOG"
    if catalog_is_real; then as_root rm -f "$proposed"; else rm -f "$proposed"; fi
    ok "Catalogue updated and Last-Updated set to today. Backup kept alongside it."
  else
    log "Left the live catalogue unchanged. Proposal remains at $proposed"
  fi
  return 0
}


# ===========================================================================
# SYSTEM DETECTION
# ===========================================================================
# Reads /etc/os-release without sourcing it (it is data, not a script).
os_field() {
  awk -F= -v k="$1" '$1 == k { v = $2; gsub(/^"|"$/, "", v); print v; exit }' "$HW_ROOT/etc/os-release" 2>/dev/null || true
}

detect_os() {
  OS_ID="$(os_field ID)"
  OS_VERSION="$(os_field VERSION_ID)"
  OS_NAME="$(os_field PRETTY_NAME)"; [ -n "$OS_NAME" ] || OS_NAME="unknown"
  OS_CODENAME="$(os_field UBUNTU_CODENAME)"; [ -n "$OS_CODENAME" ] || OS_CODENAME="$(os_field VERSION_CODENAME)"
  case "$(uname -m)" in
    x86_64)        ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)             ARCH="unsupported" ;;
  esac
}

os_supported() {
  [ "$OS_ID" = "ubuntu" ] || return 1
  case " $SUPPORTED_UBUNTU " in *" $OS_VERSION "*) return 0 ;; esac
  return 1
}

# Marketing name for a PCI slot via lspci when available, else a fallback.
gpu_name() {
  local slot="$1" fallback="$2" n=""
  if command -v lspci >/dev/null 2>&1; then
    n="$(lspci -s "$slot" 2>/dev/null | sed -e 's/^[^ ]* [^:]*: //' -e 's/ (rev [0-9a-f]*)$//' | head -1)" || n=""
  fi
  printf '%s' "${n:-$fallback}"
}

# Fills GPUS with one line per GPU:  vendor|name|vram_mib|kind|runtime
#   kind:    discrete | integrated | unsized
#   runtime: ok (NVIDIA driver working) | no-driver | rocm | vulkan | none
# NVIDIA rows come from nvidia-smi when its driver works (exact VRAM);
# everything else from sysfs, which needs neither root nor lspci.
detect_gpus() {
  GPUS=""
  local nv_rows="" nv_ok="no" c dev vendor class slot name vram kind rt
  if command -v nvidia-smi >/dev/null 2>&1; then
    if nv_rows="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null)" && [ -n "$nv_rows" ]; then
      nv_ok="yes"
    fi
  fi
  if [ "$nv_ok" = "yes" ]; then
    while IFS=, read -r name vram; do
      name="$(_trim "$name")"; vram="$(_trim "$vram")"
      [ -n "$name" ] || continue
      GPUS="${GPUS}nvidia|${name}|${vram%%.*}|discrete|ok"$'\n'
    done <<< "$nv_rows"
  fi
  for c in "$HW_ROOT"/sys/class/drm/card*; do
    [ -e "$c" ] || continue
    case "${c##*/}" in *-*) continue ;; esac    # connectors, not devices
    dev="$c/device"
    class="$(cat "$dev/class" 2>/dev/null || true)"
    case "$class" in 0x03*) ;; *) continue ;; esac
    vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
    slot="$(basename "$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")")"
    case "$vendor" in
      0x10de)
        # With a working driver nvidia-smi already listed these.
        [ "$nv_ok" = "yes" ] && continue
        GPUS="${GPUS}nvidia|$(gpu_name "$slot" "NVIDIA GPU")|0|discrete|no-driver"$'\n' ;;
      0x1002)
        vram="$(cat "$dev/mem_info_vram_total" 2>/dev/null || echo 0)"
        vram=$(( vram / 1048576 ))
        # A small carve-out is an APU's integrated GPU, not a card.
        if [ "$vram" -lt 2048 ]; then kind="integrated"; else kind="discrete"; fi
        if [ -e "$HW_ROOT/dev/kfd" ]; then rt="rocm"
        elif compgen -G "$HW_ROOT/usr/share/vulkan/icd.d/radeon_icd*.json" >/dev/null; then rt="vulkan"
        else rt="none"; fi
        GPUS="${GPUS}amd|$(gpu_name "$slot" "AMD GPU")|${vram}|${kind}|${rt}"$'\n' ;;
      0x8086)
        # No reliable VRAM source for Intel (i915/xe expose none in sysfs),
        # so Intel GPUs never size the picks; --benchmark measures instead.
        GPUS="${GPUS}intel|$(gpu_name "$slot" "Intel GPU")|0|unsized|vulkan"$'\n' ;;
    esac
  done
}

# The largest single discrete GPU with a usable runtime sizes the picks:
# Ollama keeps a model on one GPU when it fits there.
select_pool() {
  POOL_KIND="cpu"; POOL_GPU=""; POOL_VRAM_MIB=0
  local v n m k r
  while IFS='|' read -r v n m k r; do
    [ -n "$v" ] || continue
    [ "$k" = "discrete" ] || continue
    case "$v:$r" in nvidia:ok|amd:rocm|amd:vulkan) ;; *) continue ;; esac
    if [ "$m" -gt "$POOL_VRAM_MIB" ]; then
      POOL_VRAM_MIB="$m"; POOL_GPU="$n"
    fi
  done <<< "$GPUS"
  if [ "$POOL_VRAM_MIB" -gt 0 ]; then POOL_KIND="gpu"; fi
}

# Highest configured DIMM speed in MT/s from udev's DMI data (no root
# needed), or empty. systemd's dmi_memory_id fills MEMORY_DEVICE_* keys.
ram_speed_mts() {
  local s
  s="$(udevadm info -e 2>/dev/null | awk -F= '/MEMORY_DEVICE_[0-9]+_CONFIGURED_SPEED_MTS=/ { print $2 }' | sort -n | tail -1)" || s=""
  if [ -z "$s" ]; then
    s="$(udevadm info -e 2>/dev/null | awk -F= '/MEMORY_DEVICE_[0-9]+_SPEED_MTS=/ { print $2 }' | sort -n | tail -1)" || s=""
  fi
  case "$s" in ''|*[!0-9]*) s="" ;; esac
  printf '%s' "$s"
}

detect_system() {
  detect_os
  local memkb mts
  SYS_CPU="$(awk -F: '/^model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' "$HW_ROOT/proc/cpuinfo" 2>/dev/null || true)"
  [ -n "$SYS_CPU" ] || SYS_CPU="unknown CPU"
  SYS_CORES="$(nproc 2>/dev/null || echo '?')"
  memkb="$(awk '/^MemTotal:/ { print $2; exit }' "$HW_ROOT/proc/meminfo" 2>/dev/null || true)"
  case "$memkb" in ''|*[!0-9]*) memkb=0 ;; esac
  # MemTotal is a little under the installed size; round to nearest GiB.
  SYS_RAM_GB=$(( (memkb + 524288) / 1048576 ))
  [ "$SYS_RAM_GB" -gt 0 ] || SYS_RAM_GB=8
  SYS_DISK_FREE_GB="$(df -BG /usr/share 2>/dev/null | awk 'NR == 2 { gsub(/G/, "", $4); print $4 }')" || SYS_DISK_FREE_GB=""
  [ -n "$SYS_DISK_FREE_GB" ] || SYS_DISK_FREE_GB=0
  detect_gpus
  select_pool
  if [ "$POOL_KIND" = "gpu" ]; then
    SYS_BUDGET_GB="$(awk -v m="$POOL_VRAM_MIB" -v p="$VRAM_BUDGET_PCT" 'BEGIN { printf "%.1f", m / 1024 * p / 100 }')"
    SYS_DENSE_CAP_GB=""
    SYS_BANDWIDTH=""
    SYS_CHIP="$POOL_GPU, $(awk -v m="$POOL_VRAM_MIB" 'BEGIN { printf "%.0f", m / 1024 }') GB VRAM"
  else
    SYS_BUDGET_GB="$(awk -v r="$SYS_RAM_GB" -v p="$RAM_BUDGET_PCT" 'BEGIN { printf "%.1f", r * p / 100 }')"
    mts="$(ram_speed_mts)"
    if [ -n "$mts" ]; then RAM_MTS="$mts"; RAM_MTS_SOURCE="read from DMI"
    else RAM_MTS="$DEFAULT_RAM_MTS"; RAM_MTS_SOURCE="assumed; DIMM speed unreadable"; fi
    SYS_BANDWIDTH="$(awk -v s="$RAM_MTS" -v c="$ASSUMED_CHANNELS" 'BEGIN { printf "%.0f", s * 8 * c / 1000 }')"
    SYS_DENSE_CAP_GB="$(awk -v bw="$SYS_BANDWIDTH" -v eff="$DENSE_EFFICIENCY_PCT" -v tps="$DENSE_MIN_TPS" 'BEGIN { printf "%.1f", bw * eff / 100 / tps }')"
    SYS_CHIP="CPU, ${SYS_RAM_GB} GB RAM"
  fi
}

# Within each role, the largest entry passing all three gates wins:
#   1. size fits the budget (VRAM share on a GPU, RAM share otherwise)
#   2. system RAM >= MIN_RAM_GB (machine class; RAM even when a GPU sizes)
#   3. dense entries only, and only without a discrete GPU: generation at
#      DENSE_MIN_TPS or better from estimated RAM bandwidth. MoE is exempt.
best_for_role() {
  local role="$1"
  [ -f "$CATALOG" ] || return 0
  # OFS="|" so that trimming a field rebuilds $0 with pipes, not spaces.
  awk -F'|' -v OFS='|' -v budget="$SYS_BUDGET_GB" -v ram="$SYS_RAM_GB" -v want="$role" \
      -v cap="${SYS_DENSE_CAP_GB:-}" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      gsub(/^[ \t]+|[ \t]+$/, "", $4)
      gsub(/^[ \t]+|[ \t]+$/, "", $5)
      # Unreviewed rows (e.g. MIN_RAM or SIZE still "REVIEW") are never picked.
      if ($1 !~ /^[0-9.]+$/ || $3 !~ /^[0-9.]+$/) next
      if ($4 == "dense" && cap != "" && ($3 + 0) > (cap + 0)) next
      if ($5 == want && ($1 + 0) <= ram && ($3 + 0) <= (budget + 0) && ($3 + 0) > best) {
        best = $3 + 0
        line = $0
      }
    }
    END { if (line != "") print line }
  ' "$CATALOG"
}

field() { echo "$1" | awk -F'|' -v n="$2" '{gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n}'; }

gpu_runtime_text() {
  case "$1:$2" in
    nvidia:ok)        echo "driver working" ;;
    nvidia:no-driver) echo "NO DRIVER (nvidia-smi not working)" ;;
    amd:rocm)         echo "ROCm (/dev/kfd present)" ;;
    amd:vulkan)       echo "Vulkan driver present" ;;
    amd:none)         echo "no ROCm or Vulkan driver found" ;;
    intel:*)          echo "Vulkan only; VRAM not readable" ;;
    *)                echo "$2" ;;
  esac
}

print_system_report() {
  local v n m k r size
  printf '  OS:                %s (%s)' "$OS_NAME" "$ARCH"
  if os_supported; then printf '\n'; else printf '  %sunsupported: this script targets Ubuntu %s%s\n' "$C_YELLOW" "${SUPPORTED_UBUNTU// / and }" "$C_RESET"; fi
  printf '  CPU:               %s (%s threads)\n' "$SYS_CPU" "$SYS_CORES"
  printf '  System RAM:        %s GB\n' "$SYS_RAM_GB"
  printf '  Free disk:         %s GB (for models, under /usr/share)\n' "$SYS_DISK_FREE_GB"
  if [ -z "$GPUS" ]; then
    printf '  GPUs:              none found\n'
  else
    printf '  GPUs:\n'
    while IFS='|' read -r v n m k r; do
      [ -n "$v" ] || continue
      if [ "$m" -gt 0 ]; then size="$(awk -v m="$m" 'BEGIN { printf "%.1f GB", m / 1024 }')"; else size="VRAM unknown"; fi
      printf '    - %s  [%s, %s]  %s\n' "$n" "$k" "$size" "$(gpu_runtime_text "$v" "$r")"
    done <<< "$GPUS"
  fi
  if [ "$POOL_KIND" = "gpu" ]; then
    printf '  Sizing:            GPU %s: %s%% of %s GB VRAM = ~%s GB for model weights\n' \
      "$POOL_GPU" "$VRAM_BUDGET_PCT" "$(awk -v m="$POOL_VRAM_MIB" 'BEGIN { printf "%.0f", m / 1024 }')" "$SYS_BUDGET_GB"
    printf '                     No dense-speed cap: a model that fits in VRAM runs fast.\n'
  else
    printf '  Sizing:            CPU and RAM: %s%% of %s GB = ~%s GB for model weights\n' "$RAM_BUDGET_PCT" "$SYS_RAM_GB" "$SYS_BUDGET_GB"
    printf '  RAM bandwidth:     ~%s GB/s (DDR %s MT/s, %s; %s channels assumed)\n' "$SYS_BANDWIDTH" "$RAM_MTS" "$RAM_MTS_SOURCE" "$ASSUMED_CHANNELS"
    printf '  Dense model cap:   ~%s GB  (keeps dense models at %s tok/s or better; MoE exempt)\n' "$SYS_DENSE_CAP_GB" "$DENSE_MIN_TPS"
  fi
  case "$GPUS" in *"|no-driver"*)
    printf '\n  %sAn NVIDIA GPU has no working driver, so it is not used for sizing.%s\n' "$C_YELLOW" "$C_RESET"
    printf '  Install one with:  sudo ubuntu-drivers install   (then reboot),\n'
    printf '  or re-run the installer with --nvidia-driver install.\n' ;;
  esac
  case "$GPUS" in *"amd|"*"|none"*)
    printf '\n  An AMD GPU has no ROCm or Vulkan driver. ROCm 7 is supported by AMD on\n'
    printf '  Ubuntu 24.04; on 26.04 use Vulkan (mesa-vulkan-drivers).\n' ;;
  esac
  case "$GPUS" in *"intel|"*)
    printf '\n  Intel GPUs run through Vulkan only, and their VRAM cannot be read, so\n'
    printf '  they never size the picks. Integrated GPUs also need OLLAMA_IGPU_ENABLE=1.\n'
    printf '  Use --benchmark after installing to see real speed.\n' ;;
  esac
}

# ===========================================================================
# SYNC MODELS
# ===========================================================================
# Brings installed Ollama models in line with the recommendations. Order is
# the safety property: every chosen pull must succeed before anything is
# removed, so a failed or interrupted run never leaves fewer models than it
# started with. Every change needs a yes; every prompt defaults to no.
#
# Prompts read from stdin, so loops that prompt iterate over fd 3 instead;
# a plain `while read ... done <<< list` would feed the list to confirm().

# "name" and "name:latest" are the same model to Ollama.
_model_norm() { case "$1" in *:*) printf '%s' "$1" ;; *) printf '%s:latest' "$1" ;; esac; }

# True if the newline-separated list $1 contains the exact line $2.
_has_line() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

# True if `ollama show` lists an embedding capability. Fail-soft: an Ollama
# without a Capabilities section simply reports false.
_is_embedding_model() {
  ollama show "$1" 2>/dev/null \
    | awk 'tolower($0) ~ /capabilities/ { f = 1; next } f && /^[[:space:]]*$/ { f = 0 } f' \
    | grep -qi 'embedding'
}

_sha256() { sha256sum "$1" | awk '{ print $1 }'; }

# The ID `ollama list` shows for a model is the first 12 hex digits of the
# SHA-256 of its local manifest, and the registry serves that manifest byte
# for byte (verified on a real macOS install; Ollama stores models the
# same way on Linux). So an installed build
# is outdated exactly when its ID differs from the SHA-256 of the manifest
# the registry now serves - one small request, no download.
# Echoes those 12 digits, or nothing if the manifest could not be fetched.
_registry_manifest_id() {
  local t="$1" f
  f="$(mktemp)"
  if curl -s -f --max-time 15 -H "Accept: ${REGISTRY_ACCEPT}" \
       "${REGISTRY_BASE}/${t%%:*}/manifests/${t##*:}" -o "$f" 2>/dev/null && [ -s "$f" ]; then
    _sha256 "$f" | cut -c1-12
  fi
  rm -f "$f"
}

sync_models() {
  local listing inst="" m gen role line rows="" picks picktags sel="" cands=""
  local tag size arch roles st need sz pulled="" updated="" failed="" removed="" kept=""
  local states="" reachable="no" lid rid kind
  detect_system
  ensure_catalog
  cat <<'SYNCHDR'
===========================================================================
  SYNC MODELS
===========================================================================
  Pulls the recommended models you choose, then offers each installed
  model that is not a current pick for removal. Nothing is removed until
  every chosen pull has succeeded. All prompts default to NO.
===========================================================================
SYNCHDR

  # 1. The daemon must be up: both pull and rm go through it.
  if ! listing="$(ollama list 2>/dev/null)"; then
    error "Cannot reach Ollama. Start the stack (llmstart), then re-run. Nothing was changed."
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    inst="${inst}$(_model_norm "$m")"$'\n'
  done <<EOF_LIST
$(printf '%s\n' "$listing" | awk 'NR > 1 && NF { print $1 }')
EOF_LIST

  # 2. A catalogue that does not descend from the current built-in one
  # hides newer models from the picks. Judged by the Catalogue-Generation
  # marker, not Last-Updated: that date records review, and refresh tooling
  # before v3.5.1 stamped it on every proposal.
  if catalog_predates_builtin; then
    gen="$(catalog_generation)"
    if [ -z "$gen" ]; then
      printf '\nYour model catalogue has no Catalogue-Generation line, so it predates\n'
      printf 'the generation %s catalogue built into this script, or was built by hand.\n' "$CATALOG_GENERATION"
    else
      printf '\nYour model catalogue is generation %s; this script ships generation %s.\n' "$gen" "$CATALOG_GENERATION"
    fi
    echo "    Picks come from your catalogue, so newer models will not appear"
    echo "    until it is replaced. Replacing it keeps a timestamped backup;"
    echo "    copy any rows you added by hand back from that file afterwards."
    echo "    If you maintain your own catalogue on purpose, answer no and add"
    echo "    this line to it to stop being asked:"
    echo "      # Catalogue-Generation: $CATALOG_GENERATION"
    if confirm "Back up your catalogue and replace it with the built-in one?"; then
      catalog_backup
      install_default_catalog
      ok "Catalogue replaced. Backup kept alongside it."
    else
      log "Keeping your catalogue."
    fi
  fi

  # 3. Current picks, one line per unique tag with every role it serves.
  for role in daily reasoning coding vision light; do
    line="$(best_for_role "$role")"
    [ -n "$line" ] || continue
    rows="${rows}$(_model_norm "$(field "$line" 2)")|$(field "$line" 3)|$(field "$line" 4)|${role}"$'\n'
  done
  picks="$(printf '%s' "$rows" | awk -F'|' '
    NF < 4 { next }
    !($1 in r) { order[++n] = $1; size[$1] = $2; arch[$1] = $3; r[$1] = $4; next }
    { r[$1] = r[$1] ", " $4 }
    END { for (i = 1; i <= n; i++) print order[i] "|" size[order[i]] "|" arch[order[i]] "|" r[order[i]] }')"
  if [ -z "$picks" ]; then
    warn "Nothing in the catalogue fits this machine, so there is nothing to sync."
    echo "    Run --recommend for details."
    exit 0
  fi
  picktags="$(printf '%s\n' "$picks" | cut -d'|' -f1)"

  # An installed pick may be an old build of its tag: compare manifest
  # digests with the registry (one reachability probe first, so an offline
  # machine does not wait out a timeout per pick). Fail-soft: unreachable
  # means "unchecked", never an error.
  if registry_reachable; then reachable="yes"; fi
  printf '\nCurrent picks for this machine (%s):\n' "$SYS_CHIP"
  while IFS='|' read -r tag size arch roles; do
    [ -n "$tag" ] || continue
    if ! _has_line "$inst" "$tag"; then
      st="not installed"
    elif [ "$reachable" != "yes" ]; then
      st="unchecked"
    else
      lid="$(printf '%s\n' "$listing" | awk -v m="$tag" 'NR > 1 { n = $1; if (n !~ /:/) n = n ":latest"; if (n == m) { print $2; exit } }')"
      rid="$(_registry_manifest_id "$tag")"
      if [ -z "$rid" ] || [ -z "$lid" ]; then st="unchecked"
      elif [ "$rid" = "$lid" ]; then st="current"
      else st="outdated"
      fi
    fi
    states="${states}${tag}|${st}"$'\n'
    printf '  %-30s %6s GB  %-5s  %-13s  %s\n' "$tag" "$size" "$arch" "$st" "$roles"
  done <<< "$picks"
  if [ "$reachable" != "yes" ]; then
    printf '  (Registry unreachable: installed picks were not checked for newer builds.)\n'
  fi

  # 4. Choose which missing picks to pull and which outdated ones to update.
  while IFS='|' read -r tag size arch roles <&3; do
    [ -n "$tag" ] || continue
    st="$(printf '%s' "$states" | awk -F'|' -v t="$tag" '$1 == t { print $2; exit }')"
    case "$st" in
      "not installed")
        if confirm "Pull $tag (about $size GB) for: $roles?"; then
          sel="${sel}${tag}|${size}|pull"$'\n'
        fi ;;
      outdated)
        if confirm "Update $tag for: $roles? Your build is older than the registry's (download up to $size GB)."; then
          sel="${sel}${tag}|${size}|update"$'\n'
        fi ;;
    esac
  done 3<<< "$picks"

  # Removal candidates: installed, and not any role's current pick. A pick
  # you declined to pull stays a pick, so it is never offered for removal.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    _has_line "$picktags" "$m" || cands="${cands}${m}"$'\n'
  done <<< "$inst"

  if [ -z "$sel" ] && [ -z "$cands" ]; then
    printf '\nNothing to do: no pulls or updates chosen and no other models installed.\n\n'
    exit 0
  fi

  # 5. Old and new models coexist until the removals, so check up front.
  if [ -n "$sel" ]; then
    # Updates count at full size: Ollama fetches the new layers before it
    # drops the old ones.
    need="$(printf '%s' "$sel" | awk -F'|' 'NF { s += $2 } END { printf "%d", s + 10.999 }')"
    if awk -v f="$SYS_DISK_FREE_GB" -v w="$need" 'BEGIN { exit !(f + 0 < w + 0) }'; then
      warn "Only ${SYS_DISK_FREE_GB} GB free; the chosen downloads need about ${need} GB including 10 GB headroom."
      echo "    Nothing was changed. To free space first, run --sync-models again,"
      echo "    decline every pull, and answer yes to the removals you want."
      exit 1
    fi
  fi

  # 6. Pull everything chosen before removing anything.
  if [ -n "$sel" ]; then
    trap 'warn "Pull interrupted. Nothing was removed. Re-run to resume the download."; exit 1' INT
    while IFS='|' read -r tag size kind <&3; do
      [ -n "$tag" ] || continue
      log "Pulling $tag (about $size GB). Large downloads take a while."
      if ollama pull "$tag"; then
        if [ "$kind" = "update" ]; then
          updated="${updated}${tag}"$'\n'
        else
          pulled="${pulled}${tag}"$'\n'
        fi
        ok "Pulled $tag"
      else
        failed="${failed}${tag}"$'\n'
        warn "The pull failed for $tag"
      fi
    done 3<<< "$sel"
    trap - INT
    if [ -n "$failed" ]; then
      warn "Some pulls failed, so no models were removed:"
      printf '%s' "$failed" | sed 's/^/      /'
      echo "    Check the tag at https://ollama.com/library and your network, then re-run."
      exit 1
    fi
  fi

  # 7. Offer each non-pick for removal, one at a time.
  if [ -n "$cands" ]; then
    printf '\n%s installed model(s) are not a current pick. Each is offered\n' "$(printf '%s' "$cands" | grep -c .)"
    printf 'for removal separately; pressing Enter keeps it.\n'
    while IFS= read -r m <&3; do
      [ -n "$m" ] || continue
      sz="$(printf '%s\n' "$listing" | awk -v m="$m" 'NR > 1 { n = $1; if (n !~ /:/) n = n ":latest"; if (n == m) { print $3 " " $4; exit } }')"
      printf '\n  %s  (%s)\n' "$m" "${sz:-size unknown}"
      if _is_embedding_model "$m"; then
        printf '  %sEmbedding model.%s Open WebUI may use it for document search;\n' "$C_YELLOW" "$C_RESET"
        printf '  removing it can break uploads and knowledge collections.\n'
      fi
      if confirm "Remove $m?"; then
        if ollama rm "$m" >/dev/null; then
          removed="${removed}${m}"$'\n'
          ok "Removed $m"
        else
          kept="${kept}${m}"$'\n'
          warn "Could not remove $m"
        fi
      else
        kept="${kept}${m}"$'\n'
      fi
    done 3<<< "$cands"
  fi

  # 8. Summary.
  cat <<'SYNCDONE'

===========================================================================
  SYNC COMPLETE
===========================================================================
SYNCDONE
  printf '  Pulled:\n';  if [ -n "$pulled" ];  then printf '%s' "$pulled"  | sed 's/^/    /'; else echo "    (none)"; fi
  printf '  Updated:\n'; if [ -n "$updated" ]; then printf '%s' "$updated" | sed 's/^/    /'; else echo "    (none)"; fi
  printf '  Removed:\n'; if [ -n "$removed" ]; then printf '%s' "$removed" | sed 's/^/    /'; else echo "    (none)"; fi
  printf '  Kept, not a current pick:\n'; if [ -n "$kept" ]; then printf '%s' "$kept" | sed 's/^/    /'; else echo "    (none)"; fi
  if [ -n "$removed" ]; then
    echo ""
    echo "  If a removed model was the default in Open WebUI, choose a new"
    echo "  default there. Existing chats remain readable."
  fi
  echo "==========================================================================="
  echo ""
}


# ===========================================================================
# STATUS (shared by --status and the llmstatus command)
# ===========================================================================
# One block of shell, eval'd here and written verbatim into llmstatus, so
# the two can never drift. The config is read at call time.
# shellcheck disable=SC2016
STATUS_BODY='
_llmstack_conf() {
  WEBUI_RUNTIME="docker"
  SEARXNG_MODE="local"
  SEARXNG_URL="http://127.0.0.1:8888"
  WEBUI_PORT="8080"
  _cfg="${LLMSTACK_CONFIG_DIR:-/etc/llmstack}/config"
  if [ -r "$_cfg" ]; then
    . "$_cfg"
  fi
}
_llmstack_status() {
  _llmstack_conf
  local o w s u
  if curl -s -o /dev/null --max-time 3 http://127.0.0.1:11434/api/version; then o="UP"; else o="DOWN"; fi
  if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${WEBUI_PORT}"; then w="UP"; else w="DOWN"; fi
  if curl -s -o /dev/null --max-time 5 "${SEARXNG_URL}/search?q=test&format=json"; then s="UP"; else s="DOWN"; fi
  u="$(systemctl is-active ollama 2>/dev/null || true)"
  printf "Ollama      (:11434)   %-4s  systemd: %s\n" "$o" "${u:-unknown}"
  if [ "$WEBUI_RUNTIME" = "venv" ]; then
    u="$(systemctl is-active llmstack-openwebui 2>/dev/null || true)"
    printf "Open WebUI  (:%s)    %-4s  systemd: %s\n" "$WEBUI_PORT" "$w" "${u:-unknown}"
  else
    printf "Open WebUI  (:%s)    %-4s  container\n" "$WEBUI_PORT" "$w"
  fi
  if [ "$SEARXNG_MODE" = "local" ]; then
    printf "SearXNG     (local)    %-4s  container\n" "$s"
  else
    printf "SearXNG     (remote)   %-4s  %s\n" "$s" "$SEARXNG_URL"
  fi
}
'

show_status() {
  eval "$STATUS_BODY"
  _llmstack_status
  printf '\n'
  exit 0
}

# ===========================================================================
# CONFIG
# ===========================================================================
load_config() {
  if [ -r "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  fi
}

# Settings come from the config file, then command-line flags override.
resolve_settings() {
  load_config
  [ -z "${CLI_WEBUI_RUNTIME:-}" ] || WEBUI_RUNTIME="$CLI_WEBUI_RUNTIME"
  [ -z "${CLI_WEBUI_PORT:-}" ] || WEBUI_PORT="$CLI_WEBUI_PORT"
  if [ -n "${CLI_SEARXNG_PORT:-}" ]; then
    SEARXNG_HOST_PORT="$CLI_SEARXNG_PORT"
    SEARXNG_MODE="local"
    SEARXNG_URL="http://127.0.0.1:${SEARXNG_HOST_PORT}"
  fi
  if [ -n "${CLI_SEARXNG_URL:-}" ]; then
    SEARXNG_URL="$CLI_SEARXNG_URL"
    SEARXNG_MODE="remote"
  fi
}

write_config() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<CONFIG_EOF
# llmstack-ubuntu.sh configuration. Written by the installer; the llm*
# commands and later runs read it. Safe to edit, then re-run the installer.
WEBUI_RUNTIME="${WEBUI_RUNTIME}"
SEARXNG_MODE="${SEARXNG_MODE}"
SEARXNG_URL="${SEARXNG_URL}"
SEARXNG_HOST_PORT="${SEARXNG_HOST_PORT}"
WEBUI_PORT="${WEBUI_PORT}"
LLMSTACK_SCRIPT="${SCRIPT_ABS}"
CONFIG_EOF
  put_file "$tmp" "$CONFIG_FILE" 0644
  rm -f "$tmp"
}

# ===========================================================================
# RECOMMEND
# ===========================================================================
show_recommendations() {
  detect_system
  ensure_catalog
  cat <<'SYSINFO'
===========================================================================
  DETECTED SYSTEM
===========================================================================
SYSINFO
  print_system_report
  cat <<'SYSINFO2'
===========================================================================
RECOMMENDED MODELS
SYSINFO2
  local role line found="no"
  for role in daily reasoning coding vision light; do
    line="$(best_for_role "$role")"
    [ -n "$line" ] || continue
    found="yes"
    printf '\n  %-12s %s\n' "${role}:" "$(field "$line" 2)"
    printf '             %s GB, %s' "$(field "$line" 3)" "$(field "$line" 4)"
    [ "$(field "$line" 6)" = "yes" ] || printf '  [tag UNVERIFIED]'
    printf '\n             %s\n' "$(field "$line" 7)"
  done
  if [ "$found" = "no" ]; then
    printf '\n  Nothing in the catalogue fits a %s GB budget.\n' "$SYS_BUDGET_GB"
  fi
  report_catalog_age
  printf 'Catalogue file: %s\n' "$CONFIG_DIR/models.catalog"
  if [ -f "$CONFIG_DIR/models.catalog" ] && catalog_predates_builtin; then
    printf '\nYour catalogue predates the generation %s catalogue built into this\n' "$CATALOG_GENERATION"
    printf 'script, so newer models are not considered. --sync-models offers to\n'
    printf 'replace it (with a backup).\n'
  fi
  printf 'To pull these picks and review removal of other installed models:\n'
  printf '  %s --sync-models\n\n' "$SCRIPT_NAME"
}

# ===========================================================================
# HELP
# ===========================================================================
show_help() {
  cat <<HELPTEXT
${SCRIPT_NAME} v${SCRIPT_VERSION}
NAME
    ${SCRIPT_NAME} - install and manage a private, self-hosted LLM stack
    on Ubuntu ${SUPPORTED_UBUNTU// / and } (amd64 and arm64).
SYNOPSIS
    ./${SCRIPT_NAME} [MODE] [OPTIONS]
DESCRIPTION
    Installs Ollama for inference, Open WebUI as the front-end and SearXNG
    for private web search. Everything runs as system services and comes
    back after a reboot with nobody logged in. Nothing leaves the machine
    except web searches, which go through your own SearXNG.
    Before installing, the script inspects the GPUs, memory and disk, then
    consults a dated model catalogue to recommend models that fit.
    Run it as a normal user with sudo rights, or as root. It is idempotent:
    re-running is safe and existing data is never overwritten.
MODES
    --install       Install or repair the stack. Default.
    --update        Update Ollama, Open WebUI and SearXNG after backing up
                    Open WebUI data; then check the catalogue.
    --status        Health of every component. Changes nothing.
    --recommend     Detected hardware and suitable models. Installs nothing.
    --sync-models   Bring installed models in line with the recommendations:
                    offers to replace a catalogue whose Catalogue-Generation
                    marker is missing or older than the built-in one, asks
                    which missing picks to pull and which installed picks to
                    update (older build than the registry's), pulls them, and
                    only then offers each other model for removal, one at a
                    time. Every prompt defaults to no. Needs Ollama running.
    --benchmark     Measure real generation speed (tok/s) and the CPU/GPU
                    split for each installed pick, or for --model TAG.
    --uninstall     Guided teardown; asks before removing each artifact.
    --check-models  Validate catalogue tags against the Ollama registry and
                    correct the VERIFIED column.
    --refresh-catalog
                    Write models.catalog.proposed: tags re-validated in
                    place, dead ones commented out, newer variants in your
                    families suggested as "# REVIEW:" comments. Never touches
                    the live catalogue. Add --discover to scan the Ollama
                    library for new families.
    --refresh-catalog-apply
                    As --refresh-catalog, then replace the live catalogue
                    after a backup and confirmation, setting Last-Updated.
    --version       Print the version and exit.
    --help          Show this text.
OPTIONS
    --webui-runtime docker|venv
                    How Open WebUI runs. docker (default): the official
                    container, managed by Docker Compose. venv: a uv-managed
                    Python 3.11 virtualenv under systemd. Remembered.
    --searxng-url URL
                    Use an existing SearXNG instead of a local container.
    --searxng-port PORT
                    Host port for the local SearXNG. Default ${SEARXNG_HOST_PORT}.
    --webui-port PORT
                    Port for Open WebUI. Default ${WEBUI_PORT}.
    --model TAG     Install (or benchmark) this model instead of the pick.
    --no-model      Install the services without downloading a model.
    --ollama-version X.Y.Z
                    Install this Ollama release instead of the latest.
    --nvidia-driver install|skip
                    Answer the NVIDIA driver question non-interactively.
    --yes           Answer the install's own go-ahead questions with yes.
                    Never answers removal, driver or uninstall questions.
    --discover      With --refresh-catalog modes: scan for new families.
MODEL SELECTION
    Within each role, the largest catalogue entry passing three gates wins:
      1. Its size fits the budget: ${VRAM_BUDGET_PCT} percent of the largest usable
         GPU's VRAM, or ${RAM_BUDGET_PCT} percent of system RAM with no usable GPU.
      2. System RAM is at least the entry's MIN_RAM_GB.
      3. Without a discrete GPU, dense models must generate at ${DENSE_MIN_TPS} tok/s
         or better from estimated RAM bandwidth. MoE models are exempt.
    A usable GPU is an NVIDIA card with a working driver, or an AMD card with
    at least 2 GB of VRAM and ROCm or Vulkan. Intel GPUs run through Vulkan
    but their VRAM cannot be read, so they never size the picks.
    --recommend shows every GPU found and why it was or was not used.
FILES
    ${CONFIG_DIR}/config              installer settings
    ${CONFIG_DIR}/models.catalog      model catalogue, yours to edit
    ${CONFIG_DIR}/openwebui.env       secret key, root-only (0600)
    ${CONFIG_DIR}/searxng/            SearXNG settings
    ${OPT_DIR}/                       compose file or Open WebUI venv
    ${DATA_DIR}/     accounts, chats, uploads
    ${OLLAMA_MODELS_DIR}/     downloaded models
    ${CMD_DIR}/llmstatus llmstart llmstop llmupgrade
NETWORK
    Ollama      127.0.0.1:11434      local only
    Open WebUI  0.0.0.0:${WEBUI_PORT}         reachable on the LAN; ufw applies
    SearXNG     127.0.0.1:${SEARXNG_HOST_PORT}      local only (local mode)
REQUIREMENTS
    Ubuntu ${SUPPORTED_UBUNTU// / or }, amd64 or arm64; sudo rights; internet access
    during install; free disk for the models (typically 5 to 45 GB).
EXIT STATUS
    0 success; 1 an error occurred and the message says why.
EXAMPLES
    ./${SCRIPT_NAME} --recommend
    ./${SCRIPT_NAME}
    ./${SCRIPT_NAME} --webui-runtime venv --searxng-url http://192.168.1.23:8899
    ./${SCRIPT_NAME} --sync-models
    ./${SCRIPT_NAME} --benchmark
HELPTEXT
  exit 0
}

# ===========================================================================
# SERVICE HELPERS
# ===========================================================================
wait_for_url() {  # url seconds label
  for _ in $(seq 1 "$2"); do
    if curl -s -o /dev/null --max-time 3 "$1"; then ok "$3 is answering."; return 0; fi
    sleep 1
  done
  warn "$3 is not answering after $2 seconds."
  return 1
}

compose() { as_root docker compose -f "$COMPOSE_FILE" "$@"; }

need_docker() {
  [ "$WEBUI_RUNTIME" = "docker" ] || [ "$SEARXNG_MODE" = "local" ]
}

# ===========================================================================
# OLLAMA
# ===========================================================================
installed_ollama_version() {
  command -v ollama >/dev/null 2>&1 || return 0
  ollama -v 2>&1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*[^ ]*' | tail -1 || true
}

download() {  # url dest
  local progress="-sS"
  [ -t 2 ] && progress="--progress-bar"
  curl -fL "$progress" --max-time 3600 -o "$2" "$1"
}

has_gpu_vendor() { printf '%s' "$GPUS" | grep -q "^$1|"; }

install_ollama() {  # $1 = "force" to download even if installed
  local have q="" tmp
  have="$(installed_ollama_version)"
  if [ -n "$have" ] && [ "${1:-}" != "force" ] && { [ -z "$OLLAMA_VERSION_PIN" ] || [ "$have" = "$OLLAMA_VERSION_PIN" ]; }; then
    log "Ollama $have present."
  else
    [ -n "$OLLAMA_VERSION_PIN" ] && q="?version=${OLLAMA_VERSION_PIN}"
    tmp="$(mktemp -d)"
    log "Downloading Ollama for linux-${ARCH}${OLLAMA_VERSION_PIN:+ v$OLLAMA_VERSION_PIN} (about 1.5 GB with GPU libraries)"
    download "https://ollama.com/download/ollama-linux-${ARCH}.tar.zst${q}" "$tmp/ollama.tar.zst"
    # AMD cards need the ROCm libraries, shipped separately (amd64 only).
    if [ "$ARCH" = "amd64" ] && has_gpu_vendor amd; then
      log "Downloading Ollama's ROCm libraries for the AMD GPU"
      download "https://ollama.com/download/ollama-linux-amd64-rocm.tar.zst${q}" "$tmp/ollama-rocm.tar.zst"
    fi
    as_root systemctl stop ollama 2>/dev/null || true
    # Official instructions: remove the old libraries before extracting.
    as_root rm -rf /usr/local/lib/ollama
    as_root tar -C /usr/local --zstd -xf "$tmp/ollama.tar.zst"
    [ -f "$tmp/ollama-rocm.tar.zst" ] && as_root tar -C /usr/local --zstd -xf "$tmp/ollama-rocm.tar.zst"
    rm -rf "$tmp"
    ok "Ollama $(installed_ollama_version) installed to /usr/local."
  fi
  if ! id ollama >/dev/null 2>&1; then
    log "Creating the ollama system user"
    as_root useradd -r -s /bin/false -U -m -d "$OLLAMA_HOME" ollama
  fi
  local g
  for g in render video; do
    getent group "$g" >/dev/null 2>&1 && as_root usermod -a -G "$g" ollama
  done
  local unit; unit="$(mktemp)"
  cat > "$unit" <<'UNIT_OLLAMA'
[Unit]
Description=Ollama Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
# multi-user.target, not default.target: start on headless boots too.
WantedBy=multi-user.target
UNIT_OLLAMA
  put_file "$unit" "$OLLAMA_UNIT" 0644
  cat > "$unit" <<'DROPIN_OLLAMA'
# Written by llmstack-ubuntu.sh. Settings live here, never in the unit.
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
DROPIN_OLLAMA
  put_file "$unit" "$OLLAMA_DROPIN" 0644
  rm -f "$unit"
  as_root systemctl daemon-reload
  as_root systemctl enable ollama >/dev/null 2>&1
  as_root systemctl restart ollama
  wait_for_url "$OLLAMA_API/api/version" 30 "Ollama" || error "Ollama did not start. See: journalctl -u ollama -n 50"
}

handle_nvidia_driver() {
  case "$GPUS" in *"nvidia|"*"|no-driver"*) ;; *) return 0 ;; esac
  printf '\n%sAn NVIDIA GPU was found, but its driver is not working.%s\n' "$C_YELLOW" "$C_RESET"
  echo "    Without it Ollama runs on the CPU. The script can install Ubuntu's"
  echo "    recommended NVIDIA driver with 'ubuntu-drivers install'. That adds a"
  echo "    kernel module and needs a reboot before the GPU is used."
  local answer="${NVIDIA_DRIVER_ANSWER}"
  if [ -z "$answer" ]; then
    if confirm "Install the NVIDIA driver now?"; then answer="install"; else answer="skip"; fi
  fi
  if [ "$answer" = "install" ]; then
    log "Installing the NVIDIA driver with ubuntu-drivers"
    as_root apt-get install -y ubuntu-drivers-common
    as_root ubuntu-drivers install
    NEEDS_REBOOT="yes"
    ok "NVIDIA driver installed. Reboot to use the GPU."
  else
    log "Skipping the NVIDIA driver. Install it later with:  sudo ubuntu-drivers install"
  fi
}

# ===========================================================================
# DOCKER, SEARXNG, OPEN WEBUI
# ===========================================================================
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && as_root docker compose version >/dev/null 2>&1; then
    log "Docker with Compose present."
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi
  local p conflicts=""
  for p in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    dpkg -s "$p" >/dev/null 2>&1 && conflicts="$conflicts $p"
  done
  if [ -n "$conflicts" ]; then
    warn "These packages conflict with Docker's official packages:$conflicts"
    echo "    Docker's install guide removes them first. Containers and images"
    echo "    under /var/lib/docker are not deleted by removing them."
    if confirm "Remove them now?"; then
      # shellcheck disable=SC2086
      as_root apt-get remove -y $conflicts
    else
      error "Cannot install Docker Engine alongside:$conflicts"
    fi
  fi
  log "Installing Docker Engine from Docker's apt repository"
  # A Docker source left by an earlier install (often a .list file with a
  # different keyring) makes apt refuse a second one with "Conflicting
  # values set for option Signed-By". Reuse it instead of adding ours.
  local existing
  existing="$(grep -lsE '^[^#]*download\.docker\.com/linux/ubuntu' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null \
    | grep -vx /etc/apt/sources.list.d/docker.sources | head -1)" || existing=""
  if [ -n "$existing" ]; then
    log "Using the Docker apt source already configured in $existing"
    as_root apt-get update
    as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    as_root systemctl enable --now docker
    return 0
  fi
  as_root install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --max-time 60 https://download.docker.com/linux/ubuntu/gpg | as_root tee /etc/apt/keyrings/docker.asc >/dev/null
  as_root chmod a+r /etc/apt/keyrings/docker.asc
  local src; src="$(mktemp)"
  cat > "$src" <<DOCKER_SOURCES
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_SOURCES
  put_file "$src" /etc/apt/sources.list.d/docker.sources 0644
  rm -f "$src"
  as_root apt-get update
  as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  as_root systemctl enable --now docker
}

ensure_secret() {
  if as_root test -f "$ENV_FILE"; then
    log "Reusing the existing Open WebUI secret key."
    return 0
  fi
  log "Generating a persistent Open WebUI secret key (root-only file)"
  local tmp; tmp="$(mktemp)"
  printf '# Open WebUI secret. Losing it logs everyone out.\nWEBUI_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" > "$tmp"
  put_file "$tmp" "$ENV_FILE" 0600
  rm -f "$tmp"
}

write_searxng_settings() {
  if as_root test -f "$SEARXNG_SETTINGS"; then
    log "SearXNG settings present; keeping them."
    return 0
  fi
  log "Writing SearXNG settings (private instance: JSON on, limiter off)"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<SEARXNG_YML
use_default_settings: true
server:
  secret_key: "$(openssl rand -hex 32)"
  # A private instance needs no rate limiter, and so no Valkey.
  limiter: false
  image_proxy: true
search:
  # Open WebUI queries SearXNG for JSON; without it web search returns 403.
  formats:
    - html
    - json
SEARXNG_YML
  put_file "$tmp" "$SEARXNG_SETTINGS" 0644
  rm -f "$tmp"
}

searxng_query_url() { printf '%s/search?q=<query>' "${SEARXNG_URL%/}"; }

write_compose() {
  local tmp; tmp="$(mktemp)"
  {
    printf '# Written by llmstack-ubuntu.sh; regenerated on every install.\n'
    printf 'name: llmstack\nservices:\n'
    if [ "$WEBUI_RUNTIME" = "docker" ]; then
      cat <<WEBUI_SVC
  open-webui:
    image: ${WEBUI_IMAGE}
    container_name: llmstack-open-webui
    # Host networking: reaches Ollama on 127.0.0.1, and ufw rules apply
    # (ports published by Docker would bypass ufw).
    network_mode: host
    restart: unless-stopped
    env_file: ${ENV_FILE}
    environment:
      PORT: "${WEBUI_PORT}"
      OLLAMA_BASE_URL: ${OLLAMA_API}
      DATA_DIR: /app/backend/data
      ENABLE_WEB_SEARCH: "true"
      WEB_SEARCH_ENGINE: searxng
      SEARXNG_QUERY_URL: "$(searxng_query_url)"
    volumes:
      - ${DATA_DIR}:/app/backend/data
WEBUI_SVC
    fi
    if [ "$SEARXNG_MODE" = "local" ]; then
      cat <<SEARX_SVC
  searxng:
    image: ${SEARXNG_IMAGE}
    container_name: llmstack-searxng
    restart: unless-stopped
    # The container listens on 8080 whatever its settings say.
    ports:
      - "127.0.0.1:${SEARXNG_HOST_PORT}:8080"
    environment:
      SEARXNG_BASE_URL: "http://127.0.0.1:${SEARXNG_HOST_PORT}/"
    volumes:
      - ${SEARXNG_DIR}:/etc/searxng
SEARX_SVC
    fi
  } > "$tmp"
  put_file "$tmp" "$COMPOSE_FILE" 0644
  rm -f "$tmp"
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then return 0; fi
  log "Installing uv (Python package and interpreter manager) to /usr/local/bin"
  curl -LsSf --max-time 120 https://astral.sh/uv/install.sh | as_root env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
}

# uv run as root, with its interpreters and cache under /opt/llmstack so
# the open-webui service user can reach them (the default is root's home).
uv_root() {
  as_root env UV_PYTHON_INSTALL_DIR="$UV_PYTHON_DIR" UV_CACHE_DIR="$OPT_DIR/.uv-cache" "$(command -v uv)" "$@"
}

# CPU build of torch first, from PyTorch's CPU index: otherwise Open WebUI's
# dependencies pull multi-GB CUDA wheels it does not need (open-webui#29490).
# Then upgrade only open-webui, so the resolver keeps that torch when it can.
# Open WebUI refreshes its static folder in site-packages at every start;
# owning it stops a permission error in the log each time.
webui_pip_install() {
  uv_root pip install --python "$VENV_DIR/bin/python" --upgrade torch --index-url https://download.pytorch.org/whl/cpu \
    && uv_root pip install --python "$VENV_DIR/bin/python" --upgrade-package open-webui open-webui \
    || return 1
  local d
  for d in "$VENV_DIR"/lib/python3*/site-packages/open_webui/static; do
    [ -d "$d" ] && as_root chown -R "$WEBUI_USER:$WEBUI_USER" "$d"
  done
  return 0
}

setup_webui_venv() {
  ensure_uv
  if ! id "$WEBUI_USER" >/dev/null 2>&1; then
    log "Creating the $WEBUI_USER system user"
    as_root useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" -M -U "$WEBUI_USER"
  fi
  as_root mkdir -p "$OPT_DIR" "$DATA_DIR"
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    log "Creating a Python 3.11 virtualenv with uv (Open WebUI supports 3.11-3.12 only)"
    uv_root venv --python 3.11 "$VENV_DIR"
  fi
  log "Installing Open WebUI into the virtualenv. This is large and takes several minutes."
  webui_pip_install
  as_root chown -R "$WEBUI_USER:$WEBUI_USER" "$DATA_DIR"
  local unit; unit="$(mktemp)"
  cat > "$unit" <<UNIT_WEBUI
[Unit]
Description=Open WebUI (llmstack-ubuntu.sh)
After=network-online.target ollama.service
Wants=network-online.target

[Service]
User=${WEBUI_USER}
Group=${WEBUI_USER}
# Pinned: without it the secret key and data land in the working directory
# or inside site-packages.
WorkingDirectory=${DATA_DIR}
EnvironmentFile=${ENV_FILE}
Environment="DATA_DIR=${DATA_DIR}"
Environment="OLLAMA_BASE_URL=${OLLAMA_API}"
Environment="ENABLE_WEB_SEARCH=true"
Environment="WEB_SEARCH_ENGINE=searxng"
Environment="SEARXNG_QUERY_URL=$(searxng_query_url)"
ExecStart=${VENV_DIR}/bin/open-webui serve --host 0.0.0.0 --port ${WEBUI_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_WEBUI
  put_file "$unit" "$WEBUI_UNIT" 0644
  rm -f "$unit"
  as_root systemctl daemon-reload
  as_root systemctl enable llmstack-openwebui >/dev/null 2>&1
  as_root systemctl restart llmstack-openwebui
}

# ===========================================================================
# SHELL COMMANDS (/usr/local/bin)
# ===========================================================================
install_commands() {
  local tmp; tmp="$(mktemp)"
  # shellcheck disable=SC2016  # expanded by the installed command, not here
  local sudo_line='S=sudo; [ "$(id -u)" -eq 0 ] && S=""'
  { printf '#!/bin/bash\n# llmstatus - installed by llmstack-ubuntu.sh\n%s\n_llmstack_status\n' "$STATUS_BODY"; } > "$tmp"
  put_file "$tmp" "$CMD_DIR/llmstatus" 0755
  cat > "$tmp" <<CMD_START
#!/bin/bash
# llmstart - installed by llmstack-ubuntu.sh
$STATUS_BODY
_llmstack_conf
$sudo_line
\$S systemctl start ollama
[ "\$WEBUI_RUNTIME" = "venv" ] && \$S systemctl start llmstack-openwebui
[ -f "$COMPOSE_FILE" ] && \$S docker compose -f "$COMPOSE_FILE" up -d
echo "LLM stack started. Open WebUI needs 30 to 60 seconds before it answers."
CMD_START
  put_file "$tmp" "$CMD_DIR/llmstart" 0755
  cat > "$tmp" <<CMD_STOP
#!/bin/bash
# llmstop - installed by llmstack-ubuntu.sh. Frees the memory models hold.
$STATUS_BODY
_llmstack_conf
$sudo_line
[ "\$WEBUI_RUNTIME" = "venv" ] && \$S systemctl stop llmstack-openwebui
[ -f "$COMPOSE_FILE" ] && \$S docker compose -f "$COMPOSE_FILE" stop
\$S systemctl stop ollama
echo "LLM stack stopped."
CMD_STOP
  put_file "$tmp" "$CMD_DIR/llmstop" 0755
  cat > "$tmp" <<CMD_UPGRADE
#!/bin/bash
# llmupgrade - installed by llmstack-ubuntu.sh
$STATUS_BODY
_llmstack_conf
if [ -x "\${LLMSTACK_SCRIPT:-}" ]; then
  exec "\$LLMSTACK_SCRIPT" --update "\$@"
fi
echo "Cannot find llmstack-ubuntu.sh (config says: \${LLMSTACK_SCRIPT:-nothing})." >&2
echo "Download the latest from https://github.com/cautionespn/Linux-Local-LLM-Stack/releases/latest" >&2
exit 1
CMD_UPGRADE
  put_file "$tmp" "$CMD_DIR/llmupgrade" 0755
  rm -f "$tmp"
}

# ===========================================================================
# UPDATE
# ===========================================================================
do_update() {
  resolve_settings
  detect_system
  ensure_catalog
  [ "$(id -u)" -eq 0 ] || sudo -v
  local backup=""
  if as_root test -d "$DATA_DIR"; then
    backup="${DATA_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
    log "Backing up Open WebUI data to $backup"
    as_root cp -a "$DATA_DIR" "$backup" || error "Backup failed. Aborting the update."
  fi
  log "Updating Ollama"
  install_ollama force || warn "The Ollama update failed; the previous version may be gone. Re-run --install."
  if [ "$WEBUI_RUNTIME" = "venv" ]; then
    log "Updating Open WebUI in the virtualenv"
    as_root systemctl stop llmstack-openwebui 2>/dev/null || true
    if ! webui_pip_install; then
      warn "The Open WebUI update failed. Data is safe at ${backup:-$DATA_DIR}. Restarting the existing version."
    fi
    as_root systemctl start llmstack-openwebui || true
  fi
  if [ -f "$COMPOSE_FILE" ]; then
    log "Updating container images"
    compose pull || warn "Pulling images failed; keeping the current ones."
    compose up -d --remove-orphans || warn "Restarting containers failed; see: sudo docker compose -f $COMPOSE_FILE logs"
  fi
  log "Waiting for services"
  wait_for_url "http://127.0.0.1:${WEBUI_PORT}" 180 "Open WebUI" || true
  cat <<UPDATED
===========================================================================
  UPDATE COMPLETE
===========================================================================
  Backup retained at: ${backup:-none (no data yet)}
UPDATED
  report_catalog_age
  validate_catalog_tags fix
  local line
  line="$(best_for_role daily)"
  if [ -n "$line" ]; then
    printf 'Current daily pick for this machine: %s\n' "$(field "$line" 2)"
    printf 'Run --sync-models to pull picks and update outdated builds.\n\n'
  fi
  exit 0
}

# ===========================================================================
# UNINSTALL
# ===========================================================================
uninstall_stack() {
  resolve_settings
  cat <<'BANNER'
===========================================================================
  LLM STACK UNINSTALLER
===========================================================================
  Every artifact this script created is offered for removal one at a
  time. All prompts default to NO, so pressing Enter skips a step.
  Never touched: NVIDIA drivers, and anything you decline below.
===========================================================================
BANNER
  if ! confirm "Begin uninstall?"; then log "Cancelled. Nothing was changed."; exit 0; fi
  [ "$(id -u)" -eq 0 ] || sudo -v

  log "Step 1: Stop and remove the services"
  echo "    ollama.service, llmstack-openwebui.service and the containers."
  if confirm "Stop and remove the services?"; then
    as_root systemctl disable --now llmstack-openwebui 2>/dev/null || true
    as_root systemctl disable --now ollama 2>/dev/null || true
    if [ -f "$COMPOSE_FILE" ] && command -v docker >/dev/null 2>&1; then
      compose down --remove-orphans 2>/dev/null || warn "docker compose down reported an error."
    fi
    as_root rm -f "$WEBUI_UNIT" "$OLLAMA_UNIT"
    as_root rm -rf "$OLLAMA_DROPIN_DIR"
    as_root systemctl daemon-reload
    log "Services removed."
  else
    warn "Skipped. Later steps may fail while services still run."
  fi

  log "Step 2: Remove the container images"
  if command -v docker >/dev/null 2>&1; then
    echo "    $WEBUI_IMAGE and $SEARXNG_IMAGE"
    if confirm "Delete these images?"; then
      as_root docker image rm "$WEBUI_IMAGE" "$SEARXNG_IMAGE" 2>/dev/null || true
      log "Images removed (any in use elsewhere were kept)."
    else log "Skipped."; fi
  else log "Docker not installed."; fi

  log "Step 3: Remove $OPT_DIR (compose file, virtualenv, uv's Python)"
  if [ -e "$OPT_DIR" ]; then
    if confirm "Delete $OPT_DIR?"; then as_root rm -rf "$OPT_DIR"; log "Removed."; else log "Skipped."; fi
  else log "Not present."; fi

  log "Step 4: Remove Open WebUI data"
  if as_root test -d "$DATA_DIR"; then
    echo "    $DATA_DIR"
    echo ""
    echo "    *** THIS IS YOUR ACCOUNTS, CHAT HISTORY, UPLOADS AND SETTINGS."
    echo "    *** THIS CANNOT BE UNDONE."
    if confirm "PERMANENTLY delete all Open WebUI data?"; then
      if confirm "Are you certain? This deletes accounts and chat history."; then
        as_root rm -rf "$DATA_DIR"; log "Data removed."
      else log "Skipped on second confirmation."; fi
    else log "Skipped. Data preserved at $DATA_DIR"; fi
  else log "No data directory."; fi
  if compgen -G "${DATA_DIR}.backup-*" >/dev/null; then
    printf '    %s\n' "${DATA_DIR}".backup-*
    if confirm "Delete ALL of these Open WebUI backups?"; then
      as_root rm -rf "${DATA_DIR}".backup-*; log "Backups removed."
    else log "Skipped."; fi
  fi
  if [ -d /var/lib/llmstack ] && [ -z "$(ls -A /var/lib/llmstack 2>/dev/null)" ]; then as_root rmdir /var/lib/llmstack; fi

  log "Step 5: Remove downloaded models"
  if as_root test -d "$OLLAMA_MODELS_DIR"; then
    echo "    $OLLAMA_MODELS_DIR  ($(as_root du -sh "$OLLAMA_MODELS_DIR" 2>/dev/null | cut -f1))"
    if confirm "Delete all downloaded models?"; then as_root rm -rf "$OLLAMA_MODELS_DIR"; log "Models removed."
    else log "Skipped. Models preserved."; fi
  else log "No model directory."; fi

  log "Step 6: Remove Ollama (binary, libraries, system user)"
  if [ -e /usr/local/bin/ollama ] || id ollama >/dev/null 2>&1; then
    if confirm "Remove Ollama and its ollama user?"; then
      as_root rm -f /usr/local/bin/ollama
      as_root rm -rf /usr/local/lib/ollama
      if id ollama >/dev/null 2>&1; then as_root userdel ollama 2>/dev/null || true; fi
      if getent group ollama >/dev/null 2>&1; then as_root groupdel ollama 2>/dev/null || true; fi
      # Keep /usr/share/ollama if models were preserved above.
      if ! as_root test -d "$OLLAMA_MODELS_DIR"; then as_root rm -rf "$OLLAMA_HOME"; fi
      log "Ollama removed."
    else log "Skipped."; fi
  else log "Ollama not installed."; fi

  log "Step 7: Remove the $WEBUI_USER system user"
  if id "$WEBUI_USER" >/dev/null 2>&1; then
    if confirm "Remove the $WEBUI_USER user?"; then as_root userdel "$WEBUI_USER" 2>/dev/null || true; log "Removed."; else log "Skipped."; fi
  else log "Not present."; fi

  log "Step 8: Remove the llm* commands"
  if [ -e "$CMD_DIR/llmstatus" ]; then
    if confirm "Remove llmstatus, llmstart, llmstop and llmupgrade?"; then
      as_root rm -f "$CMD_DIR/llmstatus" "$CMD_DIR/llmstart" "$CMD_DIR/llmstop" "$CMD_DIR/llmupgrade"; log "Removed."
    else log "Skipped."; fi
  else log "Not present."; fi

  log "Step 9: Remove configuration, secret key and catalogue"
  if [ -e "$CONFIG_DIR" ]; then
    echo "    $CONFIG_DIR  (including any edits you made to the catalogue)"
    if confirm "Delete $CONFIG_DIR?"; then as_root rm -rf "$CONFIG_DIR"; log "Removed."; else log "Skipped."; fi
  else log "Not present."; fi

  log "Optional: uv"
  if [ -x /usr/local/bin/uv ]; then
    echo "    /usr/local/bin/uv and uvx. Other projects may use them."
    if confirm "Remove uv?"; then as_root rm -f /usr/local/bin/uv /usr/local/bin/uvx; log "Removed."; else log "Skipped."; fi
  fi

  log "Optional: Docker Engine"
  if dpkg -s docker-ce >/dev/null 2>&1; then
    echo "    Docker's packages and repository. Answer N if anything else here uses containers."
    if confirm "Uninstall Docker Engine?"; then
      as_root apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || warn "apt reported an error."
      as_root rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
      echo "    /var/lib/docker (images, volumes) was left in place."
      log "Docker removed."
    else log "Skipped."; fi
  else log "Docker Engine packages not installed by apt."; fi

  cat <<'SUMMARY'
===========================================================================
  UNINSTALL COMPLETE
===========================================================================
  Left in place by design: NVIDIA drivers, and anything you answered N to.
  Check nothing is still running:  systemctl status ollama llmstack-openwebui
===========================================================================
SUMMARY
  exit 0
}

# ===========================================================================
# BENCHMARK
# ===========================================================================
# Measured, not estimated: tok/s from Ollama's own eval counters, and the
# CPU/GPU split from /api/ps (size vs size_vram).
json_num() { printf '%s' "$1" | grep -o "\"$2\":[0-9]*" | head -1 | cut -d: -f2; }

run_benchmark() {
  resolve_settings
  detect_system
  ensure_catalog
  curl -s -o /dev/null --max-time 3 "$OLLAMA_API/api/version" \
    || error "Ollama is not answering on $OLLAMA_API. Start it with llmstart."
  local listing tags="" role line tag arch resp ec ed tps ps size vram gpu_pct verdict
  listing="$(ollama list 2>/dev/null | awk 'NR > 1 { n = $1; if (n !~ /:/) n = n ":latest"; print n }')" || listing=""
  if [ -n "$FORCE_MODEL" ]; then
    tags="$FORCE_MODEL"
  else
    for role in daily reasoning coding vision light; do
      line="$(best_for_role "$role")"; [ -n "$line" ] || continue
      tag="$(field "$line" 2)"
      printf '%s\n' "$listing" | grep -qxF "$tag" || continue
      printf '%s\n' "$tags" | grep -qxF "$tag" || tags="${tags}${tag}"$'\n'
    done
  fi
  if [ -z "$tags" ]; then
    warn "None of the current picks is installed. Pull them with --sync-models, or name one with --model."
    exit 0
  fi
  printf '\nBenchmark: 128 tokens per model, temperature 0. First load includes loading time,\n'
  printf 'so each model is warmed up once before it is measured.\n\n'
  printf '  %-28s %9s  %-14s %s\n' "MODEL" "TOK/S" "PROCESSOR" "VERDICT"
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    arch="$(awk -F'|' -v t="$tag" '$2 == t { gsub(/[ \t]/, "", $4); print $4; exit }' "$CATALOG" 2>/dev/null || true)"
    curl -s -o /dev/null --max-time 900 "$OLLAMA_API/api/generate" \
      -d "{\"model\":\"$tag\",\"prompt\":\"Hi\",\"stream\":false,\"options\":{\"num_predict\":1}}" || true
    resp="$(curl -s --max-time 900 "$OLLAMA_API/api/generate" \
      -d "{\"model\":\"$tag\",\"prompt\":\"Write a short paragraph about the history of the bicycle.\",\"stream\":false,\"options\":{\"num_predict\":128,\"temperature\":0}}")" || resp=""
    ec="$(json_num "$resp" eval_count)"; ed="$(json_num "$resp" eval_duration)"
    if [ -z "$ec" ] || [ -z "$ed" ] || [ "$ed" -eq 0 ]; then
      printf '  %-28s %9s  %-14s %s\n' "$tag" "-" "-" "FAILED: no timing in response"
      continue
    fi
    tps="$(awk -v c="$ec" -v d="$ed" 'BEGIN { printf "%.1f", c / (d / 1e9) }')"
    # Drop the nested "details" object first, so each model is one line
    # after splitting on "{" (size_vram comes after details).
    ps="$(curl -s --max-time 10 "$OLLAMA_API/api/ps" | sed 's/"details":{[^}]*}//g' | tr '{' '\n' \
      | grep -F "\"name\":\"$tag\"" | head -1)" || ps=""
    size="$(json_num "$ps" size)"; vram="$(json_num "$ps" size_vram)"
    if [ -n "$size" ] && [ "${size:-0}" -gt 0 ]; then
      gpu_pct="$(awk -v s="$size" -v v="${vram:-0}" 'BEGIN { printf "%.0f", v * 100 / s }')"
    else gpu_pct="?"; fi
    verdict="OK"
    if [ "$POOL_KIND" = "gpu" ] && [ "$gpu_pct" != "?" ] && [ "$gpu_pct" -lt 100 ]; then
      verdict="SPILLS to CPU (${gpu_pct}% on GPU): expect a large slowdown"
    elif [ "$arch" = "dense" ] && awk -v t="$tps" -v m="$DENSE_MIN_TPS" 'BEGIN { exit !(t < m) }'; then
      verdict="SLOW: below ${DENSE_MIN_TPS} tok/s"
    fi
    printf '  %-28s %9s  %-14s %s\n' "$tag" "$tps" "${gpu_pct}% GPU" "$verdict"
  done <<< "$tags"
  printf '\n'
  exit 0
}

# ===========================================================================
# ARGUMENT PARSING
# ===========================================================================
MODE="install"
CLI_WEBUI_RUNTIME="" CLI_WEBUI_PORT="" CLI_SEARXNG_PORT="" CLI_SEARXNG_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)       show_help ;;
    --version)       echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
    --install)       MODE="install" ;;
    --update|--upgrade) MODE="update" ;;
    --status)        MODE="status" ;;
    --recommend)     MODE="recommend" ;;
    --sync-models)   MODE="sync-models" ;;
    --benchmark)     MODE="benchmark" ;;
    --uninstall)     MODE="uninstall" ;;
    --check-models)  MODE="check-models" ;;
    --refresh-catalog)       MODE="refresh-catalog" ;;
    --refresh-catalog-apply) MODE="refresh-catalog-apply" ;;
    --discover)      DISCOVER="yes" ;;
    --yes)           ASSUME_YES="yes" ;;
    --webui-runtime)
      [ $# -ge 2 ] || error "--webui-runtime needs docker or venv"
      case "$2" in docker|venv) CLI_WEBUI_RUNTIME="$2" ;; *) error "--webui-runtime must be docker or venv, not '$2'" ;; esac
      shift ;;
    --searxng-url)
      [ $# -ge 2 ] || error "--searxng-url needs a URL"
      case "$2" in http://*|https://*) CLI_SEARXNG_URL="${2%/}" ;; *) error "--searxng-url must start with http:// or https://" ;; esac
      shift ;;
    --searxng-port)
      [ $# -ge 2 ] || error "--searxng-port needs a port number"
      validate_port "$2"; CLI_SEARXNG_PORT="$2"; shift ;;
    --webui-port)
      [ $# -ge 2 ] || error "--webui-port needs a port number"
      validate_port "$2"; CLI_WEBUI_PORT="$2"; shift ;;
    --model)
      [ $# -ge 2 ] || error "--model needs a tag"
      FORCE_MODEL="$2"; shift ;;
    --no-model)      SKIP_MODEL="yes" ;;
    --ollama-version)
      [ $# -ge 2 ] || error "--ollama-version needs a version such as 0.35.0"
      [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] || error "--ollama-version must look like 0.35.0, not '$2'"
      OLLAMA_VERSION_PIN="$2"; shift ;;
    --nvidia-driver)
      [ $# -ge 2 ] || error "--nvidia-driver needs install or skip"
      case "$2" in install|skip) NVIDIA_DRIVER_ANSWER="$2" ;; *) error "--nvidia-driver must be install or skip, not '$2'" ;; esac
      shift ;;
    *) error "Unknown argument: $1   (try --help)" ;;
  esac
  shift
done

case "$MODE" in
  status)                resolve_settings; show_status ;;
  recommend)             resolve_settings; show_recommendations; exit 0 ;;
  sync-models)           resolve_settings; sync_models; exit 0 ;;
  benchmark)             run_benchmark ;;
  uninstall)             uninstall_stack ;;
  update)                do_update ;;
  check-models)          validate_catalog_tags fix; exit 0 ;;
  refresh-catalog)       build_catalog_proposal "$DISCOVER"; exit 0 ;;
  refresh-catalog-apply) apply_catalog_proposal "$DISCOVER"; exit 0 ;;
esac

# ===========================================================================
# INSTALL
# ===========================================================================
resolve_settings
SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
NEEDS_REBOOT="no"
INSTALL_STARTED="yes"

log "Preflight"
detect_system
os_supported || error "This script supports Ubuntu ${SUPPORTED_UBUNTU// / and }. Detected: ${OS_NAME}."
[ "$ARCH" != "unsupported" ] || error "Unsupported CPU architecture: $(uname -m). Supported: x86_64 (amd64), aarch64 (arm64)."
if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  error "systemd is not running. This installer needs a normal (non-container) Ubuntu with systemd."
fi

cat <<'DETECTED_HDR'
===========================================================================
  DETECTED SYSTEM
===========================================================================
DETECTED_HDR
print_system_report
echo "==========================================================================="
printf '  Open WebUI runtime: %s%s\n' "$WEBUI_RUNTIME" "$([ "$WEBUI_RUNTIME" = docker ] && echo ' (official container)' || echo ' (uv-managed Python 3.11 virtualenv)')"
printf '  SearXNG:            %s\n' "$([ "$SEARXNG_MODE" = local ] && echo "local container on 127.0.0.1:${SEARXNG_HOST_PORT}" || echo "remote at $SEARXNG_URL")"

holder=""
if holder="$(port_in_use "$WEBUI_PORT")"; then
  case "$holder" in *open-webui*|*python*|*docker*) : ;; *)
    warn "Port ${WEBUI_PORT} is already in use by: $holder"
    echo "    Free it, or re-run with --webui-port <other-port>." ;;
  esac
fi
if [ "$SEARXNG_MODE" = "local" ] && holder="$(port_in_use "$SEARXNG_HOST_PORT")"; then
  case "$holder" in *docker*) : ;; *)
    warn "Port ${SEARXNG_HOST_PORT} is already in use by: $holder"
    echo "    Free it, or re-run with --searxng-port <other-port>." ;;
  esac
fi

ensure_catalog
MODEL_TAG=""
MODEL_SIZE=0
if [ "$SKIP_MODEL" = "yes" ]; then
  log "Skipping the model download (--no-model)."
elif [ -n "$FORCE_MODEL" ]; then
  MODEL_TAG="$FORCE_MODEL"
  log "Using the model given on the command line: $MODEL_TAG (fit checks skipped)."
else
  REC_LINE="$(best_for_role daily)"
  [ -n "$REC_LINE" ] || REC_LINE="$(best_for_role light)"
  if [ -z "$REC_LINE" ]; then
    warn "No catalogue entry fits a ${SYS_BUDGET_GB} GB budget. Installing without a model."
    SKIP_MODEL="yes"
  else
    MODEL_TAG="$(field "$REC_LINE" 2)"
    MODEL_SIZE="$(field "$REC_LINE" 3)"
    printf '\nRecommended model: %s  (%s GB, %s)\n  %s\n' "$MODEL_TAG" "$MODEL_SIZE" "$(field "$REC_LINE" 4)" "$(field "$REC_LINE" 7)"
    DISK_WANTED_GB="$(awk -v s="$MODEL_SIZE" 'BEGIN { printf "%d", s + 10.999 }')"
    if awk -v f="$SYS_DISK_FREE_GB" -v w="$DISK_WANTED_GB" 'BEGIN { exit !(f + 0 < w + 0) }'; then
      warn "Only ${SYS_DISK_FREE_GB} GB free; about ${DISK_WANTED_GB} GB is wanted. Re-run with --no-model to skip the download."
    fi
  fi
fi

confirm_install "Install the stack as shown above?" || { INSTALL_STARTED="no"; log "Cancelled. Nothing was changed."; exit 0; }
[ "$(id -u)" -eq 0 ] || { log "Requesting sudo up front"; sudo -v; }
settle_catalog

log "Installing prerequisites"
as_root apt-get update -qq
as_root apt-get install -y --no-install-recommends curl ca-certificates zstd openssl

handle_nvidia_driver
install_ollama

as_root install -d -m 0755 "$CONFIG_DIR" "$OPT_DIR"
as_root install -d -m 0755 "$DATA_DIR"
ensure_secret
if need_docker; then ensure_docker; fi
if [ "$SEARXNG_MODE" = "local" ]; then write_searxng_settings; fi

if [ "$WEBUI_RUNTIME" = "venv" ]; then
  setup_webui_venv
else
  # Switching from venv to docker: retire the venv service.
  if [ -f "$WEBUI_UNIT" ]; then
    log "Stopping the venv Open WebUI service (runtime is now docker)"
    as_root systemctl disable --now llmstack-openwebui 2>/dev/null || true
  fi
fi

if need_docker; then
  write_compose
  log "Starting containers. First start downloads the images (several GB for Open WebUI)."
  compose up -d --remove-orphans
else
  as_root rm -f "$COMPOSE_FILE"
fi
if [ "$SEARXNG_MODE" = "local" ]; then
  wait_for_url "http://127.0.0.1:${SEARXNG_HOST_PORT}/search?q=test&format=json" 60 "SearXNG" || true
fi

write_config
install_commands

if [ "$SKIP_MODEL" != "yes" ] && [ -n "$MODEL_TAG" ]; then
  if ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qxF "$MODEL_TAG"; then
    log "Model already present: $MODEL_TAG"
  else
    log "Pulling $MODEL_TAG. This is a large download and will take a while."
    trap 'warn "Pull interrupted. Re-run to resume the download."; exit 1' INT
    if ollama pull "$MODEL_TAG"; then ok "Model pulled: $MODEL_TAG"
    else warn "The pull failed for $MODEL_TAG. Everything else installed; pull it later with: ollama pull $MODEL_TAG"; fi
    trap - INT
  fi
fi

log "Verifying services. Open WebUI's first start takes a minute or two."
wait_for_url "http://127.0.0.1:${WEBUI_PORT}" 240 "Open WebUI" || true

trap - EXIT
INSTALL_STARTED="no"
HOSTNAME_SHORT="$(hostname)"
cat <<DONE
===========================================================================
  SETUP COMPLETE
===========================================================================
  Ollama API:   ${OLLAMA_API}
  Open WebUI:   http://${HOSTNAME_SHORT}:${WEBUI_PORT}
  SearXNG:      ${SEARXNG_URL}
  Next steps:
    1. Open the Open WebUI address and create the admin account now.
       The first account created becomes the owner.
    2. Web search is pre-configured for this first launch. After that,
       Admin > Settings > Web Search is authoritative.
    3. llmstatus, llmstart, llmstop and llmupgrade are in ${CMD_DIR}.
    4. ./${SCRIPT_NAME} --benchmark measures real speed on this machine.
DONE
if [ "$NEEDS_REBOOT" = "yes" ]; then
  printf '  %sReboot to load the NVIDIA driver; the GPU is not used until then.%s\n' "$C_YELLOW" "$C_RESET"
fi
echo "==========================================================================="
