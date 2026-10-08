# llmstack-ubuntu

A single shell script that turns an Ubuntu machine into a private, self-hosted AI server.

Inference, a web front-end and private web search, all running locally as system services that come back after a reboot with nobody logged in.

```bash
./llmstack-ubuntu.sh --recommend   # see what this machine can run
./llmstack-ubuntu.sh               # install it
```

A port of [MacOS-Local-LLM-Stack](https://github.com/cautionespn/MacOS-Local-LLM-Stack) v3.6.1. The model catalogue, catalogue maintenance and `--sync-models` behave the same on both.

---

## Contents

- [What it installs](#what-it-installs)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What has been verified](#what-has-been-verified)
- [Modes](#modes)
- [Options](#options)
- [Open WebUI: Docker or venv](#open-webui-docker-or-venv)
- [How models are chosen](#how-models-are-chosen)
- [GPUs](#gpus)
- [The model catalogue](#the-model-catalogue)
- [Syncing models](#syncing-models)
- [Benchmarking](#benchmarking)
- [Remote SearXNG](#remote-searxng)
- [Commands](#commands)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [File layout](#file-layout)
- [Ports and firewall](#ports-and-firewall)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Design notes](#design-notes)
- [Development](#development)
- [Changelog](#changelog)
- [License](#license)

---

## What it installs

| Component | What it does | How it runs |
|---|---|---|
| [Ollama](https://ollama.com) | Runs the models | systemd `ollama.service`, as the `ollama` system user |
| [Open WebUI](https://openwebui.com) | Chat interface in the browser | Docker container (default), or a Python 3.11 virtualenv under systemd |
| [SearXNG](https://docs.searxng.org) | Private metasearch for Open WebUI's web search | Docker container, or a SearXNG you already run |
| [Docker Engine](https://docs.docker.com/engine/install/ubuntu/) | Container runtime | Docker's official apt repository, only when a local container is needed |
| [uv](https://docs.astral.sh/uv/) | Python 3.11 and packages for the venv runtime | `/usr/local/bin/uv`, venv runtime only |

It also recommends models for the hardware, pulls the best fit, writes `llmstatus`, `llmstart`, `llmstop` and `llmupgrade` to `/usr/local/bin`, and pre-configures Open WebUI's web search to use SearXNG.

## Requirements

- Ubuntu **24.04 LTS** or **26.04 LTS**, amd64 or arm64. Other releases are refused at preflight.
- A normal user with sudo rights, or root.
- systemd as init (not a container, or WSL without systemd).
- Internet access during install.
- Disk for models: typically 5 to 45 GB under `/usr/share/ollama`, plus about 5 GB for the Open WebUI image or virtualenv.
- For GPU acceleration: an NVIDIA card with a working driver, or an AMD card with ROCm or Vulkan. See [GPUs](#gpus).

## Quick start

```bash
# Download the latest release
curl -fLO https://github.com/cautionespn/Linux-Local-LLM-Stack/releases/latest/download/llmstack-ubuntu.sh
chmod +x llmstack-ubuntu.sh

# Inspect the machine first. Installs nothing, downloads nothing.
./llmstack-ubuntu.sh --recommend

# Install. It shows what it found and asks before changing anything.
./llmstack-ubuntu.sh
```

When it finishes, open `http://<this-machine>:8080` and create the first account. **The first account created becomes the administrator**, so do it straight away.

## What has been verified

| Path | Status |
|---|---|
| Install, restart, re-run, update, sync, benchmark and uninstall on Ubuntu 24.04 amd64 | Verified in CI on every push (GitHub-hosted runner, CPU only) |
| The same on Ubuntu 24.04 arm64, Docker runtime | Verified in CI (`ubuntu-24.04-arm` runner) |
| Docker Engine installed from Docker's apt repository | Verified in CI (the venv job removes the runner's Docker first) |
| Ubuntu 26.04 | Unit tests only, in an `ubuntu:26.04` container. A real install on 26.04 has not been run, because GitHub has no 26.04 runner. |
| NVIDIA, AMD and Intel GPU detection and sizing | Unit-tested against simulated `nvidia-smi` and sysfs trees only. Not yet run on real GPU hardware. |
| `--nvidia-driver install` (`ubuntu-drivers install`) | Not exercised in CI. |

If you run it on real GPU hardware or on 26.04, an issue with the output of `--recommend` and `--benchmark` is very welcome.

## Modes

| Mode | What it does |
|---|---|
| `--install` | Install or repair the stack. The default. Idempotent: safe to re-run, never overwrites your data or secret key. |
| `--recommend` | Show detected hardware and the models that fit. Installs nothing. |
| `--status` | Health of every component. Changes nothing. |
| `--sync-models` | Pull the recommended models you choose, update outdated builds, then offer each other installed model for removal. See [Syncing models](#syncing-models). |
| `--benchmark` | Measure real tok/s and the CPU/GPU split for each installed pick. |
| `--update` | Back up Open WebUI data, update Ollama, Open WebUI and SearXNG, then check the catalogue. |
| `--uninstall` | Guided teardown. Asks before removing each piece. |
| `--check-models` | Check every catalogue tag against the Ollama registry and correct the VERIFIED column. |
| `--refresh-catalog` | Write `models.catalog.proposed` for review. Never touches the live catalogue. Add `--discover` to look for new model families. |
| `--refresh-catalog-apply` | As above, then apply the proposal after a backup and confirmation. |
| `--version`, `--help` | |

## Options

| Option | Effect |
|---|---|
| `--webui-runtime docker\|venv` | How Open WebUI runs. Default `docker`. Remembered for later runs. |
| `--searxng-url URL` | Use an existing SearXNG instead of a local container. |
| `--searxng-port PORT` | Host port for the local SearXNG. Default 8888. |
| `--webui-port PORT` | Open WebUI's port. Default 8080. |
| `--model TAG` | Install (or benchmark) this model instead of the recommendation. |
| `--no-model` | Install the services without downloading a model. |
| `--ollama-version X.Y.Z` | Install this Ollama release instead of the latest. |
| `--nvidia-driver install\|skip` | Answer the NVIDIA driver question without a prompt. |
| `--yes` | Answer the install's own "go ahead?" question. Never answers removal, driver or uninstall questions. |
| `--discover` | With the refresh modes: scan the Ollama library for new families. |

Settings are stored in `/etc/llmstack/config`. A later run reads them, and flags override them.

```bash
# The venv runtime, with a SearXNG you already run elsewhere
./llmstack-ubuntu.sh --webui-runtime venv --searxng-url http://192.168.1.23:8899

# Services now, model later
./llmstack-ubuntu.sh --no-model
```

## Open WebUI: Docker or venv

**Docker (default).** The official `ghcr.io/open-webui/open-webui:main` image, run by Docker Compose from `/opt/llmstack/compose.yaml`. Updates are an image pull. The container uses host networking, so it reaches Ollama on `127.0.0.1` and your ufw rules apply to it (ports published by Docker bypass ufw).

**venv.** Open WebUI from PyPI in a virtualenv at `/opt/llmstack/openwebui-venv`, run by `llmstack-openwebui.service` as the unprivileged `open-webui` user. Open WebUI supports Python 3.11 and 3.12 only, and Ubuntu 26.04 ships 3.14, so the script uses [uv](https://docs.astral.sh/uv/) to fetch Python 3.11 into `/opt/llmstack/python`. It never touches the system Python. PyTorch's CPU build is installed first; without it, the dependencies pull several GB of CUDA libraries Open WebUI doesn't need.

Choose venv if you'd rather not run Open WebUI in Docker. A local SearXNG still needs Docker; pair venv with `--searxng-url` to avoid Docker entirely.

Switching is a re-run with the other `--webui-runtime`. Both use the same data directory, `/var/lib/llmstack/open-webui`, so accounts and chats carry over.
- **venv → docker:** the `llmstack-openwebui` service is stopped and its unit file removed. The script then asks, once, whether to delete the venv, its Python and uv's package cache under `/opt/llmstack` (several GB; the default is no, and `--yes` never answers it). Switching back rebuilds them.
- **docker → venv:** the Open WebUI container is removed; the image stays until `--uninstall`.

## How models are chosen

Within each role (daily, reasoning, coding, vision, light), the largest catalogue entry that passes three gates wins:

1. **It fits the budget.** With a usable discrete GPU: 75% of that GPU's VRAM, leaving the rest for the context (KV cache) and Ollama's own reservation. Without one: 70% of system RAM.
2. **The machine is big enough.** System RAM is at least the entry's `MIN_RAM_GB`.
3. **It will be fast enough.** Only without a discrete GPU, and only for dense models: estimated memory bandwidth must drive the model at 8 tok/s or better. Bandwidth is the configured DIMM speed (read from `udevadm`, no root needed) × 8 bytes × 2 channels, or 51 GB/s (DDR4-3200) when the speed can't be read. Mixture-of-experts models read only their active experts per token, so they're exempt.

A model that spills out of VRAM into system RAM runs many times slower, so spilling is never recommended. When the estimate and reality disagree, [`--benchmark`](#benchmarking) measures.

`--recommend` prints every number it used. With a GPU:

```
  GPUs:
    - NVIDIA GeForce RTX 4090  [discrete, 24.0 GB]  driver working
  Sizing:            GPU NVIDIA GeForce RTX 4090: 75% of 24 GB VRAM = ~18.0 GB for model weights
                     No dense-speed cap: a model that fits in VRAM runs fast.
```

Without one:

```
  Sizing:            CPU and RAM: 70% of 64 GB = ~44.8 GB for model weights
  RAM bandwidth:     ~51 GB/s (DDR 3200 MT/s, assumed; DIMM speed unreadable; 2 channels assumed)
  Dense model cap:   ~4.1 GB  (keeps dense models at 8 tok/s or better; MoE exempt)
```

## GPUs

| GPU | What the script does |
|---|---|
| **NVIDIA, driver working** | VRAM from `nvidia-smi`. Sizes the picks. |
| **NVIDIA, no driver** | Detected from sysfs. The script says so and asks whether to run `ubuntu-drivers install` (Ubuntu's recommended driver; needs a reboot). `--nvidia-driver install\|skip` answers ahead of time. Until the driver works, the machine is sized as CPU-only. The script never installs CUDA; Ollama ships its own CUDA libraries. |
| **AMD, 2 GB of VRAM or more** | VRAM from sysfs. Sizes the picks when ROCm (`/dev/kfd`) or a Radeon Vulkan driver is present. On amd64 the script also installs Ollama's ROCm libraries. AMD lists ROCm 7 for 24.04; on 26.04 use Vulkan (`mesa-vulkan-drivers`). The script installs no AMD drivers. |
| **AMD APU** (under 2 GB) | Integrated. Listed, sized as CPU-only. |
| **Intel** | Listed, never sizes the picks: Intel GPUs run through Ollama's Vulkan backend, and their VRAM can't be read reliably. Integrated GPUs also need `OLLAMA_IGPU_ENABLE=1` (see [FAQ](#faq)). |

With several GPUs, the single largest usable one sizes the picks, because Ollama keeps a model on one GPU when it fits there.

## The model catalogue

Picks come from `/etc/llmstack/models.catalog`, a plain text file you can edit:

```
# Format: MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
24|gemma4:26b-a4b-it-qat|16|moe|daily|yes|Gemma 4 26B MoE, about 4B active, QAT build. ...
```

- `# Last-Updated:` records when a person last reviewed the file. The script grades staleness from it (a note at 90 days, a warning at 180).
- `# Catalogue-Generation:` records which built-in catalogue the file descends from. It is shared with the macOS and Windows scripts: all three ship the same models, sizes and gates for a given generation (only the NOTES wording differs per platform). `--sync-models` offers to replace a catalogue from an older generation, with a backup.
- `VERIFIED` is `yes` when the tag was confirmed in the Ollama registry.

Keeping it current:

- `--check-models` probes every tag and fixes the VERIFIED column.
- `--refresh-catalog` writes a proposal beside the live file: dead tags commented out in place, newer variants in your families suggested as `# REVIEW:` comments you fill in. `--refresh-catalog-apply` applies it after showing the diff and asking. Only a confirmed apply sets `Last-Updated`.
- Every registry check is fail-soft: offline, nothing changes and nothing fails.

The catalogue is root-owned, so changes to it go through sudo. `--recommend` run without sudo rights uses the built-in catalogue if the file doesn't exist yet.

## Syncing models

```bash
./llmstack-ubuntu.sh --sync-models
```

1. Offers to replace a catalogue from an older generation (backup kept).
2. Lists the current picks and whether each is installed, current or **outdated** (an older build than the registry serves; compared by manifest digest, one small request, no download).
3. Asks, per model, which missing picks to pull and which outdated ones to update.
4. Checks disk space, then pulls everything chosen.
5. **Only if every pull succeeded**, offers each installed model that isn't a current pick for removal, one at a time, flagging embedding models Open WebUI may use for documents.

Every prompt defaults to no. A failed or interrupted pull removes nothing.

## Benchmarking

```bash
./llmstack-ubuntu.sh --benchmark            # every installed pick
./llmstack-ubuntu.sh --benchmark --model qwen3.5:9b
```

Each model is warmed up once, then generates 128 tokens at temperature 0. Tok/s comes from Ollama's own counters, and the CPU/GPU split from `/api/ps`. The output looks like this (illustrative numbers):

```
  MODEL                            TOK/S  PROCESSOR      VERDICT
  gemma4:26b-a4b-it-qat             94.2  100% GPU       OK
  qwen3.8:27b                       11.3  62% GPU        SPILLS to CPU (62% on GPU): expect a large slowdown
```

## Remote SearXNG

`--searxng-url http://host:port` skips the local container and points Open WebUI at an existing SearXNG. That instance must allow the `json` format (`search.formats` in its `settings.yml`), or Open WebUI's searches return 403.

The local SearXNG is configured for private use: JSON enabled, rate limiter off (so no Valkey), bound to `127.0.0.1` only.

Web search settings are applied on Open WebUI's **first** start. After that, Open WebUI keeps them in its database and **Admin Panel → Settings → Web Search** is authoritative, so changing the URL later means changing it there.

## Commands

Installed to `/usr/local/bin` for every user. They use sudo where needed.

| Command | Does |
|---|---|
| `llmstatus` | Health of each component |
| `llmstart` | Start everything |
| `llmstop` | Stop everything, freeing the memory models hold |
| `llmupgrade` | Runs `llmstack-ubuntu.sh --update` from where it was installed |

## Updating

```bash
llmupgrade        # or: ./llmstack-ubuntu.sh --update
```

It copies `/var/lib/llmstack/open-webui` to a timestamped backup first, then updates Ollama (the latest release, or `--ollama-version`), Open WebUI (image pull, or pip in the venv) and SearXNG, restarts them and checks the catalogue. Run `--sync-models` afterwards to update model builds.

## Uninstalling

```bash
./llmstack-ubuntu.sh --uninstall
```

Each step asks separately, and pressing Enter skips it: services, container images, `/opt/llmstack`, Open WebUI data (asked twice), backups, downloaded models, Ollama and its user, the `open-webui` user, the commands, `/etc/llmstack`, and optionally uv and Docker Engine. NVIDIA drivers are never touched. Removing Docker leaves `/var/lib/docker` in place.

## File layout

| Path | Contents |
|---|---|
| `/etc/llmstack/config` | Installer settings |
| `/etc/llmstack/models.catalog` | Model catalogue (yours to edit) |
| `/etc/llmstack/openwebui.env` | Open WebUI secret key, mode 0600 |
| `/etc/llmstack/searxng/settings.yml` | SearXNG settings |
| `/opt/llmstack/compose.yaml` | Containers (when Docker is used) |
| `/opt/llmstack/openwebui-venv`, `/opt/llmstack/python` | venv runtime |
| `/var/lib/llmstack/open-webui` | Accounts, chats, uploads, settings |
| `/usr/share/ollama/.ollama/models` | Downloaded models |
| `/usr/local/bin/ollama`, `/usr/local/lib/ollama` | Ollama |
| `/etc/systemd/system/ollama.service` | Ollama's unit, matching the official one |
| `/etc/systemd/system/ollama.service.d/llmstack.conf` | This script's Ollama settings (a drop-in, so the unit stays stock) |
| `/etc/systemd/system/llmstack-openwebui.service` | venv runtime only |
| `/usr/local/bin/llm*` | The four commands |

## Ports and firewall

| Service | Listens on | Reachable from |
|---|---|---|
| Ollama | `127.0.0.1:11434` | This machine only |
| Open WebUI | `0.0.0.0:8080` | Your network, subject to ufw |
| SearXNG (local) | `127.0.0.1:8888` | This machine only |

If ufw is enabled, allow Open WebUI from your LAN, for example: `sudo ufw allow from 192.168.1.0/24 to any port 8080 proto tcp`.

## Security

- **Secret key.** Generated once with `openssl rand -hex 32` into `/etc/llmstack/openwebui.env` (root-only) and reused on every run. Losing it logs everyone out.
- **No docker group.** Nobody is added to the `docker` group, which is root-equivalent. The commands use sudo.
- **Loopback by default.** Only Open WebUI listens beyond this machine.
- **Unprivileged services.** Ollama runs as `ollama`, the venv Open WebUI as `open-webui`.
- **Official sources only.** Ollama from ollama.com's release tarballs, Docker from download.docker.com, images from their publishers' registries, uv from astral.sh.

## Troubleshooting

**`This script supports Ubuntu 24.04 and 26.04`.** Check `/etc/os-release`. Other releases are out of scope.

**`systemd is not running`.** The installer needs systemd as init. Containers, and WSL without systemd, are not supported.

**Open WebUI doesn't answer after install.** The first start downloads an embedding model and can take a few minutes. Check `sudo docker logs llmstack-open-webui` (Docker) or `journalctl -u llmstack-openwebui -n 100` (venv).

**Web search returns nothing in Open WebUI.** Check SearXNG directly: `curl 'http://127.0.0.1:8888/search?q=test&format=json'`. A 403 means `json` is missing from `search.formats`. If SearXNG answers, check the URL in Admin Panel → Settings → Web Search.

**The GPU isn't used.** Run `--recommend` and read the GPU lines. For NVIDIA, `nvidia-smi` must work. Then run `--benchmark` and look at the PROCESSOR column. `journalctl -u ollama` shows which GPU Ollama found at start.

**`Port 8080 is already in use`.** Free it or pass `--webui-port`.

**Model pull fails.** Check the tag at [ollama.com/library](https://ollama.com/library) and the free disk space. The rest of the install completes without the model.

**The script stopped partway.** It prints where to look. Re-running is safe.

## FAQ

**Why not Ollama's `install.sh`?** When it sees an NVIDIA GPU it adds NVIDIA's CUDA repository and installs the driver, with no way to decline. This script uses Ollama's documented manual install instead, so installing a kernel driver is always your decision.

**Can it use my Intel iGPU or AMD APU?** Ollama can, through Vulkan, with `OLLAMA_IGPU_ENABLE=1`. It's off by default because shared-memory GPUs often aren't faster than the CPU. To try it: `sudo systemctl edit ollama`, add `Environment="OLLAMA_IGPU_ENABLE=1"` under `[Service]`, restart Ollama, then compare with `--benchmark`.

**Can I use it headless over SSH?** Yes, that's the intended setup.

**Does anything leave the machine?** Web searches, through your own SearXNG to the search engines it queries, and model downloads from Ollama's registry. Nothing else.

## Design notes

- **One file.** The installer is one script, like the macOS version, so the catalogue, registry checks and sync logic stay recognisably the same code on both platforms, and fixes carry across.
- **systemd drop-in.** The Ollama unit matches the official one; this script's settings live in a drop-in, so Ollama's own instructions keep working.
- **Sizing from the largest single GPU.** Splitting a model across GPUs works but is slower, and the recommendation should be the fast case.
- **MIN_RAM compares with system RAM**, even when a GPU sizes the picks. It's a machine-class floor, as on macOS.

## Development

```bash
bash tests/unit.sh          # no root, no network; stubs every system tool
shellcheck -x llmstack-ubuntu.sh tests/unit.sh
```

`PROMPT.md` is the specification the script is built to. CI (`.github/workflows/ci.yml`) runs lint, the unit tests on 24.04 and in a 26.04 container, and real installs on amd64 and arm64 runners.

## Changelog

### v1.0.2
- **A failed `--sync-models` pull now says why.** The script checks each failed tag against the Ollama registry. If the registry has the tag, it reports that the download itself was cut off and suggests a VPN, proxy or security software that may be resetting long downloads; downloaded parts are kept, so re-running resumes them. If the tag is missing it points at the Ollama library, and if the registry does not answer it says so. Previously every failure said "Check the tag", even when the tag was fine and a corporate security tool was dropping the connection.
- **`PROMPT.md`** updated from the maintainer's spec.

### v1.0.1
- **Switching Open WebUI from the venv runtime to docker now cleans up.** The `llmstack-openwebui` unit file is removed (it was only disabled), and the script offers to delete the venv, its Python and uv's package cache, several GB that docker doesn't use. Accounts and chats are shared by both runtimes and untouched. A new end-to-end step switches the venv job to docker and checks the result.
- **`PROMPT.md`** is now the full rebuild specification, exported from the maintainer's spec set.

### v1.0.0
First release. Port of MacOS-Local-LLM-Stack v3.6.1 to Ubuntu 24.04 and 26.04 (amd64, arm64): systemd services, Open WebUI via Docker or a uv-managed venv, NVIDIA/AMD/Intel/CPU detection with VRAM-based sizing, `--benchmark`, and the shared catalogue generation 3.4.0.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
