#!/bin/bash
# check() evaluates its first argument later, so single quotes are the point.
# shellcheck disable=SC2016,SC2034
#
# Unit tests for llmstack-ubuntu.sh. No network, no root, no services:
# hardware comes from a fake tree (LLMSTACK_ROOT), the catalogue from a
# scratch directory (LLMSTACK_CONFIG_DIR), and nvidia-smi, udevadm, df,
# sudo, ollama and curl are stubs placed first on PATH.
#
# Run from anywhere:  bash tests/unit.sh
# Every check runs; the exit status is the number of failures (capped at 1).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
S="$PWD/llmstack-ubuntu.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASSES=0; FAILS=0; label=""; out=""

pass()   { PASSES=$((PASSES + 1)); echo "ok   [$label] $1"; }
fail()   { FAILS=$((FAILS + 1)); echo "FAIL [$label] $1"; [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/     | /'; }
expect() { if printf '%s\n' "$out" | grep -qE -- "$1"; then pass "/$1/"; else fail "expected /$1/"; fi; }
reject() { if printf '%s\n' "$out" | grep -qE -- "$1"; then fail "unexpected /$1/"; else pass "not /$1/"; fi; }
check()  { if eval "$1"; then pass "$2"; else fail "$2"; fi; }   # check 'test expr' 'description'

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/fakecurl" "$T/deadcurl" "$T/nosudo"
cat > "$T/bin/nvidia-smi" <<'EOF'
#!/bin/bash
# FAKE_NVSMI holds the CSV rows; unset means installed but no working driver.
[ -n "${FAKE_NVSMI:-}" ] || { echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver." >&2; exit 9; }
printf '%s\n' "$FAKE_NVSMI"
EOF
cat > "$T/bin/udevadm" <<'EOF'
#!/bin/bash
[ -z "${FAKE_MTS:-}" ] && exit 0
printf 'P: /devices/virtual/dmi/id\nE: MEMORY_DEVICE_0_SPEED_MTS=%s\nE: MEMORY_DEVICE_0_CONFIGURED_SPEED_MTS=%s\n' "$FAKE_MTS" "$FAKE_MTS"
printf 'E: MEMORY_DEVICE_1_CONFIGURED_SPEED_MTS=%s\n' "$FAKE_MTS"
EOF
cat > "$T/bin/df" <<'EOF'
#!/bin/bash
if [ "$1" = "-BG" ]; then
  echo "Filesystem 1G-blocks Used Available Use% Mounted on"
  echo "/dev/sda1 1000G 500G ${FAKE_DISK_GB:-500}G 50% /"
else
  exec /bin/df "$@"
fi
EOF
cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
# Passwordless stand-in: drop sudo's own options, run the command.
while [ $# -gt 0 ]; do case "$1" in -n|-v|-H) shift ;; *) break ;; esac; done
[ $# -eq 0 ] && exit 0
exec "$@"
EOF
cat > "$T/nosudo/sudo" <<'EOF'
#!/bin/bash
echo "sudo: a password is required" >&2
exit 1
EOF
cat > "$T/bin/ollama" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_OLLAMA_LOG"
case "$1" in
  list)
    [ -z "${FAKE_OLLAMA_DOWN:-}" ] || { echo "Error: could not connect to ollama server" >&2; exit 1; }
    # ID = first 12 hex of sha256 of the manifest, as real Ollama does. The
    # stub registry serves "manifest:<tag>:v1"; a model in FAKE_STALE was
    # pulled from an older manifest, so its ID differs.
    echo "NAME                      ID              SIZE      MODIFIED"
    for m in ${FAKE_OLLAMA_MODELS:-}; do
      n="$m"; case "$n" in *:*) ;; *) n="$n:latest" ;; esac
      rev=v1; case " ${FAKE_STALE:-} " in *" $n "*) rev=old ;; esac
      id="$(printf 'manifest:%s:%s' "$n" "$rev" | sha256sum | cut -c1-12)"
      echo "$m    $id    4.1 GB    2 weeks ago"
    done ;;
  pull) case " ${FAKE_PULL_FAIL:-} " in *" $2 "*) echo "Error: pull failed" >&2; exit 1 ;; esac ;;
  rm)   echo "deleted '$2'" ;;
  show)
    case " ${FAKE_EMBED:-} " in
      *" $2 "*) printf '  Capabilities\n    embedding\n\n' ;;
      *)        printf '  Capabilities\n    completion\n\n' ;;
    esac ;;
esac
EOF
# Registry impersonator: 200 for tags in FAKE_LIVE (or any tag when FAKE_LIVE
# is "*"), 404 otherwise; manifests fetched into a file are "manifest:<tag>:v1".
cat > "$T/fakecurl/curl" <<'EOF'
#!/bin/bash
url=""; out=""; prev=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -z "${FAKE_REG_DOWN:-}" ] || exit 7
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then
  t="${url#*/v2/library/}"; tag="${t%%/manifests/*}:${t##*/manifests/}"
  printf 'manifest:%s:v1' "$tag" > "$out"; exit 0
fi
case "$url" in
  *registry.ollama.ai/v2/library/*/manifests/*)
    t="${url#*/v2/library/}"; tag="${t%%/manifests/*}:${t##*/manifests/}"
    if [ "${FAKE_LIVE:-*}" = "*" ]; then printf '200'; exit 0; fi
    case " ${FAKE_LIVE:-} " in *" $tag "*) printf '200' ;; *) printf '404' ;; esac ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/deadcurl/curl"
chmod +x "$T"/bin/* "$T"/fakecurl/curl "$T"/deadcurl/curl "$T"/nosudo/sudo
export FAKE_OLLAMA_LOG="$T/ollama.log"

# ---------------------------------------------------------------------------
# Fake hardware
# ---------------------------------------------------------------------------
# mkhw NAME RAM_GB [UBUNTU_VERSION]
mkhw() {
  local r="$T/hw/$1"
  mkdir -p "$r/etc" "$r/proc" "$r/sys/class/drm" "$r/dev"
  printf 'PRETTY_NAME="Ubuntu %s LTS"\nNAME="Ubuntu"\nVERSION_ID="%s"\nID=ubuntu\nUBUNTU_CODENAME=noble\n' "${3:-24.04}" "${3:-24.04}" > "$r/etc/os-release"
  printf 'processor\t: 0\nmodel name\t: Test CPU 9000\n' > "$r/proc/cpuinfo"
  # MemTotal sits a little under the installed size, as on real machines.
  printf 'MemTotal:       %d kB\n' $(( $2 * 1048576 - 250000 )) > "$r/proc/meminfo"
  mkdir -p "$r/sys/class/drm/card0-HDMI-A-1"   # a connector, never a GPU
}
# addgpu NAME CARD VENDOR_HEX VRAM_MIB
addgpu() {
  local d="$T/hw/$1/sys/class/drm/$2/device"
  mkdir -p "$d"
  echo 0x030000 > "$d/class"
  echo "$3" > "$d/vendor"
  [ "$3" != "0x1002" ] || echo $(( $4 * 1048576 )) > "$d/mem_info_vram_total"
}
hw() { printf '%s' "$T/hw/$1"; }

# run MODE HW [ARGS...]: one invocation with a fresh config dir (CFG), env
# and stdin from the caller. Sets out and RC; never called inside $(...), so
# the counter and CFG survive.
n=0
run() {
  local mode="$1" root; root="$(hw "$2")"; shift 2
  n=$((n + 1)); CFG="$T/cfg$n"; RC=0
  out="$(LLMSTACK_ROOT="$root" LLMSTACK_CONFIG_DIR="$CFG" PATH="$T/bin:$PATH" "$S" "$mode" "$@" 2>&1)" || RC=$?
}

mkhw cpu16 16
mkhw cpu64 64
mkhw vm7 7
mkhw nv24 64;    addgpu nv24 card1 0x10de 0
mkhw nvnodrv 32; addgpu nvnodrv card1 0x10de 0
mkhw amd16 32;   addgpu amd16 card1 0x1002 16368; touch "$(hw amd16)/dev/kfd"
mkhw amdnone 32; addgpu amdnone card1 0x1002 16368
mkhw apu 32;     addgpu apu card0 0x1002 512
mkdir -p "$(hw apu)/usr/share/vulkan/icd.d"; touch "$(hw apu)/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"
mkhw intel 32;   addgpu intel card0 0x8086 0
mkhw multi 64;   addgpu multi card0 0x10de 0; addgpu multi card1 0x1002 24560
mkdir -p "$(hw multi)/usr/share/vulkan/icd.d"; touch "$(hw multi)/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"
mkhw jammy 32 22.04

# ===========================================================================
# CLI
# ===========================================================================
label="help"; out="$("$S" --help 2>&1)"; check '[ $? -eq 0 ]' "--help exits 0"
for m in --install --update --status --recommend --sync-models --benchmark --uninstall \
         --check-models --refresh-catalog --refresh-catalog-apply --discover \
         --webui-runtime --nvidia-driver --ollama-version --yes; do expect -- "$m"; done
label="version"; out="$("$S" --version 2>&1)"
expect "^llmstack-ubuntu\.sh v$(grep -m1 '^SCRIPT_VERSION=' "$S" | cut -d'"' -f2)$"

bad() {  # bad LABEL PATTERN ARGS...  -> exit 1 with the message
  label="$1"; local pat="$2"; shift 2
  out="$("$S" "$@" 2>&1)"; local rc=$?
  check "[ $rc -eq 1 ]" "exits 1"; expect "$pat"
}
bad "unknown argument"      'Unknown argument'           --frobnicate
bad "port not numeric"      'Invalid port'               --webui-port abc
bad "port too high"         'Invalid port'               --webui-port 70000
bad "port zero"             'Invalid port'               --searxng-port 0
bad "missing --model value" 'needs a tag'                --model
bad "missing searxng url"   'needs a URL'                --searxng-url
bad "searxng url scheme"    'must start with http'       --searxng-url 192.168.1.2:8888
bad "runtime value"         'must be docker or venv'     --webui-runtime podman
bad "runtime missing"       'needs docker or venv'       --webui-runtime
bad "nvidia-driver value"   'must be install or skip'    --nvidia-driver maybe
bad "ollama version format" 'must look like 0.35.0'      --ollama-version latest

# ===========================================================================
# Hardware detection and picks
# ===========================================================================
label="CPU 16 GB DDR5-5600"
FAKE_MTS=5600 run --recommend cpu16
expect 'System RAM: +16 GB'; expect 'RAM bandwidth: +~90 GB/s \(DDR 5600 MT/s, read from DMI'
expect 'Dense model cap: +~7\.3 GB'; expect 'CPU and RAM: 70% of 16 GB = ~11\.2 GB'
expect 'daily: +qwen3\.5:4b$'; expect 'coding: +qwen3\.5:9b$'; reject 'gemma4:12b'
expect 'GPUs: +none found'

label="CPU 64 GB, DIMM speed unreadable"
run --recommend cpu64
expect 'DDR 3200 MT/s, assumed'; expect '~51 GB/s'; expect 'Dense model cap: +~4\.1 GB'
expect 'daily: +qwen3\.6:35b-a3b$'; expect 'reasoning: +gemma4:26b-a4b-it-qat$'
expect 'coding: +qwen3\.6:35b-a3b-coding$'; reject 'qwen3\.8:27b'

label="7 GB VM"
run --recommend vm7
expect 'light: +granite4\.2:3b$'; reject 'daily:'

label="NVIDIA 24 GB"
FAKE_NVSMI='NVIDIA GeForce RTX 4090, 24564' run --recommend nv24
expect 'NVIDIA GeForce RTX 4090 +\[discrete, 24\.0 GB\] +driver working'
expect 'GPU NVIDIA GeForce RTX 4090: 75% of 24 GB VRAM = ~18\.0 GB'
expect 'No dense-speed cap'
expect 'daily: +gemma4:26b-a4b-it-qat$'; expect 'reasoning: +qwen3\.8:27b$'
expect 'coding: +devstral-small-2:24b$'
check '[ "$(printf "%s\n" "$out" | grep -c "NVIDIA")" -eq 2 ]' "card listed once (sysfs row skipped when nvidia-smi works)"

label="NVIDIA without a driver"
FAKE_MTS=4800 run --recommend nvnodrv
expect 'NO DRIVER'; expect 'ubuntu-drivers install'; expect 'Sizing: +CPU and RAM'

label="AMD 16 GB with ROCm"
run --recommend amd16
expect 'AMD GPU +\[discrete, 16\.0 GB\] +ROCm'; expect 'GPU AMD GPU: 75% of 16 GB VRAM = ~12\.0 GB'
expect 'daily: +gemma4:12b$'; expect 'coding: +qwen3\.5:9b$'

label="AMD card with no ROCm or Vulkan"
run --recommend amdnone
expect 'no ROCm or Vulkan driver found'; expect 'Sizing: +CPU and RAM'; expect 'on 26\.04 use Vulkan'

label="AMD APU (integrated)"
run --recommend apu
expect '\[integrated, 0\.5 GB\] +Vulkan driver present'; expect 'Sizing: +CPU and RAM'

label="Intel GPU"
run --recommend intel
expect 'Intel GPU +\[unsized, VRAM unknown\]'; expect 'Intel GPUs run through Vulkan only'
expect 'OLLAMA_IGPU_ENABLE=1'; expect 'Sizing: +CPU and RAM'

label="NVIDIA 12 GB + AMD 24 GB: the larger card sizes"
FAKE_NVSMI='NVIDIA GeForce RTX 3060, 12288' run --recommend multi
expect 'GPU AMD GPU: 75% of 24 GB'; expect 'RTX 3060 +\[discrete, 12\.0 GB\]'
check '[ "$(printf "%s\n" "$out" | grep -c "NVIDIA")" -eq 1 ]' "NVIDIA listed once"

label="Ubuntu 22.04 is reported unsupported"
run --recommend jammy
expect 'unsupported: this script targets Ubuntu 24\.04 and 26\.04'
run --install jammy </dev/null; rc=$RC
check "[ $rc -eq 1 ]" "--install exits 1"; expect 'supports Ubuntu 24\.04 and 26\.04'

label="install without an answer cancels"
PATH="$T/deadcurl:$PATH" run --install cpu64 --no-model </dev/null; rc=$RC
if [ -d /run/systemd/system ]; then
  check "[ $rc -eq 0 ]" "exits 0"; expect 'Cancelled\. Nothing was changed'
else
  check "[ $rc -eq 1 ]" "exits 1 without systemd"; expect 'systemd is not running'
fi

label="recommend is idempotent"
run --recommend cpu64    # writes the catalogue; the next two only read it
again() { LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$CFG" PATH="$T/bin:$PATH" "$S" --recommend 2>&1; }
a="$(again)"; b="$(again)"
out=""; check '[ "$a" = "$b" ]' "same output twice"
label="recommend writes and keeps the catalogue"
run --recommend cpu64
check '[ -f "$CFG/models.catalog" ]' "catalogue written"
echo '# my edit' >> "$CFG/models.catalog"
LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$CFG" PATH="$T/bin:$PATH" "$S" --recommend >/dev/null 2>&1
check 'grep -qx "# my edit" "$CFG/models.catalog"' "existing catalogue not overwritten"
expect -- '--sync-models'; expect 'last updated: '

if [ "$(id -u)" -ne 0 ]; then
  label="read-only recommend without sudo uses a private copy"
  ro="$T/ro"; mkdir -p "$ro"; chmod 555 "$ro"; mkdir -p "$T/tmpdir"
  out="$(TMPDIR="$T/tmpdir" LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$ro/llmstack" \
         PATH="$T/nosudo:$T/bin:$PATH" "$S" --recommend 2>&1)"; rc=$?
  check "[ $rc -eq 0 ]" "exits 0"; expect 'daily: +qwen3\.6:35b-a3b$'; expect 'using the built-in one'
  check '[ ! -e "$ro/llmstack" ]' "nothing written to the config dir"
  check '[ -z "$(ls -A "$T/tmpdir")" ]' "temporary catalogue removed"
  chmod 755 "$ro"
fi

# ===========================================================================
# Catalogue format (the shipped catalogue)
# ===========================================================================
label="catalogue format"
LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$T/shipped" PATH="$T/bin:$PATH" "$S" --recommend >/dev/null 2>&1
C="$T/shipped/models.catalog"; out=""
check 'grep -qE "^# Last-Updated: [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$C"' "Last-Updated line"
check 'grep -qx "# Catalogue-Generation: $(grep -m1 "^CATALOG_GENERATION=" "$S" | cut -d\" -f2)" "$C"' "generation marker matches the script"
rows="$(grep -v '^#' "$C" | grep -v '^$')"
check '[ -z "$(printf "%s\n" "$rows" | awk -F"|" "NF != 7")" ]' "7 fields per row"
check '[ -z "$(printf "%s\n" "$rows" | cut -d"|" -f2 | grep -vE "^[a-z0-9][a-z0-9._-]*(/[a-z0-9._-]+)?:[a-z0-9._-]+$")" ]' "tags are name:tag"
check '[ -z "$(printf "%s\n" "$rows" | cut -d"|" -f6 | grep -vxE "yes|no")" ]' "VERIFIED is yes or no"
check '[ -z "$(printf "%s\n" "$rows" | cut -d"|" -f4 | grep -vxE "moe|dense")" ]' "ARCH is moe or dense"
check '[ -z "$(printf "%s\n" "$rows" | cut -d"|" -f5 | grep -vxE "daily|reasoning|coding|vision|light")" ]' "ROLE is known"
check 'printf "%s\n" "$rows" | awk -F"|" "\$5 == \"daily\" && \$6 == \"yes\"" | grep -q .' "a verified daily driver exists"
# The rows must match the macOS generation exactly apart from NOTES.
if [ -n "${MACOS_SCRIPT:-}" ] && [ -f "$MACOS_SCRIPT" ]; then
  mh="$(mktemp -d)"
  HOME="$mh" bash "$MACOS_SCRIPT" --recommend >/dev/null 2>&1 || true
  a="$(grep -v '^#' "$mh/.config/llmstack/models.catalog" | grep -v '^$' | cut -d'|' -f1-6)"
  b="$(printf '%s\n' "$rows" | cut -d'|' -f1-6)"
  check '[ "$a" = "$b" ]' "rows match the macOS catalogue (columns 1-6)"
  rm -rf "$mh"
fi

# ===========================================================================
# --sync-models against the stub ollama and registry. Picks on cpu64:
# qwen3.6:35b-a3b (daily, vision), gemma4:26b-a4b-it-qat (reasoning),
# qwen3.6:35b-a3b-coding (coding), granite4.2:3b (light).
# ===========================================================================
# sync ANSWERS [CATALOG_FILE]: answers are one y/n per prompt, fed on stdin.
sync() {
  n=$((n + 1)); SYNC_CFG="$T/cfg$n"; mkdir -p "$SYNC_CFG"
  [ -z "${2:-}" ] || cp "$2" "$SYNC_CFG/models.catalog"
  : > "$FAKE_OLLAMA_LOG"
  SYNC_RC=0
  # shellcheck disable=SC2086
  out="$(printf '%s\n' $1 | LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$SYNC_CFG" \
    FAKE_DISK_GB="${FAKE_DISK_GB:-500}" PATH="$T/fakecurl:$T/bin:$PATH" \
    "$S" --sync-models 2>&1)" || SYNC_RC=$?
}
called()     { if grep -qxF -- "$1" "$FAKE_OLLAMA_LOG"; then pass "called '$1'"; else fail "expected ollama call '$1'"; fi; }
not_called() { if grep -qxF -- "$1" "$FAKE_OLLAMA_LOG"; then fail "unexpected ollama call '$1'"; else pass "not called '$1'"; fi; }
clear_fakes() { unset FAKE_OLLAMA_MODELS FAKE_EMBED FAKE_PULL_FAIL FAKE_OLLAMA_DOWN FAKE_STALE FAKE_REG_DOWN FAKE_DISK_GB FAKE_LIVE; }

label="sync happy path"; clear_fakes
export FAKE_OLLAMA_MODELS="llama3.3:70b qwen2.5:32b-instruct nomic-embed-text gemma4:26b-a4b-it-qat"
export FAKE_EMBED="nomic-embed-text:latest"
# pulls: qwen3.6 y, coding n, granite y | removals: llama3.3 y, qwen2.5 n, nomic n
sync 'y n y y n n'
check "[ $SYNC_RC -eq 0 ]" "exits 0"
called 'pull qwen3.6:35b-a3b'; called 'pull granite4.2:3b'
not_called 'pull qwen3.6:35b-a3b-coding'; not_called 'pull gemma4:26b-a4b-it-qat'
called 'rm llama3.3:70b'; not_called 'rm qwen2.5:32b-instruct'; not_called 'rm nomic-embed-text:latest'
expect 'Embedding model'; expect 'gemma4:26b-a4b-it-qat .* current'
reject 'Catalogue-Generation line|this script ships generation'
lp=$(grep -n '^pull ' "$FAKE_OLLAMA_LOG" | tail -1 | cut -d: -f1); fr=$(grep -n '^rm ' "$FAKE_OLLAMA_LOG" | head -1 | cut -d: -f1)
check "[ ${lp:-0} -lt ${fr:-0} ]" "every pull precedes the first removal"

label="sync pull failure blocks removals"; clear_fakes
export FAKE_OLLAMA_MODELS="llama3.3:70b" FAKE_PULL_FAIL="qwen3.6:35b-a3b"
sync 'y y y y y y y y'
check "[ $SYNC_RC -eq 1 ]" "exits 1"; called 'pull qwen3.6:35b-a3b'; not_called 'rm llama3.3:70b'
expect 'no models were removed'

# 1.0.2: the failure names its cause. The stub registry serves every tag
# when FAKE_LIVE is unset, only the listed ones otherwise, and refuses
# connections with FAKE_REG_DOWN.
label="sync pull failure, live tag"; clear_fakes
export FAKE_OLLAMA_MODELS="llama3.3:70b" FAKE_PULL_FAIL="qwen3.6:35b-a3b"
sync 'y y y y y y y y'
check "[ $SYNC_RC -eq 1 ]" "exits 1"; not_called 'rm llama3.3:70b'
expect 'qwen3.6:35b-a3b +download failed \(the tag is in the registry\)'; expect 'VPN,'
reject 'Check the tag|tag not found|registry unreachable'

label="sync pull failure, missing tag"; clear_fakes
export FAKE_OLLAMA_MODELS="llama3.3:70b" FAKE_PULL_FAIL="qwen3.6:35b-a3b" FAKE_LIVE="llama3.3:70b"
sync 'y y y y y y y y'
check "[ $SYNC_RC -eq 1 ]" "exits 1"; not_called 'rm llama3.3:70b'
expect 'qwen3.6:35b-a3b +tag not found in the registry'; expect 'Check the tag at https://ollama.com/library'
reject 'download failed|VPN,|registry unreachable'

label="sync pull failure, registry down"; clear_fakes
export FAKE_OLLAMA_MODELS="llama3.3:70b" FAKE_PULL_FAIL="qwen3.6:35b-a3b" FAKE_REG_DOWN=1
sync 'y y y y y y y y'
check "[ $SYNC_RC -eq 1 ]" "exits 1"; not_called 'rm llama3.3:70b'
expect 'qwen3.6:35b-a3b +registry unreachable'; expect 'did not answer'
reject 'Check the tag|VPN,'

label="sync with Ollama down"; clear_fakes
export FAKE_OLLAMA_DOWN=1
sync 'y y y y'
check "[ $SYNC_RC -eq 1 ]" "exits 1"; expect 'Nothing was changed'
check '! grep -qE "^(pull|rm) " "$FAKE_OLLAMA_LOG"' "no pull or rm"

label="sync: no generation marker, answer no"; clear_fakes
old="$T/old.catalog"
printf '%s\n' '# Last-Updated: 2026-09-30' '32|qwen3.6:35b-a3b|24|moe|daily|yes|old' > "$old"
export FAKE_OLLAMA_MODELS="qwen3.6:35b-a3b"
sync 'n' "$old"
expect 'no Catalogue-Generation line'
check '! grep -q "^# Catalogue-Generation:" "$SYNC_CFG/models.catalog"' "catalogue unchanged"
label="sync: no generation marker, answer yes"
sync 'y n n n' "$old"
check 'grep -q "^# Catalogue-Generation: " "$SYNC_CFG/models.catalog"' "catalogue replaced"
check 'ls "$SYNC_CFG"/models.catalog.backup-* >/dev/null 2>&1' "backup kept"
expect 'gemma4:26b-a4b-it-qat'

label="sync: older generation offered, current not"; clear_fakes
export FAKE_OLLAMA_MODELS="qwen3.6:35b-a3b"
older="$T/older.catalog"
printf '%s\n' '# Last-Updated: 2026-09-30' '# Catalogue-Generation: 3.3.0' '32|qwen3.6:35b-a3b|24|moe|daily|yes|x' > "$older"
sync 'n' "$older"; expect 'is generation 3\.3\.0'
gen=$(grep -m1 '^CATALOG_GENERATION=' "$S" | cut -d'"' -f2)
current="$T/current.catalog"
printf '%s\n' '# Last-Updated: 2020-01-01' "# Catalogue-Generation: $gen" '32|qwen3.6:35b-a3b|24|moe|daily|yes|x' > "$current"
sync '' "$current"; reject 'Catalogue-Generation line|this script ships generation'
label="recommend notes an old catalogue"
n=$((n + 1)); mkdir -p "$T/cfg$n"; cp "$older" "$T/cfg$n/models.catalog"
out="$(LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$T/cfg$n" PATH="$T/bin:$PATH" "$S" --recommend 2>&1)"
expect 'predates the generation'
label="recommend with no Last-Updated line"
n=$((n + 1)); mkdir -p "$T/cfg$n"; printf '%s\n' '32|qwen3.6:35b-a3b|24|moe|daily|yes|x' > "$T/cfg$n/models.catalog"
out="$(LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$T/cfg$n" PATH="$T/bin:$PATH" "$S" --recommend 2>&1)"
expect 'daily: +qwen3\.6:35b-a3b$'; expect 'no readable .Last-Updated'

label="sync: outdated pick offered for update"; clear_fakes
export FAKE_OLLAMA_MODELS="qwen3.6:35b-a3b gemma4:26b-a4b-it-qat" FAKE_STALE="qwen3.6:35b-a3b"
# update qwen3.6 y | coding n | granite n
sync 'y n n'
check "[ $SYNC_RC -eq 0 ]" "exits 0"
expect 'qwen3\.6:35b-a3b .* outdated'; expect 'gemma4:26b-a4b-it-qat .* current'
expect 'Update qwen3\.6:35b-a3b'; reject 'Update gemma4'
called 'pull qwen3.6:35b-a3b'; not_called 'pull gemma4:26b-a4b-it-qat'
check 'printf "%s\n" "$out" | awk "/^  Updated:/ { getline; print }" | grep -q "qwen3\.6:35b-a3b"' "listed under Updated"

label="sync: failed update blocks removals"; clear_fakes
export FAKE_OLLAMA_MODELS="qwen3.6:35b-a3b llama3.3:70b" FAKE_STALE="qwen3.6:35b-a3b" FAKE_PULL_FAIL="qwen3.6:35b-a3b"
sync 'y n n n y'
check "[ $SYNC_RC -eq 1 ]" "exits 1"; called 'pull qwen3.6:35b-a3b'; not_called 'rm llama3.3:70b'

label="sync: registry unreachable"; clear_fakes
export FAKE_OLLAMA_MODELS="qwen3.6:35b-a3b" FAKE_STALE="qwen3.6:35b-a3b" FAKE_REG_DOWN=1
sync 'n n n'
check "[ $SYNC_RC -eq 0 ]" "exits 0"
expect 'qwen3\.6:35b-a3b .* unchecked'; expect 'Registry unreachable'; reject 'Update qwen3\.6'

label="sync: disk shortfall stops first"; clear_fakes
export FAKE_OLLAMA_MODELS="llama3.3:70b" FAKE_DISK_GB=20
sync 'y y y y y'
check "[ $SYNC_RC -eq 1 ]" "exits 1"; expect 'Nothing was changed'
check '! grep -qE "^(pull|rm) " "$FAKE_OLLAMA_LOG"' "no pull or rm"
clear_fakes

# ===========================================================================
# Catalogue refresh against the stub registry
# ===========================================================================
refresh() {  # refresh CFG ARGS...  (stdin passes through)
  local cfg="$1"; shift
  LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$cfg" PATH="$T/fakecurl:$T/bin:$PATH" "$S" "$@" 2>&1
}
label="refresh: order kept, dead in place, REVIEW as comments"
R="$T/refresh1"; mkdir -p "$R"; c="$R/models.catalog"
printf '%s\n' '# Last-Updated: 2026-01-01' '# Catalogue-Generation: 3.4.0' \
  '# --- Daily ---' '32|qwen3.6:35b-a3b|23|moe|daily|yes|kept' \
  '# --- Coding ---' '16|qwen3.6:14b|9|dense|coding|no|dead one' > "$c"
export FAKE_LIVE="llama3.3:70b qwen3.6:35b-a3b qwen3.6:27b"
out="$(refresh "$R" --refresh-catalog)"; p="$c.proposed"
check '[ "$(awk "/^# --- Daily ---/ { getline; print }" "$p")" = "32|qwen3.6:35b-a3b|23|moe|daily|yes|kept" ]' "live row under its heading"
check 'awk "/^# --- Coding ---/ { getline; print }" "$p" | grep -q "^# DEAD (404.*qwen3\.6:14b"' "dead row commented in place"
check 'grep -q "^# REVIEW: REVIEW|qwen3\.6:27b|" "$p"' "candidate suggested"
check '! grep -qE "^REVIEW\|" "$p"' "no unreviewed live row"
check 'grep -qx "# Last-Updated: 2026-01-01" "$p"' "proposal leaves Last-Updated alone"
mv "$p" "$c"; out="$(refresh "$R" --refresh-catalog)"
check '[ "$(grep -c "^# REVIEW: REVIEW|qwen3\.6:27b|" "$c.proposed")" -eq 1 ]' "no duplicate suggestion"
check '[ "$(grep -c "^# --- Suggested by --refresh-catalog" "$c.proposed")" -eq 1 ]' "no duplicate header"

label="refresh apply: date stamped only on yes"
R="$T/refresh2"; mkdir -p "$R"; c="$R/models.catalog"
printf '%s\n' '# Last-Updated: 2026-01-01' '32|qwen3.6:35b-a3b|23|moe|daily|yes|kept' > "$c"
export FAKE_LIVE="llama3.3:70b qwen3.6:35b-a3b"
out="$(printf 'n\n' | refresh "$R" --refresh-catalog-apply)"
check 'grep -qx "# Last-Updated: 2026-01-01" "$c"' "unchanged on no"
out="$(printf 'y\n' | refresh "$R" --refresh-catalog-apply)"
check 'grep -qx "# Last-Updated: $(date +%Y-%m-%d)" "$c"' "stamped on yes"
check '[ ! -f "$c.proposed" ]' "applied proposal removed"
check 'ls "$R"/models.catalog.backup-* >/dev/null 2>&1' "backup kept"

label="refresh apply: a leftover proposal is never applied offline"
R="$T/refresh3"; mkdir -p "$R"; c="$R/models.catalog"
printf '%s\n' '# Last-Updated: 2026-01-01' '32|qwen3.6:35b-a3b|23|moe|daily|yes|kept' > "$c"
printf '%s\n' '# stale leftover' '8|bogus:1b|1|dense|daily|yes|x' > "$c.proposed"
cp "$c" "$T/before.catalog"
out="$(printf 'y\n' | LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$R" PATH="$T/deadcurl:$T/bin:$PATH" "$S" --refresh-catalog-apply 2>&1)"
check 'diff -q "$c" "$T/before.catalog" >/dev/null' "catalogue unchanged"

label="check-models and refresh are offline-safe"
R="$T/refresh4"; mkdir -p "$R"
for m in --check-models --refresh-catalog --refresh-catalog-apply; do
  out="$(LLMSTACK_ROOT="$(hw cpu64)" LLMSTACK_CONFIG_DIR="$R" PATH="$T/deadcurl:$T/bin:$PATH" "$S" "$m" </dev/null 2>&1)"; rc=$?
  check "[ $rc -eq 0 ]" "$m exits 0 offline"
done
check '[ ! -f "$R/models.catalog.proposed" ]' "no proposal written offline"

label="check-models corrects VERIFIED"
R="$T/refresh5"; mkdir -p "$R"; c="$R/models.catalog"
printf '%s\n' '# Last-Updated: 2026-01-01' '32|qwen3.6:35b-a3b|23|moe|daily|no|x' '8|gone:1b|1|dense|daily|yes|y' > "$c"
export FAKE_LIVE="llama3.3:70b qwen3.6:35b-a3b"
out="$(refresh "$R" --check-models)"
check 'grep -qx "32|qwen3.6:35b-a3b|23|moe|daily|yes|x" "$c"' "live tag marked yes"
check 'grep -qx "8|gone:1b|1|dense|daily|no|y" "$c"' "dead tag marked no"
unset FAKE_LIVE

# ===========================================================================
# Status
# ===========================================================================
label="status with nothing running"
out="$(LLMSTACK_CONFIG_DIR="$T/nostatus" PATH="$T/deadcurl:$T/bin:$PATH" "$S" --status 2>&1)"; rc=$?
check "[ $rc -eq 0 ]" "exits 0"
expect 'Ollama +\(:11434\) +DOWN'; expect 'Open WebUI +\(:8080\) +DOWN +container'; expect 'SearXNG +\(local\) +DOWN'
label="status reads the config"
mkdir -p "$T/stcfg"; printf 'WEBUI_RUNTIME="venv"\nWEBUI_PORT="3000"\nSEARXNG_MODE="remote"\nSEARXNG_URL="http://10.0.0.5:8899"\n' > "$T/stcfg/config"
out="$(LLMSTACK_CONFIG_DIR="$T/stcfg" PATH="$T/deadcurl:$T/bin:$PATH" "$S" --status 2>&1)"
expect 'Open WebUI +\(:3000\) +DOWN +systemd'; expect 'SearXNG +\(remote\) +DOWN +http://10\.0\.0\.5:8899'

# ===========================================================================
printf '\n%d passed, %d failed\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ]
