<!--
  Generated from 20-ubuntu-spec.md in the maintainer's private meta repository
  (Local-LLM-Stack-Meta) by tools/export_prompt.py. Do not edit here:
  change the spec there and export again.
-->

> **About this file.** This is the complete specification Linux-Local-LLM-Stack is built
> from: give it to Claude with an empty folder to rebuild the repository,
> or with this repository to change it. It names some companion documents
> (`01-shared-core.md`, `40-ci-and-testing.md`, `50-release-runbook.md`,
> `60-lessons-learned.md`, `80-backlog.md`). Those live in the maintainer's
> private meta repository. The rules they share with this spec are copied
> in below; the rest are the maintainer's working notes.

# 20 — Rebuild spec: Linux-Local-LLM-Stack (`llmstack-ubuntu.sh` v1.0.1)

**Use this prompt to rebuild the repository from an empty folder, or to change it.**
- Give the whole file to Claude with the instruction: *"Build (or update) the repository described here. Follow it exactly; where it is silent, ask."*
- It is self-contained. The `SHARED` blocks are kept identical to `01-shared-core.md`.
- Pair it with `50-release-runbook.md` to ship, and with `60-lessons-learned.md` to avoid repeating mistakes.

| | |
|---|---|
| Repository | `cautionespn/Linux-Local-LLM-Stack` (public, GPL v3) |
| Current version | 1.0.1 (2026-10-01; release `1.0.1` to be published by Chris). Previous: 1.0.0, released 2026-09-30, tag `1.0.0` |
| Catalogue generation | 3.4.0 |
| Verified on | CI only: real installs on GitHub `ubuntu-24.04` (amd64, both runtimes) and `ubuntu-24.04-arm`; unit tests on 24.04 and in an `ubuntu:26.04` container |
| Not verified | real GPU hardware, a real 26.04 install, `ubuntu-drivers install` |

---

## 1. Objective

The deliverables are:
- one shell script that provisions the stack on Ubuntu;
- a GitHub-style README;
- workflows that lint the script, unit-test it with stubbed hardware and services, and **really install** it on hosted runners.

## 2. Target environment

- **Ubuntu 24.04 LTS and 26.04 LTS**, amd64 and arm64.
  - Read `/etc/os-release` as data, never by sourcing it.
  - Refuse anything else in preflight; 22.04 is out of scope.
- **bash.** The script is run by a normal user with sudo rights, or by root, and calls `sudo` only where needed through `as_root`.
- **systemd** must be PID 1 (`/run/systemd/system`). Refuse containers and WSL without systemd.
- Fresh server installs, administered over SSH, no desktop.
- Nothing site-specific.
- **Test hooks:**
  - `LLMSTACK_CONFIG_DIR` overrides `/etc/llmstack`.
  - `LLMSTACK_ROOT` prefixes every hardware read (`/sys`, `/proc`, `/dev`, `/etc/os-release`, `/usr/share/vulkan`) so detection can run against a fake tree.

## 3. Deliverables

1. **`llmstack-ubuntu.sh`:** one file. The installer has no companion scripts.
2. **`README.md`.**
3. **`tests/unit.sh`:** about 170 checks, needing no root and no network (§15).
4. **`.github/workflows/ci.yml`** and **`.github/workflows/release-asset.yml`:**
   - The release workflow attaches the script and refuses a tag ≠ `SCRIPT_VERSION`.
   - The Quick start downloads `releases/latest/download/llmstack-ubuntu.sh`.
5. **`.shellcheckrc`:** the only lint config, with `external-sources=true` and nothing disabled globally. The inline directives, each with its reason:
   - `SC2016` on `STATUS_BODY` and the `sudo_line` command template
   - `SC2086` on the unquoted conflict-package list
   - `# shellcheck source=/dev/null` on the config `source`
6. **`LICENSE`:** GPL v3, stated in the script header and the README.
7. **`PROMPT.md`:** this file, exported with `tools/export_prompt.py` from the meta repo (a short preamble says the files it names live in the maintainer's private meta repo). Never edit it by hand; change this spec and export again.

## 4. Stack

| Component | How it runs |
|---|---|
| Ollama | systemd `ollama.service` (official unit, `WantedBy=multi-user.target`), user `ollama` |
| Open WebUI | `--webui-runtime docker` (default): official container via Compose; `--webui-runtime venv`: uv-managed Python 3.11 venv under systemd `llmstack-openwebui.service`, user `open-webui` |
| SearXNG | `docker.io/searxng/searxng:latest` container on `127.0.0.1:<port>:8080`, or remote via `--searxng-url` |
| Docker Engine | Docker's apt repository (deb822 `docker.sources`), only when a container is needed |
| uv | `/usr/local/bin/uv`, venv runtime only |

**Why Docker is the default:** Open WebUI supports Python 3.11–3.12 only, and Ubuntu 26.04 ships 3.14. The venv runtime gets 3.11 from uv and never touches the system Python.

## 5. Ollama

**Installation.** Skipped when Ollama is already installed and matches any `--ollama-version` pin; `--update` always reinstalls. Downloads use `curl -fL --max-time 3600`, with `--progress-bar` on a TTY and `-sS` otherwise. Use Ollama's **manual install**:
1. Download `https://ollama.com/download/ollama-linux-${ARCH}.tar.zst`, adding `?version=X.Y.Z` when `--ollama-version` is given.
2. Stop the service.
3. `rm -rf /usr/local/lib/ollama`, as the official instructions require.
4. `tar -C /usr/local --zstd -xf` the archive.
5. On amd64 with an AMD GPU, also extract `ollama-linux-amd64-rocm.tar.zst`.

**Never use `install.sh`.** It installs NVIDIA's CUDA driver whenever it finds an NVIDIA GPU without working `nvidia-smi`, with no opt-out. This was verified in v0.35.0's source.

**The service account and unit.**
- Create the user with `useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama`.
- Add it to the `render` and `video` groups when they exist.
- The unit file `/etc/systemd/system/ollama.service` contains:
  - `ExecStart=/usr/local/bin/ollama serve`
  - `User=ollama`, `Group=ollama`
  - `Restart=always`, `RestartSec=3`
  - a `PATH` environment line
  - `WantedBy=multi-user.target`
- Settings go only in the drop-in `/etc/systemd/system/ollama.service.d/llmstack.conf`: `Environment="OLLAMA_HOST=127.0.0.1:11434"`.
- Then `daemon-reload`, `enable`, `restart`, and wait up to 30 s for `/api/version`.

**The NVIDIA driver.**
- When a card with vendor `0x10de` exists but `nvidia-smi` does not work, explain and ask, defaulting to no.
- Yes runs `apt-get install -y ubuntu-drivers-common` and then `ubuntu-drivers install`, and reports that a reboot is needed.
- `--nvidia-driver install|skip` answers the question in advance. `--yes` never does.

**AMD and Intel.**
- AMD: no driver installation. Report whether `/dev/kfd` exists (ROCm). AMD lists ROCm 7 for 24.04; on 26.04, Vulkan is the path.
- Intel: Vulkan only. Integrated GPUs need `OLLAMA_IGPU_ENABLE=1`, which the script does not set.

## 6. Open WebUI and SearXNG

**Docker runtime.**
- One Compose project at `/opt/llmstack/compose.yaml` (`name: llmstack`), regenerated on every install.
- Service `open-webui`:
  - `ghcr.io/open-webui/open-webui:main`, container name `llmstack-open-webui`, `network_mode: host`, `restart: unless-stopped`
  - `env_file: /etc/llmstack/openwebui.env`
  - environment: `PORT`, `OLLAMA_BASE_URL=http://127.0.0.1:11434`, `DATA_DIR=/app/backend/data`, `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=searxng`, `SEARXNG_QUERY_URL=<url>/search?q=<query>`
  - volume `/var/lib/llmstack/open-webui:/app/backend/data`
- Host networking means it reaches Ollama on loopback, and **ufw rules apply**. Ports published by Docker bypass ufw.

**venv runtime.**
- Create the system user with `useradd -r -s /usr/sbin/nologin -d /var/lib/llmstack/open-webui -M -U open-webui`.
- Install uv, if it isn't already on PATH, with `curl -LsSf --max-time 120 https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh`.
- Run every uv command as root with `UV_PYTHON_INSTALL_DIR=/opt/llmstack/python` and `UV_CACHE_DIR=/opt/llmstack/.uv-cache`:
  1. `uv venv --python 3.11 /opt/llmstack/openwebui-venv`, only if `bin/python` is missing.
  2. `uv pip install --python /opt/llmstack/openwebui-venv/bin/python --upgrade torch --index-url https://download.pytorch.org/whl/cpu`
  3. `uv pip install --python /opt/llmstack/openwebui-venv/bin/python --upgrade-package open-webui open-webui`. This keeps the CPU torch (open-webui#29490).

  Without `--python`, uv run as root does not target the venv.
- `chown -R` the data directory and the package's `open_webui/static` folder to `open-webui`. Open WebUI rewrites `static` at every start.
- The unit `llmstack-openwebui.service`:
  - `User=`/`Group=open-webui`
  - `WorkingDirectory` set to the data dir
  - `EnvironmentFile=/etc/llmstack/openwebui.env`
  - `Environment=` lines: `DATA_DIR`, `OLLAMA_BASE_URL` and the web-search variables
  - `ExecStart=<venv>/bin/open-webui serve --host 0.0.0.0 --port <port>`
  - `Restart=always`, `RestartSec=5`, `LimitNOFILE=65536`
  - `After=network-online.target ollama.service`, `Wants=network-online.target`, `WantedBy=multi-user.target`
- **Switching from venv to docker** (`WEBUI_RUNTIME=docker` and the unit file exists), before the containers start:
  1. `systemctl disable --now llmstack-openwebui`, delete the unit file, `systemctl daemon-reload`. Always: the unit is regenerated if the runtime switches back.
  2. Still inside that "unit file exists" branch, so it is asked once, at the switch: if any of `$VENV_DIR`, uv's Python (`$UV_PYTHON_DIR`, `/opt/llmstack/python`) or uv's cache (`/opt/llmstack/.uv-cache`) exists, say their combined size (`du -sch`), that switching back rebuilds them and that the data is shared and untouched. Then ask `Delete the venv Open WebUI install (<size>)?` with `confirm` (defaults to no; `--yes` never answers it). Yes deletes all three; no prints the `sudo rm -rf` line for later. The cache must go too: uv hard-links packages from it into the venv, so deleting only the venv frees little.
  - Open WebUI data in `/var/lib/llmstack/open-webui` is shared by both runtimes and is never touched. The `open-webui` system user and `/usr/local/bin/uv` stay; `--uninstall` offers to remove them.
- Switching from docker to venv needs nothing extra: the regenerated compose file no longer has `open-webui`, and `up -d --remove-orphans` removes its container.

**The secret.**
- `/etc/llmstack/openwebui.env` (0600, root) holds `WEBUI_SECRET_KEY=$(openssl rand -hex 32)`.
- It is created once and reused.

**SearXNG settings** (`/etc/llmstack/searxng/settings.yml`, written once, never overwritten):
- `use_default_settings: true`
- `server.secret_key` generated
- `limiter: false` (a private instance needs no Valkey)
- `image_proxy: true`
- `search.formats: [html, json]` (Open WebUI needs json)

**Container settings.**
- SearXNG is a **second service, `searxng`, in the same `llmstack` Compose project**:
  - `container_name: llmstack-searxng` (CI asserts this name)
  - `restart: unless-stopped`
  - ports `127.0.0.1:<port>:8080`
  - env `SEARXNG_BASE_URL=http://127.0.0.1:<port>/`
  - volume: the directory `/etc/llmstack/searxng` at `/etc/searxng`
- The Compose file is written when the runtime is docker **or** SearXNG is local, so venv plus local SearXNG still uses Compose. When neither applies, the file is deleted.
- `--searxng-url` uses a remote instance and installs no SearXNG container. Docker is then needed only for the docker runtime.

**Web-search settings** are Open WebUI ConfigVars, applied at first launch only. The README says the admin page is authoritative afterwards.

**On Linux, containers restart at boot with nobody logged in.** The macOS reboot limitation does not exist here.

**Docker Engine install.**
- If `docker` and `docker compose` already work, use them.
- If `docker` and `docker compose` already work, also run `systemctl enable --now docker`.
- Otherwise, remove conflicting distro packages, **only after the user confirms**: `docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc`. Answering no aborts the install with an error.
- If any apt source already points at `download.docker.com/linux/ubuntu`, reuse it. Two sources with different `Signed-By` values make apt refuse to run.
- Otherwise add the keyring at `/etc/apt/keyrings/docker.asc` and the deb822 `/etc/apt/sources.list.d/docker.sources`, using `UBUNTU_CODENAME` and `dpkg --print-architecture`.
- Install `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`, then `enable --now docker`.
- **Never add anyone to the `docker` group** (root-equivalent).

## 7. Files and commands

| Path | Contents |
|---|---|
| `/etc/llmstack/config` | `WEBUI_RUNTIME`, `SEARXNG_MODE`, `SEARXNG_URL`, `SEARXNG_HOST_PORT`, `WEBUI_PORT`, `LLMSTACK_SCRIPT` (0644) |
| `/etc/llmstack/models.catalog` | catalogue (0644) |
| `/etc/llmstack/openwebui.env` | secret (0600) |
| `/etc/llmstack/searxng/settings.yml` | SearXNG |
| `/opt/llmstack/` | `compose.yaml`, or `openwebui-venv/` plus `python/` |
| `/var/lib/llmstack/open-webui/` | data; backups sit beside it as `open-webui.backup-YYYYMMDD-HHMMSS` |
| `/usr/share/ollama/.ollama/models` | models |
| `/usr/local/bin/llm{status,start,stop,upgrade}` | small scripts, not rc-file functions |

**The `llm*` commands.**
- `llmstatus` embeds `STATUS_BODY`, the same string `--status` evals.
- The other three call `sudo` when not root:
  - `llmstart` starts `ollama` and, in the venv runtime, `llmstack-openwebui`, then runs `docker compose up -d`.
  - `llmstop` stops them.
  - `llmupgrade` never calls sudo; it execs the recorded `LLMSTACK_SCRIPT --update "$@"`, or prints where to download the script.

**Root-owned catalogue.**
- Every write goes through `as_root` or `put_file` (`install -D -m`).
- When a user without cached sudo runs `--recommend` and no catalogue exists, the script writes the built-in catalogue to a temporary file, uses it, and deletes it on exit. It never prompts for a password.
- `settle_catalog` writes the real file once the install has sudo.

## 8. Modes and CLI

**Modes:**
- `--install` (default)
- `--update` (alias `--upgrade`)
- `--status`
- `--recommend`
- `--sync-models`
- `--benchmark`
- `--uninstall`
- `--check-models`
- `--refresh-catalog`
- `--refresh-catalog-apply`
- `--version`
- `--help` (also `-h`)

**Options:**
- `--webui-runtime docker|venv` (remembered)
- `--searxng-url URL` (must start with `http://` or `https://`)
- `--searxng-port PORT` (default 8888)
- `--webui-port PORT` (default 8080)
- `--model TAG`
- `--no-model`
- `--ollama-version X.Y.Z` (`^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$`)
- `--nvidia-driver install|skip`
- `--yes`
- `--discover`

Settings come from `/etc/llmstack/config` first; flags override them.
- `--searxng-port` also forces local mode and a `127.0.0.1` URL.
- `--searxng-url` forces remote mode, and wins if both are given.

**Install flow.**
1. Preflight: OS, architecture and systemd.
2. Print the detected system, the runtime and the SearXNG mode.
3. Port checks with `ss -ltnpH`, warning with the owning process. Holders matching `open-webui`, `python` or `docker` on the WebUI port, and `docker` on the SearXNG port, are expected on a re-run and not warned about.
4. Model choice: the daily pick, else the light pick, else none. `--model` skips the fit checks; `--no-model` skips the download.
5. A disk warning if free space is less than the model plus 10 GB.
6. `confirm_install` (`--yes` answers it).
7. `sudo -v` up front, then `settle_catalog`.
8. `apt-get install curl ca-certificates zstd openssl`.
9. The NVIDIA question.
10. Ollama.
11. Directories, the secret, Docker if needed, SearXNG settings, the venv if chosen, `compose up -d --remove-orphans` if needed.
12. Wait up to 60 s for SearXNG JSON.
13. Write the config and the commands.
14. Pull the model, trapping Ctrl-C.
15. Wait up to 240 s for Open WebUI.
16. The `SETUP COMPLETE` summary, plus a reboot note if a driver was installed.

An `EXIT` trap during install prints the exit code, the log commands (`journalctl -u ollama`, `journalctl -u llmstack-openwebui`, `docker compose logs`) and that re-running is safe.

**`--update`:**
- `sudo -v`.
- Back up the data dir with `cp -a`; abort if that fails.
- Force-reinstall Ollama.
- Venv runtime: stop the service, run the torch-then-open-webui upgrade, then start it, even if the upgrade failed.
- `compose pull` and `compose up -d --remove-orphans`.
- Wait 180 s.
- Run the catalogue age report and `--check-models`.
- Print the daily pick and point at `--sync-models`.

**`--uninstall`.** Begin, then nine steps. Each asks, defaulting to no:
1. Services, units and the drop-in.
2. Images.
3. `/opt/llmstack`.
4. Data (two confirmations), then the backups, then remove `/var/lib/llmstack` if it is empty.
5. Models.
6. Ollama binary, libraries and user, keeping `/usr/share/ollama` if the models were kept.
7. The `open-webui` user.
8. The commands.
9. `/etc/llmstack`.

Then two optional steps:
- **uv.**
- **Docker Engine:** purge the packages and the source and keyring, keeping `/var/lib/docker`.

NVIDIA drivers are never touched.

**`--benchmark`:**
- Requires `/api/version`. If none of the picks is installed and no `--model` is given, warn and exit 0.
- For each installed current pick, or `--model`: warm up with `num_predict 1`, then generate 128 tokens at temperature 0.
- tok/s = `eval_count / (eval_duration / 1e9)`.
- GPU share comes from `/api/ps` as `size_vram × 100 / size`. Strip the nested `details` object before splitting the JSON on `{`.
- Verdicts:
  - `SPILLS to CPU (<n>% on GPU)` when a GPU sizes the picks and the share is under 100%.
  - `SLOW: below 8 tok/s` for dense models.
  - `OK` otherwise.

<!-- SHARED:sync -->
### `--sync-models` (shared contract)

This mode brings installed models in line with the current picks. **The safety property is order: every chosen pull must succeed before anything is removed.** Every change needs a yes, every prompt defaults to no, and bare Enter means no.

1. **Daemon check.** `ollama list` must succeed. Otherwise say "Cannot reach Ollama. Start the stack (llmstart), then re-run. Nothing was changed." and exit 1.
2. **Catalogue lineage.** If the `Catalogue-Generation` marker is missing or older than the built-in generation:
   - Explain that newer models will not appear until the catalogue is replaced.
   - Say that a backup is kept and hand-added rows can be copied back.
   - Say that adding the current marker line stops the offer.
   - Then ask "Back up your catalogue and replace it with the built-in one?"
3. **Picks.** Compute every role's pick and collapse them to one line per unique tag, listing every role it serves. Treat a tag with no `:` as `:latest` everywhere. Show each pick as:

   ```
     <tag padded 30> <size> GB  <arch>  <state>  <roles>
   ```

   The state is one of:
   - `not installed`
   - `current`: the `ollama list` ID equals the first 12 hex characters of the SHA-256 of the manifest the registry serves for the tag.
   - `outdated`: the two differ.
   - `unchecked`: the registry was unreachable or the manifest could not be fetched.

   If no role has a pick, warn "Nothing in the catalogue fits this machine, so there is nothing to sync." and exit 0, before any registry check.

   Otherwise check reachability once. If the registry is unreachable, print "(Registry unreachable: installed picks were not checked for newer builds.)" and carry on.
4. **Choose.** Go through the picks in order:
   - For each `not installed` pick: "Pull <tag> (about <size> GB) for: <roles>?"
   - For each `outdated` pick: "Update <tag> for: <roles>? Your build is older than the registry's (download up to <size> GB)."
5. **Removal candidates** are installed models that are no current pick. Declining a pick's pull never makes it a removal candidate. If nothing is chosen and there are no candidates, say "Nothing to do: ..." and exit 0.
6. **Disk check.** Updates count at full size. If free disk is less than the chosen sizes plus 10 GB:
   - Warn, and say "Nothing was changed. To free space first, run --sync-models again, decline every pull, and answer yes to the removals you want."
   - Exit 1.
7. **Pull** everything chosen. On Ctrl-C during a pull, say "Pull interrupted. Nothing was removed. Re-run to resume the download." and stop: bash traps `INT`; PowerShell, where a stop skips `catch` but runs `finally`, prints it from a `finally` guarded by "not done and no ordinary error". If any pull fails, list the failures, say "no models were removed", and exit 1.
8. **Remove**, one model at a time:
   - Show the model's name and size.
   - If `ollama show` lists an `embedding` capability, warn that Open WebUI may use it for document search.
   - Ask "Remove <model>?"
9. **Summary.** Print a `SYNC COMPLETE` banner, then the Pulled, Updated, Removed and "Kept, not a current pick" lists, each showing `(none)` when empty. If anything was removed, add a reminder to choose a new default model in Open WebUI.

When stdin is a list of answers, as in tests, loops that prompt must not consume that list. In bash, iterate over fd 3.
<!-- /SHARED:sync -->

<!-- SHARED:registry -->
### Registry checks and catalogue maintenance (shared contract)

**Endpoint.** `https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`, with header `Accept: application/vnd.docker.distribution.manifest.v2+json`.
- 200 means live and 404 means dead; no auth is needed.
- Any other status, a timeout or a network error means **unknown**.

**Fail-soft, always.**
- An unknown never changes the catalogue.
- Every call has a timeout of 8–15 s.
- Reachability is checked once up front by probing `llama3.3:70b`. **Any 200 or 404 counts as reachable**, so the check survives that tag being retired. If the registry is unreachable, the mode reports that and exits 0 with nothing written.
- CI depends on this.

**`--check-models`.**
- Probes every tag and prints a LIVE/DEAD/???? line for each, then a summary.
- **Only if at least one VERIFIED value changes** (200 sets `yes`, 404 sets `no`), it takes a timestamped backup (`models.catalog.backup-YYYYMMDD-HHMMSS`) and rewrites the file.
- Otherwise, if any tag is dead, it points at `--refresh-catalog`.

**`--refresh-catalog`.** Writes `models.catalog.proposed` beside the live file and never touches the live file.
- Walk the live file **in order**. Comments and blank lines pass through untouched, so headings keep their rows.
- A live row is rewritten with `VERIFIED=yes`. MIN_RAM, ARCH, ROLE and NOTES are preserved verbatim; they are human judgment.
- A dead row is commented out **in place**: `# DEAD (404 at registry, review/remove): <row with VERIFIED=no>`.
- An unknown row passes through unchanged.
- Candidates are found by probing `<family>:<size>` and `<family>:<size>-instruct` for each catalogue family. The sizes are 1.5b 3b 4b 7b 8b 9b 11b 12b 14b 22b 27b 30b 32b 34b 70b 72b. Only tags that are live and not already present count.
- With `--discover`, the script also scrapes `https://ollama.com/library` for family names and keeps those whose `:latest` is live. The scrape is fragile HTML, so it is wholly optional and fail-soft.
- Each candidate is appended **only as a comment**: `# REVIEW: REVIEW|<tag>|REVIEW|REVIEW|REVIEW|yes|Confirmed in the registry. Set MIN_RAM, SIZE, ARCH, ROLE and NOTES.`
  - The first one is preceded by `# --- Suggested by --refresh-catalog: set every REVIEW field, then delete '# REVIEW: ' ---`. That header is never repeated.
  - A candidate already present as a `# REVIEW:` line is not suggested again.
- The proposal leaves `Last-Updated` alone.
- Field trimming must not mangle apostrophes. In bash that means parameter expansion, never `xargs`.

**`--refresh-catalog-apply`.**
- Builds a proposal **in this run**. A leftover `.proposed` file from an earlier run is never applied, notably when the registry is now unreachable.
- Shows the diff and asks, defaulting to no.
- On yes: backs up, replaces the live file, sets `Last-Updated` to today, and deletes the proposal.

**`--update`** runs `--check-models` after updating.
<!-- /SHARED:registry -->

## 9. Hardware detection and sizing (Ubuntu)

**GPUs** come from `/sys/class/drm/card*/device/{vendor,class}`. Skip connector entries (names containing `-`) and keep class `0x03*`.

| Vendor | Source | Kind | Runtime |
|---|---|---|---|
| `0x10de` NVIDIA | `nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits` when it works (exact MiB); otherwise a sysfs row | discrete | `ok` / `no-driver` |
| `0x1002` AMD | `mem_info_vram_total` (bytes) | discrete if ≥ 2048 MiB, else integrated (APU) | `rocm` if `/dev/kfd`, `vulkan` if a `radeon_icd*.json` exists, else `none` |
| `0x8086` Intel | none | `unsized` | `vulkan` |

Names come from `lspci -s <slot>` when available, else "NVIDIA GPU", "AMD GPU" or "Intel GPU". With a working NVIDIA driver, the sysfs NVIDIA rows are skipped so each card is listed once.

**Sizing pool:** the largest single *discrete* GPU with a usable runtime (`nvidia:ok`, `amd:rocm`, `amd:vulkan`). Ollama keeps a model on one GPU when it fits.

- **With a usable GPU:**
  - The budget is 75% of that GPU's VRAM, to one decimal.
  - There is no dense cap: anything that fits in VRAM is fast.
- **Without one** (CPU-only, integrated only, or NVIDIA without a driver):
  - The budget is 70% of RAM.
  - RAM is `MemTotal`, rounded to the nearest GiB, with 8 as the fallback.
  - Bandwidth = DIMM MT/s × 8 × 2 channels ÷ 1000. MT/s is the highest `MEMORY_DEVICE_*_CONFIGURED_SPEED_MTS`, else `*_SPEED_MTS`, from `udevadm info -e` (no root needed), else 3200 assumed.
  - Dense cap = bandwidth × 0.65 ÷ 8.
- **Free disk:** `df -BG /usr/share`.

The report lists:
- OS (with an "unsupported" note when it is), CPU, threads, RAM and free disk;
- each GPU as `name [kind, size] runtime-text`;
- the sizing line;
- bandwidth and dense cap, or "No dense-speed cap";
- notes for no-driver NVIDIA, driverless AMD and Intel.

Spilling past VRAM is never recommended.

<!-- SHARED:catalogue -->
### Model catalogue (shared contract, generation 3.4.0)

**Format.** One plain-text file. Pipe-delimited and hand-editable:
- `#` starts a comment.
- Blank lines are ignored.
- CRLF line endings are accepted on read.
- Files are written with LF.

Each data row is:

```
MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
```

| Column | Meaning |
|---|---|
| `MIN_RAM_GB` | Minimum **system** RAM (machine class). Compared with system RAM even when a GPU sizes the picks. |
| `TAG` | Exact Ollama tag, `name:tag`. Never invent one. |
| `SIZE_GB` | Download size of that exact tag. May be a decimal (`7.6`). |
| `ARCH` | `dense` or `moe`. |
| `ROLE` | `daily`, `reasoning`, `coding`, `vision` or `light`. |
| `VERIFIED` | `yes` only if the tag was confirmed in the Ollama registry; otherwise `no`. |
| `NOTES` | Free text, worded per platform. Never parsed. |

**Number handling.**
- Never feed a catalogue value to integer arithmetic.
- Compare sizes as decimals, culture-invariant: awk in bash, `[double]::Parse` with `InvariantCulture` in PowerShell.
- A row whose `MIN_RAM_GB` or `SIZE_GB` is not numeric (for example still `REVIEW`) is never picked.

**Header lines.**
- **`# Last-Updated: YYYY-MM-DD`** records when a *person* last reviewed the file.
  - Graded: under 90 days is recent; 90 to 180 is worth a look; over 180 is very likely stale.
  - `--recommend` and `--update` report the grade.
  - No tooling changes this line, except a confirmed `--refresh-catalog-apply`, which sets it to today.
- **`# Catalogue-Generation: X.Y.Z`** records which built-in catalogue the file descends from.
  - It is the MacOS-Local-LLM-Stack version in which the built-in rows last changed. That is currently **3.4.0**.
  - It is shared by all three repositories and bumped in all three together, only when the rows change.
  - A missing or older marker means "predates the built-in catalogue". `--recommend` notes it, and `--sync-models` offers a backed-up replacement.
  - Lineage is never judged from `Last-Updated`.

**Lifecycle.**
- The script writes the built-in catalogue on first use if none exists.
- It never overwrites an existing catalogue silently.
- What a read-only mode does when it cannot write differs per platform; each spec says which:
  - macOS: the catalogue is in the user's home, so it can always write.
  - Ubuntu: uses a temporary copy, deleted on exit.
  - Windows: uses the built-in text in memory.

**Selection.** Within each role, the **largest** entry that passes all three gates wins:
1. `SIZE_GB` ≤ the budget.
2. System RAM ≥ `MIN_RAM_GB`.
3. Dense entries only, and only when the platform defines a dense cap:
   - `SIZE_GB` ≤ dense cap.
   - Dense cap (GB) = bandwidth (GB/s) × 0.65 ÷ 8 tok/s.
   - Named constants: `DENSE_EFFICIENCY_PCT=65` (a percentage, divided by 100) and `DENSE_MIN_TPS=8`; on Windows, `$Script:DenseEfficiencyPct` and `$Script:DenseMinTps`.
   - MoE entries are exempt: only their active experts are read per token.

The bandwidth gate is the only MoE preference. Do not hard-prefer MoE: a dense model that passes may be better than any MoE that fits. Within a role, size tracks quality, so never list several quantizations of one model. Roles are shown in this order: daily, reasoning, coding, vision, light. The install pulls the daily pick, or the light pick when no daily pick fits.

**Built-in rows, generation 3.4.0.** These columns are identical on every platform; only NOTES differ.

| MIN_RAM_GB | TAG | SIZE_GB | ARCH | ROLE | VERIFIED |
|---|---|---|---|---|---|
| 4 | granite4.2:3b | 2.2 | dense | light | yes |
| 8 | qwen3.5:4b | 3.4 | dense | daily | yes |
| 16 | gemma4:12b | 7.6 | dense | daily | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | daily | yes |
| 32 | qwen3.6:35b-a3b | 23 | moe | daily | yes |
| 8 | qwen3.5:4b | 3.4 | dense | reasoning | yes |
| 16 | gemma4:12b | 7.6 | dense | reasoning | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | reasoning | yes |
| 32 | qwen3.8:27b | 18 | dense | reasoning | yes |
| 8 | qwen3.5:4b | 3.4 | dense | coding | yes |
| 16 | qwen3.5:9b | 6.6 | dense | coding | yes |
| 24 | devstral-small-2:24b | 15 | dense | coding | yes |
| 32 | qwen3.6:35b-a3b-coding | 23 | moe | coding | yes |
| 8 | qwen3.5:4b | 3.4 | dense | vision | yes |
| 16 | gemma4:12b | 7.6 | dense | vision | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | vision | yes |
| 32 | qwen3.6:35b-a3b | 23 | moe | vision | yes |

The file groups these under comment headings: `# --- Light ...`, `# --- Daily drivers ...`, `# --- Reasoning ...`, `# --- Coding ...` and `# --- Vision ...`. Above them is a header that explains the format, the two header lines, the three gates, why architecture matters, and the VERIFIED column. All tags were verified live against the registry on 2026-09-30 and are re-checked by CI on every push.
<!-- /SHARED:catalogue -->

**Ubuntu and Windows NOTES column.** These are the exact row texts, in file order; Windows uses the same.

```
4|granite4.2:3b|2.2|dense|light|yes|IBM Granite 4.2 3B. Tiny and fast, with a thinking mode. The floor: fits machines under 8 GB, such as small VMs.
8|qwen3.5:4b|3.4|dense|daily|yes|Qwen 3.5 4B. Strongest general model under 5 GB. Text and image input.
16|gemma4:12b|7.6|dense|daily|yes|Google Gemma 4 12B. Strong all-rounder for 16 GB machines. Multimodal.
24|gemma4:26b-a4b-it-qat|16|moe|daily|yes|Gemma 4 26B MoE, about 4B active, QAT build. The strong MoE that fits a 24 GB budget.
32|qwen3.6:35b-a3b|23|moe|daily|yes|Qwen 3.6 35B MoE, 3B active. Fast even on a CPU. Multimodal. Needs 32 GB of RAM or more.
8|qwen3.5:4b|3.4|dense|reasoning|yes|Qwen 3.5 4B with its thinking mode.
16|gemma4:12b|7.6|dense|reasoning|yes|Gemma 4 12B. Strong maths and reasoning for its size.
24|gemma4:26b-a4b-it-qat|16|moe|reasoning|yes|Gemma 4 26B MoE. Reasoning on machines too slow for a dense 27B.
32|qwen3.8:27b|18|dense|reasoning|yes|Qwen 3.8 27B. Top small open model on independent indexes. Dense: fits a 24 GB GPU; on a CPU only fast memory clears the speed gate. Uses many tokens.
8|qwen3.5:4b|3.4|dense|coding|yes|Qwen 3.5 4B. Best coding option under 5 GB.
16|qwen3.5:9b|6.6|dense|coding|yes|Qwen 3.5 9B. Stronger agentic coding than Gemma 4 12B.
24|devstral-small-2:24b|15|dense|coding|yes|Mistral Devstral Small 2 24B. Strong agentic coding. Dense: best on a 24 GB GPU.
32|qwen3.6:35b-a3b-coding|23|moe|coding|yes|Qwen 3.6 35B MoE with its coding sampling preset. Same weights as the daily tag.
8|qwen3.5:4b|3.4|dense|vision|yes|Qwen 3.5 4B. Image input on the smallest machines.
16|gemma4:12b|7.6|dense|vision|yes|Gemma 4 12B. Image input.
24|gemma4:26b-a4b-it-qat|16|moe|vision|yes|Gemma 4 26B MoE. Image input.
32|qwen3.6:35b-a3b|23|moe|vision|yes|Qwen 3.6 35B MoE. Leads Gemma 4 26B on vision evals.
```

**Pinned picks.** The tests check these exact numbers.

| Fake machine | Expected |
|---|---|
| CPU, 16 GB, DDR5-5600 | ~90 GB/s, cap 7.3, budget 11.2; daily `qwen3.5:4b`, coding `qwen3.5:9b`, no `gemma4:12b` |
| CPU, 64 GB, DIMM speed unreadable | 3200 assumed, ~51 GB/s, cap 4.1; daily `qwen3.6:35b-a3b`, reasoning `gemma4:26b-a4b-it-qat`, coding `qwen3.6:35b-a3b-coding`, no `qwen3.8:27b` |
| 7 GB VM | light `granite4.2:3b` only |
| NVIDIA RTX 4090 (24564 MiB), 64 GB | budget 18.0; daily `gemma4:26b-a4b-it-qat`, reasoning `qwen3.8:27b`, coding `devstral-small-2:24b` |
| AMD 16 GB (16368 MiB) + ROCm, 32 GB | budget 12.0; daily `gemma4:12b`, coding `qwen3.5:9b` |
| NVIDIA 12 GB + AMD 24 GB | the AMD card sizes |

## 10. Platform failure modes to pre-empt

1. Generate the secret with `openssl rand -hex 32`, persist it at 0600, and reuse it.
2. Pin `DATA_DIR` explicitly for both runtimes; the pip default is inside site-packages.
3. Bind-mount sources must exist as files before the first `up`, or Docker creates directories.
4. SearXNG listens on 8080 inside the container.
5. Conflicting packages are removed only on a yes. Reuse an existing Docker apt source.
6. No `docker` group membership.
7. `WantedBy=multi-user.target`, not `default.target`.
8. Every `curl` has `--max-time`.
9. **Lookups never abort under `pipefail` when nothing matches.** End them with `|| true`.
10. Catalogue sizes may be decimal: compare in awk.
11. **ShellCheck versions differ.** Lint must pass on 0.9.0, which is the runner's apt version, as well as 0.10 and 0.11. 0.9 flags `A && B || C` (SC2015) where 0.11 doesn't, so write those as `if` statements.

## 11. Script quality

- `set -euo pipefail` and idempotent.
- Colour only on a terminal.
- `--max-time` everywhere.
- Comment *why*.
- Keep the macOS script's function names and structure where the platforms agree (`best_for_role`, `field`, `_trim`, `registry_probe`, `build_catalog_proposal`, `sync_models`, `STATUS_BODY`), so fixes carry across.
- Build tip: the blocks shared with macOS (catalogue lookups, registry and refresh, sync) can be extracted mechanically from the macOS script. Then swap writes into `/etc/llmstack` for `as_root`/`put_file`, and make the catalogue writer take a destination path.

## 12. Documentation

The README covers:
- what it installs, requirements and the Quick start;
- a **verification table** saying exactly what CI proves and what it does not;
- modes, options and the runtime choice;
- sizing and GPUs, the catalogue, sync and benchmark;
- remote SearXNG, commands, update, uninstall, file layout;
- ports and ufw, security, troubleshooting, FAQ (including why not `install.sh`), design notes, development and changelog.

## 13. Working style

<!-- SHARED:working-style -->
### Working style (shared)

- State assumptions and design decisions before writing code. Name the options, weigh the trade-offs and justify the choice.
- Push back on risk or unneeded complexity instead of complying silently.
- Verify current facts (package names, image tags, model tags, endpoints, versions) instead of relying on recall. Say which ones were verified and which were not. **Never invent model tags.**
- Say plainly what is and is not verified, in the README too. A path tested only against stubs is not verified on real hardware.
- Deliver complete files, never diffs.
- Lint and test before delivering.
- Comment *why*, not *what*, especially at each workaround.
- Every network call has a timeout. Readiness polls real endpoints instead of sleeping.
- Every prompt defaults to no. Deleting Open WebUI data (accounts and chats) takes two confirmations; every other removal takes one. `--yes` (or `-Yes`) answers only the install's own go-ahead, never a removal, an uninstall, a driver install or a third-party licence.
- Idempotent: re-running is safe and never overwrites user data or the secret key.
<!-- /SHARED:working-style -->

## 14. CI (`.github/workflows/ci.yml`)

**Lint** (`ubuntu-24.04`):
- `bash -n` on the script and the tests.
- `shellcheck -x` on both.
- Shebang check.
- The header version equals `SCRIPT_VERSION`.
- actionlint 1.7.7, downloaded by its script.

**Unit** (`ubuntu-24.04`):
- `bash tests/unit.sh` (see `40-ci-and-testing.md` for the harness).
- Real read-only `--recommend` on the runner.
- A live tag guard: a 404 fails, anything else warns.
- A `continue-on-error` step that diffs the rows against the latest macOS release (`MACOS_SCRIPT`), warning on drift.

**Unit 26.04:** the same `tests/unit.sh` in `container: ubuntu:26.04`, as root.

**End to end:**
- Matrix: `ubuntu-24.04` docker, `ubuntu-24.04` venv, `ubuntu-24.04-arm` docker.
- `MODEL=smollm2:135m`.
- The venv job first purges the runner's Docker packages (`moby-*`, `docker*`, `containerd*`) so the apt install path is exercised.

Steps:
1. Install with `--yes --webui-runtime $RUNTIME --model $MODEL --nvidia-driver skip`.
2. Services are enabled and active. The model is listed. Open WebUI answers. SearXNG JSON works.
3. 11434 and 8888 are bound to 127.0.0.1 only.
4. Venv only: the service runs as `open-webui` (`ps -o user:20=`) and `docker-ce` is installed.
5. The secret file is mode 600.
6. `llmstatus` shows three UPs.
7. The env check reads the running process's environment: `/proc/<MainPID>/environ` for venv, `docker inspect` for docker. `systemctl show` shell-quotes values containing `<` and `>`.
8. A re-run keeps the secret.
9. Restart `ollama`, `llmstack-openwebui` and `docker`, and everything comes back.
10. `--benchmark` prints a row.
11. `yes n | --sync-models` finishes and the model is kept.
12. `--update` (amd64 docker only) leaves a backup.
12a. Venv job only, **switch to docker:** `printf 'y\n' | ./llmstack-ubuntu.sh --yes --webui-runtime docker --model $MODEL --nvidia-driver skip`. The step sets `pipefail`, so the installer's exit status survives the `tee`. The output contains the deletion question. Then `/etc/systemd/system/llmstack-openwebui.service`, `/opt/llmstack/openwebui-venv`, `/opt/llmstack/python` and `/opt/llmstack/.uv-cache` are gone, `systemctl cat llmstack-openwebui` fails, the `llmstack-open-webui` container runs, and Open WebUI answers on 8080.
13. `yes | --uninstall`, then check nothing is left.

Write each "gone" check as `if cmd; then fail; fi`: a bare `! cmd` never fails a step under errexit.

**CI Pass** needs every job.

`actions/checkout@v5` (Node 24). `permissions: contents: read`. Job timeouts: lint 5 min, unit 10, end-to-end 60. The docker end-to-end jobs also assert that the containers `llmstack-open-webui` and `llmstack-searxng` are running.

## Appendix — Version history

| Version | Change |
|---|---|
| 1.0.1 (2026-10-01) | Switching the runtime from venv to docker removes the unit file and offers to delete the venv (backlog 4g); end-to-end switch test; `PROMPT.md` exported from this spec |
| 1.0.0 (2026-09-30) | First release; PR #1. Fixes before merge: shellcheck 0.9 SC2015; venv env check via `/proc`; reuse an existing Docker apt source; checkout v5 |
