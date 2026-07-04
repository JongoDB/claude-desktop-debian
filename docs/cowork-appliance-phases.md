[< Back to index](index.md)

# Cowork appliance — phase specifications

Executable specifications for the six implementation phases of the [Cowork appliance design](cowork-appliance-design.md): scope, file layout, interfaces, acceptance criteria, and test plan per phase.

- Every shell deliverable follows the [bash style guide](styleguides/bash_styleguide.md) and is shellcheck-clean
- Every phase ships BATS coverage using the repo's existing conventions (sourced libs, stubbed commands, `mktemp` sandboxes)
- Validation happens at two levels: **CI-testable** (mocked, runs anywhere) and **hardware-verify** (needs a real box; tracked as a checklist per phase)

## Repository layout (all phases)

```
appliance/
├── setup.sh                 # Phase 1 — provisioning orchestrator
├── member.sh                # Phase 2 — member lifecycle
├── gen-sshconfigs.sh        # Phase 4 — managed-settings generator
├── lib/
│   ├── common.sh            # logging, os/pkg detection, run/dry-run gate
│   ├── engine.sh            # engine selection rules (official vs repo build)
│   ├── doctor.sh            # appliance-doctor check functions
│   └── profiles/
│       ├── kasmvnc.sh       # default session layer
│       ├── xrdp.sh          # protocol-native alternative
│       └── overlay.sh       # tailscale break-glass profile
├── testbench/
│   ├── setup.sh             # Phase 3 — test bench provisioning
│   ├── desktop-control-mcp.js  # Tier-2 MCP server (nested display control)
│   └── vm-bench-mcp.js      # Tier-3 MCP server (QEMU targets)
└── images/
    ├── cloud-init.yaml      # Phase 5 — VPS/mini-PC bootstrap
    └── README.md            # pi-gen recipe notes

tests/
├── appliance-common.bats
├── appliance-engine.bats
├── appliance-doctor.bats
├── appliance-member.bats
├── appliance-sshconfigs.bats
└── appliance-mcp.bats       # protocol tests for both MCP servers

.github/workflows/appliance-tests.yml
```

## Cross-phase conventions

- **Idempotency**: every provisioning entry point can be re-run; existing
  state is detected and skipped, never clobbered. Config files the user may
  have edited are only written if absent (or with `--force`).
- **`--dry-run` everywhere**: all mutating commands route through
  `run_cmd()` in `lib/common.sh`, which echoes instead of executing under
  `--dry-run`. This is also the primary BATS seam.
- **Root model**: `setup.sh` and `member.sh` require root (they install
  packages and create accounts) and refuse to run as a plain user with a
  clear message. Per-user state is written via `runuser -u` so ownership is
  correct without a fakeroot dance — the repo already learned what `0700`
  build-uid artifacts do to Cowork ([cowork-vm-daemon.md](learnings/cowork-vm-daemon.md)).
- **No secrets in the repo or in argv**: tunnel tokens and IdP settings are
  read from files or env, never flags (flags leak via `ps`).

---

## Phase 1 — single-user headless appliance

**Goal**: one command takes a fresh Debian 12/Ubuntu 24.04 box (x86_64 or
arm64) to a working single-user appliance: engine installed, desktop
session serving over kasmVNC, cloudflared tunnel configured, doctor green.

### Interface

```bash
sudo appliance/setup.sh \
	[--engine auto|official|repo]   # default auto
	[--profile kasmvnc|xrdp|overlay] # default kasmvnc
	[--user NAME]                    # default: invoking sudo user
	[--hostname claude.example.com]  # tunnel public hostname (kasmvnc profile)
	[--dry-run] [--force]

appliance/setup.sh doctor        # alias for the doctor entry point
```

### Behavior

1. **Preflight**: root check, distro/arch check, network reachability.
2. **Engine selection** (`lib/engine.sh`): rule order —
   official apt build if Debian-family and `/dev/kvm` exists and arch is
   amd64/arm64; else repo build (deb via this repo's apt repo) with
   `COWORK_VM_BACKEND=bwrap` exported in the session environment.
   `--engine` overrides. The chosen rule and reason are logged and stored
   in `/etc/claude-appliance/engine.conf` for doctor to report.
3. **Session stack**: XFCE (`xfce4 xfce4-goodies` minimal set), per the
   selected profile:
   - **kasmvnc**: install kasmvncserver deb, configure
     `~/.vnc/kasmvnc.yaml` (localhost bind, TLS off — TLS terminates at the
     tunnel), systemd user service, `cloudflared` install + config skeleton
     at `/etc/cloudflared/config.yml` mapping `--hostname` to the local
     kasmVNC port. Tunnel *authentication* (`cloudflared tunnel login`) is
     interactive and left to the operator; setup prints the exact next
     commands.
   - **xrdp**: install xrdp + xorgxrdp, apply the repo's session-type
     fixes, enable service bound to localhost (tunnel or overlay carries
     it).
   - **overlay**: install tailscale, print `tailscale up` next-steps.
4. **Autostart**: XDG autostart entry launching `claude-desktop` in the
   session, close-to-tray relied on for persistence.
5. **Doctor** (`lib/doctor.sh`): checks per the design doc, mirroring the
   output style of `scripts/doctor.sh` (PASS/WARN/FAIL, distro hints, no
   false-green on unreadable probes).

### Acceptance criteria

- `setup.sh --dry-run` on a clean container prints the full plan and
  touches nothing (asserted by BATS).
- Re-running a completed setup makes zero changes (idempotency asserted
  via `run_cmd` call log in dry-run over a simulated done-state).
- `appliance-doctor` exits non-zero when any FAIL is present; publicly
  bound VNC/RDP ports are a FAIL, not a WARN.
- shellcheck-clean; all functions covered by BATS with stubbed commands.

### Hardware-verify checklist (not CI-testable)

- [ ] Real kasmVNC session reachable through a real cloudflared tunnel
- [ ] Claude Desktop signs in and Cowork starts under the chosen engine
- [ ] xrdp profile renders (GPU-compositing fix path)

---

## Phase 2 — multi-user member management

**Goal**: add/remove team members with real isolation and quotas.

### Interface

```bash
sudo appliance/member.sh add NAME [--quota-mem 6G] [--quota-cpu 200%] \
	[--port auto] [--dry-run]
sudo appliance/member.sh remove NAME [--keep-home] [--dry-run]
appliance/member.sh list
```

### Behavior

- `add`: create Unix account (no sudo), install systemd user-slice
  override (`/etc/systemd/system/user-<uid>.slice.d/50-appliance.conf`
  with `MemoryMax`, `CPUQuota`, `TasksMax`), allocate next free kasmVNC
  port from a registry file (`/etc/claude-appliance/members.tsv`), write
  per-user kasmVNC service + XDG autostart, append a hostname→port entry
  to the cloudflared config ingress (one hostname per member,
  `NAME.claude.example.com`), print the Access-policy reminder (policy
  creation lives in Cloudflare's dashboard/API, out of scope here).
- `remove`: stop services, drop ingress entry, delete slice override,
  optionally archive home.
- `list`: render the registry with port, quota, and doctor state per
  member.
- PAM keyring: ensure `pam_gnome_keyring.so` lines exist for the login
  stack used by the session layer, so `safeStorage` works headlessly.

### Acceptance criteria

- Port allocation is collision-free and stable across add/remove cycles
  (BATS over the registry file).
- `remove` never `rm -rf`s outside the member's home; `--keep-home` is
  honored (BATS with a fake root tree).
- Ingress edits are surgical and idempotent (BATS golden-file diff).

### Hardware-verify checklist

- [ ] Two concurrent members in real kasmVNC sessions, each signed into
      their own Claude account, quotas visible in `systemd-cgtop`
- [ ] Keyring unlock at session start (no safeStorage degradation)

---

## Phase 3 — test bench (computer-use substitutes)

**Goal**: the MCP toolset from the design doc's
[test bench section](cowork-appliance-design.md#computer-use-substitutes--the-multi-os-test-bench),
installable per member, usable from Cowork/Code sessions.

### Deliverables

1. **`testbench/setup.sh`**: installs Xvfb, xdotool, imagemagick,
   at-spi2-core, Playwright MCP config snippet; registers both MCP
   servers into the member's `claude_desktop_config.json` (merge, not
   overwrite — jq).
2. **`desktop-control-mcp.js`** (no npm dependencies, CommonJS, stdio
   newline-delimited JSON-RPC per MCP spec):
   - `display_start {width,height}` → boots a dedicated Xvfb display,
     returns `{display}`; refuses to target a display it did not create
     (the member's real `:0`/`:10` session is never controllable)
   - `display_stop`, `screenshot {}` → PNG (base64 image content),
   - `click {x,y,button}`, `type {text}`, `key {keys}` (xdotool),
   - `launch {command,args}` → app on the nested display,
   - `ax_tree {}` → AT-SPI dump when available (graceful degrade).
3. **`vm-bench-mcp.js`** (skeleton, same protocol): `vm_start
   {image,snapshot}`, `vm_screenshot`, `vm_input {events}`, `vm_revert`,
   `vm_stop` over QMP. Ships with an explicit `status: experimental`
   banner in `tools/list` descriptions; QMP wire code unit-tested against
   a mock QMP socket, not a real guest.

### Acceptance criteria

- Both servers complete the MCP handshake (`initialize` →
  `tools/list` → `tools/call`) driven by a scripted stdio client under
  BATS + node.
- `desktop-control` end-to-end **in this repo's CI container**: start
  Xvfb display, launch `xterm` (or `xlogo`), screenshot returns a
  non-empty PNG, click/type produce no protocol errors, stop cleans up
  (no orphan Xvfb — asserted via pgrep).
- Safety: tools refuse to act when the target display is not one the
  server created; `launch` rejects shell metacharacters (argv array
  spawn only, no shell).

### Hardware-verify checklist

- [ ] Playwright MCP + `_electron` against a real member-built app
- [ ] vm-bench against a licensed Windows guest with snapshots
- [ ] AT-SPI tree over a real GTK app

---

## Phase 4 — team distribution

**Goal**: make the appliance appear in every member's own desktop app.

### Deliverables

- **`gen-sshconfigs.sh`**: reads `members.tsv` + appliance hostname,
  emits the managed-settings `sshConfigs` JSON block (and optional
  `sshHostAllowlist`) to stdout; `--merge FILE` merges into an existing
  managed settings file via jq without disturbing other keys.
- **`docs/cowork-appliance-runbook.md`**: admin runbook — initial
  provision, member add/remove, tunnel/Access setup walkthrough,
  Guacamole gateway option, break-glass overlay procedure, backup
  (what to back up: `/etc/claude-appliance`, member homes, NOT vm
  bundles), restore drill.

### Acceptance criteria

- Generator output is `jq`-valid, matches the upstream `sshConfigs`
  schema (id/name/sshHost required), and is stable/deterministic (BATS
  golden files); `--merge` preserves unrelated keys byte-for-byte.

---

## Phase 5 — images + CI

**Goal**: flash-and-go paths and CI protection for everything above.

### Deliverables

- **`images/cloud-init.yaml`**: user-data that clones the repo at a tag,
  runs `setup.sh --engine auto --profile kasmvnc` non-interactively, and
  drops a first-boot README on the console with the next-step commands
  (tunnel login, sign-in).
- **`images/README.md`**: pi-gen stage recipe for a Pi 5 image (arm64
  deb engine, notes on 16 GB RAM guidance and no-HW-encoder caveat).
- **`.github/workflows/appliance-tests.yml`**: on PR/push touching
  `appliance/**` or `tests/appliance-*`: shellcheck on `appliance/**/
  *.sh`, `node --check` on the MCP servers, full appliance BATS suite,
  plus the Xvfb end-to-end MCP test (ubuntu-latest has xvfb).
- CHANGELOG `[Unreleased]` entries per Keep a Changelog.

### Acceptance criteria

- Workflow is actionlint-clean and passes on this PR.
- cloud-init YAML validates (`cloud-init schema` if available, else
  yamllint-level check in CI).

---

## Phase 6 — deferred R&D (tracking only)

Native Linux computer use in the app; Sunshine profile tuning; Android
AVF on-device experiments; Mac-node automation for the macOS/iOS test
leg. Each gets an issue when the phase above it ships; none block 1–5.
