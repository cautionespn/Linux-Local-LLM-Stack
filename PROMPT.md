# Prompt: local LLM stack installer for Ubuntu

Port of [MacOS-Local-LLM-Stack](https://github.com/cautionespn/MacOS-Local-LLM-Stack) (v3.6.1) to Ubuntu. Numbered so sections can be amended without rewriting; add new requirements under the matching section or under §16. Where this spec is silent, the macOS spec's reasoning applies.

---

## 1. Objective

A single, shareable shell script that provisions a private, self-hosted LLM stack on Ubuntu, a GitHub-style `README.md`, and GitHub Actions workflows that lint, unit-test and **really install** the stack on a GitHub-hosted Ubuntu runner.

## 2. Target environment

- Ubuntu **24.04 LTS** and **26.04 LTS**, amd64 and arm64. Refuse other distributions and releases in preflight with a clear message; 22.04 is out of scope (standard support ends May 2027).
- bash. The script is run by a normal user with sudo rights, or by root; it calls `sudo` only for the steps that need it. When run as root with `SUDO_USER` set, per-user output (shell commands' owner, group membership) is for `SUDO_USER`.
- Assume a fresh server install, administered over SSH, with no desktop.
- No assumption about user names or paths beyond the FHS locations in §7. Nothing specific to the author's network.

## 3. Deliverables

1. `llmstack-ubuntu.sh` — one file, executable, no companion scripts.
2. `README.md` — GitHub conventions.
3. `.github/workflows/ci.yml` — lint, unit tests with stubbed hardware and services, and an end-to-end install/uninstall on a real runner (§15).
4. `.github/workflows/release-asset.yml` — attach the script to each published release, refusing when the tag and `SCRIPT_VERSION` differ; the README's Quick start downloads `releases/latest/download/llmstack-ubuntu.sh`.
5. `.shellcheckrc` — only lint configuration; disable nothing that doesn't fire.
6. `LICENSE` — GNU GPL v3; the script header and README say so and point at it.

## 4. Stack

| Component | Purpose | How it runs |
|---|---|---|
| Ollama | inference | systemd `ollama.service`, user `ollama` |
| Open WebUI | web front-end | Docker container (default) or uv-managed Python 3.11 venv under systemd |
| SearXNG | private web search | Docker container, or a remote instance |
| Docker Engine | container runtime | Docker's official apt repository; only when a local container is needed |

Open WebUI's runtime is the user's choice: `--webui-runtime docker` (default) or `--webui-runtime venv`. Default to Docker because Open WebUI supports only Python 3.11–3.12 and Ubuntu 26.04 ships 3.14; the venv path gets 3.11 from `uv`, never from the system Python.

## 5. Ollama

- Install with Ollama's **documented manual method**: download `ollama-linux-${ARCH}.tar.zst` from `https://ollama.com/download` (optionally `?version=`), extract to `/usr/local`, create the system user `ollama` (`useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama`), add it to `render` and `video` when those groups exist, and write `/etc/systemd/system/ollama.service` matching the official unit. When an AMD GPU is present on amd64, also extract `ollama-linux-amd64-rocm.tar.zst`, as the official installer does.
- **Do not use `install.sh`.** It installs NVIDIA's CUDA driver whenever it finds an NVIDIA GPU without a working `nvidia-smi`, with no option to decline (verified in v0.35.0's source).
- **NVIDIA driver:** if a card with vendor `10de` is present and `nvidia-smi` does not work, explain and ask (default no). Yes runs `ubuntu-drivers install` (Canonical's supported route) and reports that a reboot is needed; no continues CPU-only and prints the command to run later. `--nvidia-driver install|skip` answers the question non-interactively.
- AMD: no driver installation. Report whether `/dev/kfd` exists (ROCm) and state that on 26.04 ROCm is not on AMD's support list, so Vulkan is the path. Intel: Vulkan only; report that integrated GPUs need `OLLAMA_IGPU_ENABLE=1`, which the script does not set by default.
- Settings go in a drop-in, `/etc/systemd/system/ollama.service.d/llmstack.conf`, never by editing the unit. Keep `OLLAMA_HOST=127.0.0.1:11434`.
- Remove the extracted `lib/ollama` directory before upgrading, as the official instructions require.

## 6. Open WebUI and SearXNG

- **Docker runtime:** one Compose project at `/opt/llmstack/compose.yaml`, services `open-webui` (`ghcr.io/open-webui/open-webui:main`) and `searxng` (`docker.io/searxng/searxng:latest`), `restart: unless-stopped`.
  - Open WebUI uses `network_mode: host` so it reaches Ollama on `127.0.0.1` and ufw rules apply normally (published ports bypass ufw; host networking doesn't publish). Set `PORT`, `OLLAMA_BASE_URL=http://127.0.0.1:11434`, `DATA_DIR`, and read `WEBUI_SECRET_KEY` from `/etc/llmstack/openwebui.env` (mode 0600).
  - SearXNG publishes `127.0.0.1:${SEARXNG_PORT}:8080` only.
- **venv runtime:** `uv` installs to `/usr/local/bin`; `uv venv --python 3.11 /opt/llmstack/openwebui-venv`; install the CPU build of torch before `open-webui` (the default pulls CUDA builds; open-webui#29490). A system user `open-webui` runs `llmstack-openwebui.service` with `EnvironmentFile=/etc/llmstack/openwebui.env`, `WorkingDirectory` and `DATA_DIR` under `/var/lib/llmstack/open-webui`, `LimitNOFILE=65536`.
- **SearXNG settings** at `/etc/llmstack/searxng/settings.yml`: `use_default_settings: true`, a generated `secret_key`, `limiter: false` (a private instance needs no Valkey), `formats: [html, json]` (Open WebUI needs json).
- `--searxng-url URL` uses a remote instance and installs no container for search. Docker is then needed only for the Docker runtime.
- Web search settings are Open WebUI "ConfigVar" values: set `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE=searxng` and `SEARXNG_QUERY_URL` in the environment for the first launch, and tell the user that after first launch the admin settings page is authoritative.
- On Linux, containers restart at boot with no one logged in. The macOS reboot limitation does not exist here; say so in the README.

## 7. Files

| Path | Contents |
|---|---|
| `/etc/llmstack/config` | installer settings (0644) |
| `/etc/llmstack/models.catalog` | model catalogue (0644), never overwritten silently |
| `/etc/llmstack/openwebui.env` | `WEBUI_SECRET_KEY` and Open WebUI settings (0600, root) |
| `/etc/llmstack/searxng/settings.yml` | SearXNG config |
| `/opt/llmstack/` | Compose file, or the venv |
| `/var/lib/llmstack/open-webui/` | Open WebUI data (accounts, chats) |
| `/usr/local/bin/llm{status,start,stop,upgrade}` | shell commands (small scripts, not rc-file functions: no alias collisions, any shell) |

`LLMSTACK_CONFIG_DIR` overrides `/etc/llmstack` (for tests and unusual layouts). A read-only mode run by a non-root user without a catalogue uses the built-in one in memory and writes nothing.

## 8. Modes and CLI

Modes: `--install` (default), `--update`, `--status`, `--recommend`, `--sync-models`, `--benchmark`, `--uninstall`, `--check-models`, `--refresh-catalog`, `--refresh-catalog-apply`, `--version`, `--help`.

Options: `--webui-runtime docker|venv`, `--searxng-url URL`, `--searxng-port PORT`, `--webui-port PORT`, `--model TAG`, `--no-model`, `--ollama-version X.Y.Z`, `--nvidia-driver install|skip`, `--yes` (answer yes to the install's own confirmations, never to uninstall or removal prompts), `--discover`.

The macOS rules for `--help`, `--recommend`/`--status` being read-only, the guided uninstall (per-artifact, default no, data needs two confirmations), `--update` (back up data first, restart even if a step fails), port validation and port-conflict reporting, the catalogue-maintenance modes and `--sync-models` all carry over unchanged in intent.

- `--benchmark`: for each installed current pick, run a fixed prompt through `/api/generate` with `num_predict` 128, report tok/s (`eval_count / eval_duration`) and the CPU/GPU split from `/api/ps`. Warn when a dense model is below 8 tok/s or not 100% on GPU when a GPU is in use. Read-only apart from loading models.

## 9. Hardware detection and sizing

- **GPUs** from `/sys/class/drm/card*/device/{vendor,class}` (no lspci needed): `0x10de` NVIDIA, `0x1002` AMD, `0x8086` Intel.
  - NVIDIA VRAM: `nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits` (requires a working driver).
  - AMD VRAM: `mem_info_vram_total` in sysfs (world-readable). Under 2 GiB of VRAM means an APU carve-out: treat as integrated.
  - Intel: no reliable VRAM source, so Intel GPUs never size the picks (see §16.1).
- **Sizing pool:** the largest single discrete GPU with a working runtime (Ollama keeps a model on one GPU when it fits). Budget = 75% of its VRAM, leaving room for the KV cache and Ollama's reservation. No dense-speed gate on a discrete GPU: anything that fits in VRAM is fast.
- **No usable discrete GPU** (CPU-only, integrated GPU, or NVIDIA without a driver): budget = 70% of `MemTotal`, plus the dense-speed gate. Bandwidth estimate = configured DIMM speed (from `udevadm info -e`, `MEMORY_DEVICE_*_CONFIGURED_SPEED_MTS`) × 8 bytes × 2 channels; if unavailable, 51 GB/s (DDR4-3200 dual channel). Cap = bandwidth × 0.65 ÷ 8 tok/s. MoE is exempt.
- **MIN_RAM_GB** keeps its meaning as machine class and is compared with system RAM, not VRAM.
- `--recommend` shows every GPU found, which one sizes the picks and why, and whether each vendor's runtime looks usable.
- Spilling past VRAM is never recommended.

## 10. Catalogue

Identical in format and rows to MacOS-Local-LLM-Stack v3.6.1 (`Catalogue-Generation: 3.4.0`), including the refresh-proposal rules (§10.19 of the macOS spec). Keep the generation numbers in step across the repositories.

## 11. Failure modes to pre-empt

1. `WEBUI_SECRET_KEY`: generate with `openssl rand -hex 32`, persist 0600, reuse. Without it `open-webui serve` writes a key into its working directory.
2. `DATA_DIR` pinned explicitly for both runtimes; the pip default is inside site-packages.
3. Docker bind-mount paths must exist as files before the first `up`, or Docker creates directories.
4. SearXNG listens on 8080 in the container; publish host-port:8080.
5. Remove conflicting distro packages (`docker.io`, `docker-compose`, `docker-compose-v2`, `podman-docker`, `containerd`, `runc`) only after the user confirms, before installing Docker's packages.
6. Adding a user to the `docker` group grants root-equivalent access. Do not do it; the shell commands use sudo.
7. The official unit uses `WantedBy=default.target`; use `multi-user.target` so it starts on headless boots.
8. Every `curl` has `--max-time`; readiness polls real endpoints.
9. The catalogue lookup functions never abort under `pipefail` when nothing matches.
10. Catalogue sizes may be decimal: compare in awk.

## 12. Script quality

`set -euo pipefail`, idempotent, shellcheck-clean with nothing disabled globally, colour only when stdout is a terminal, `--max-time` on every network call, comments explain why. Match the macOS script's structure where the platforms agree, so fixes can be carried across.

## 13. Documentation

README covers what it installs, requirements, Quick start, modes and options, runtime choice, hardware sizing (with the honest note that GPU paths are verified only against simulated tools until run on real hardware), the catalogue, syncing and benchmarking, reboot behaviour, remote SearXNG, updating, uninstalling, file layout, ports and firewall, security, troubleshooting, FAQ, design notes and a changelog.

## 14. Working style

As in the macOS spec: state decisions and trade-offs first, verify current facts, never invent model tags, say what is and isn't verified.

## 15. CI

- **Lint:** `bash -n`, shellcheck via `.shellcheckrc`, shebang, actionlint.
- **Unit (no network needed):** CLI validation; `--recommend` with stub `nvidia-smi`, sysfs trees (via an overridable root, `LLMSTACK_ROOT`), and `udevadm` for each case — NVIDIA 24 GB, NVIDIA without driver, AMD 16 GB, AMD APU, Intel, CPU-only, multi-GPU; catalogue format and live tag guard; the sync and refresh stubs from the macOS repo.
- **End to end (real runner, `ubuntu-24.04`):** install with each runtime (`--model` a tiny tag, `--yes`, `--nvidia-driver skip`), assert `--status` reports every service up and Open WebUI answers, run `--benchmark`, reboot-equivalent restart of services, then `--uninstall` with scripted answers and assert nothing is left behind.
- **Ubuntu 26.04:** run the unit job in an `ubuntu:26.04` container; the end-to-end job needs systemd, so 26.04 end-to-end is unverified until run on a real 26.04 host. Say so in the README.

## 16. Extensions

<!-- Append refinements below, referencing the section amended. -->

### 16.1 Intel GPUs are unsized (amends §9)
`vulkaninfo` is not installed by default, and on integrated Intel GPUs the device-local heap is a share of system RAM, not VRAM. Intel GPUs are therefore listed but never size the picks; the machine is sized as CPU-only, and `--recommend` says Intel runs through Vulkan and that integrated GPUs need `OLLAMA_IGPU_ENABLE=1`. `--benchmark` measures real speed.

### 16.2 Tests live in `tests/unit.sh` (amends §3, §15)
The unit tests are one script, `tests/unit.sh`, run by CI on 24.04 and in an `ubuntu:26.04` container, and runnable locally without root or network. "No companion scripts" applies to the installer, which stays one file. CI also runs the unit tests against the latest macOS release's catalogue and warns (does not fail) when the rows differ.

### 16.3 Catalogue NOTES are per platform (amends §10)
Rows match the macOS generation in MIN_RAM, TAG, SIZE, ARCH, ROLE and VERIFIED. NOTES are worded for this platform (the macOS notes cite Apple chip tiers). The generation marker tracks the first six columns.

### 16.4 Catalogue writes go through sudo (amends §7, §8)
The catalogue lives in root-owned `/etc/llmstack`. Modes that change it (`--sync-models` replacement, `--check-models`, `--refresh-catalog*`) write via sudo. `--recommend` run by a user without cached sudo uses a private temporary copy of the built-in catalogue instead of prompting for a password; the install writes the real file once sudo is granted.

### 16.5 No per-user setup (amends §2)
The `llm*` commands are system-wide scripts in `/usr/local/bin` that call sudo when needed, and nobody is added to the `docker` group, so nothing is written for `SUDO_USER`.

### 16.6 Open WebUI venv upgrades (amends §6)
`torch` is upgraded from PyTorch's CPU index first, then only `open-webui` is upgraded (`--upgrade-package`), so the resolver keeps the CPU torch. The service user owns the package's `static/` folder, which Open WebUI rewrites at every start.

### 16.7 End-to-end coverage (amends §15)
Three jobs: amd64 with the Docker runtime (the runner's preinstalled Docker is used, and `--update` is exercised), amd64 with the venv runtime (the runner's Docker is purged first so the script installs Docker Engine from Docker's apt repository), and arm64 (`ubuntu-24.04-arm`) with the Docker runtime. Each installs a tiny model, checks services, loopback binding and the secret's mode, re-runs, restarts services, benchmarks, syncs answering no, then uninstalls answering yes and checks nothing is left.
