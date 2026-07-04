[< Back to index](index.md)

# Cowork appliance — design

A headless, internet-connected, team-accessible Claude Desktop server ("the appliance") built by composing upstream-maintained parts, so it inherits every Claude Desktop feature and fix without forking functionality.

- **Base**: one always-on Linux box (x86_64 mini PC or arm64 SBC) running Claude Desktop
- **Engine**: official Anthropic apt build by default; this repo's build where the official one can't run (no KVM, non-Debian, bwrap portability)
- **Access**: per-user remote desktop for the full app; SSH-target mode for Code-tab sessions from members' own desktop apps; Dispatch from phones
- **Trust boundary**: Tailscale network + per-member Linux accounts + bwrap/KVM Cowork isolation + AppArmor

## Goals and non-goals

**Goals**

1. Deliver the full Claude Desktop feature surface (Chat, Cowork, Code, connectors, MCP, skills, plugins, Dispatch) to devices that cannot run it natively — iPad, Android tablets, any browser.
2. Track upstream automatically. Every layer updates through its own upstream channel (Anthropic apt repo, distro packages, Tailscale). The appliance layer itself is composition + configuration, not a fork.
3. Support multiple team members with real isolation between them.
4. Borrow this repo's hardening: `--doctor`-style readiness checks, bwrap sandbox configuration, AppArmor userns profiles, keyring detection, XRDP fixes.

**Non-goals**

- Reimplementing any part of the Claude Desktop app. Features gated off by Anthropic (computer use on Linux, dictation) stay gated until upstream ships them; the appliance documents the gap and the closest workaround instead of patching one in.
- iPadOS/Android *native* execution. Apple and Google platform rules make that permanently impossible for an Electron + VM stack; the appliance treats tablets as clients.

## Feature parity matrix

What each feature needs from the appliance, and its status. "Official Linux" is Anthropic's [Linux beta](https://code.claude.com/docs/en/desktop-linux); "repo build" is this project's repackaged Windows app.

| Feature | Official Linux | Repo build | Via appliance remote session | Notes |
|---|---|---|---|---|
| Chat tab | yes | yes | yes | |
| Cowork tab | yes (beta) | yes (KVM/bwrap/host) | yes | Isolation backend choice below |
| Code tab | yes (beta) | yes (patched) | yes | Also reachable via SSH-target mode |
| Parallel sessions, diff review, terminal, editor, app preview | yes | yes | yes | Preview ports are local to the appliance; reachable over Tailscale |
| Remote connectors (Drive, Slack, …) | yes | yes | yes | Account-level; OAuth flows complete in the remote session's browser |
| Local MCP servers | yes | yes | yes | Run on the appliance; per-user `~/.config/Claude/claude_desktop_config.json` |
| Desktop extensions (`.mcpb`) | yes | yes | yes | |
| Skills and plugins | yes | yes | yes | |
| Cloud sessions | yes | yes | yes | Continue even when the appliance session closes |
| SSH sessions (Desktop as client) | yes | yes | yes | The appliance is more useful as the *target*; see below |
| Dispatch (phone → desktop handoff) | yes | yes | yes | Requires the desktop app running and signed in — exactly what the appliance guarantees, per member |
| Quick Entry global hotkey | X11 yes; native Wayland needs GlobalShortcuts portal | same | yes | xrdp sessions are Xorg, so the X11 path applies |
| System tray | yes | yes (repo has extra fixes) | yes | Needs a tray-capable DE/panel in the remote session |
| Computer use (app/screen control) | **no — macOS/Windows research preview only** | no | no | Also Pro/Max-only; **not available on Team/Enterprise plans at all**. See gap tracking below |
| Dictation | **no on Linux desktop** | no | practical workaround | Client-side OS dictation (iPad/Android keyboard mic) types into the remote session; CLI voice dictation exists separately |
| Fedora/RHEL packages | no | yes (rpm) | n/a | Repo build is the only option there today |

Two upstream gates worth internalizing before promising "ALL features" to a team:

1. **Computer use cannot be delivered by any Linux appliance today.** It is a research preview on macOS and Windows, requires Pro or Max, and is explicitly excluded from Team and Enterprise plans. A team-accessible server and computer use are currently mutually exclusive at the *plan* level, not just the OS level. The honest design is: track upstream, and meanwhile note that Cowork's priority order (connectors → Bash → browser → screen control) means most computer-use tasks on a server reduce to Bash and connectors anyway.
2. **Dictation** is absent from the Linux app, but the tablet-as-client architecture mostly dissolves this: iPadOS and Android system dictation input works in any remote-desktop client's keyboard path.

## Engine selection

The appliance supports two interchangeable engines behind one provisioning interface:

| | Official apt build | This repo's build |
|---|---|---|
| Update channel | Anthropic's apt repo (`downloads.claude.ai/claude-desktop/apt`) | This repo's apt/dnf repo, AUR, Nix |
| Cowork isolation | Anthropic's VM stack (KVM/QEMU; needs `/dev/kvm`) | `kvm`, `bwrap`, or `host` via `COWORK_VM_BACKEND` |
| Distros | Ubuntu 22.04+/Debian 12+ | deb, rpm, AppImage, Nix, AUR |
| Arch | x86_64, arm64 | x86_64, arm64 |
| Breakage risk | lowest (first-party) | patch suite chases upstream minification |

Selection rule, encoded in the provisioning script:

1. Debian-family + `/dev/kvm` available → **official build**. First-party updates, first-party Cowork VM.
2. No KVM (cloud VPS without nested virt, LXC/containers, Android AVF experiments) → **repo build with `COWORK_VM_BACKEND=bwrap`**. Bubblewrap is the portability play: namespace isolation with zero virtualization requirements, plus the `coworkBwrapMounts` config surface (`additionalROBinds`, `additionalBinds`, `disabledDefaultBinds`, `{src, dst}` mapping) documented in [configuration.md](configuration.md#cowork-sandbox-mounts).
3. Fedora/RHEL/Nix host → **repo build** (official is Debian-only today).

The doctor check (below) reports which rule fired and why, mirroring `claude-desktop --doctor`'s backend summary.

## Access layer

Three complementary paths, not one:

### 1. Remote desktop (full app: Chat + Cowork + Code)

**xrdp is the default.** It is the only mainstream option with true multi-user semantics — each member RDPs into *their own* Xorg session under their own Linux account. Clients are first-class on iPad (Windows App, Jump Desktop), Android, and every OS. This repo already carries the two fixes that make it work:

- the XRDP GPU-compositing blank-window fix (launcher detects the session type and adjusts GPU flags; #davidamacey),
- GPU-crash auto-recovery relaunch with safe flags.

**kasmVNC as the zero-install alternative**: browser-only access (iPad Safari, Chromebooks, locked-down machines), per-user instances on distinct ports behind Tailscale.

**Sunshine/Moonlight for the latency-sensitive single seat**: best-in-class feel on iPad, but single-session and needs a hardware encoder (Intel iGPU/QuickSync; note the Pi 5 has no H.264 encoder, so software encoding costs CPU there). Offered as an opt-in profile, not the team default.

Session shell: a lightweight tray-capable DE (XFCE or LXQt) so the tray, Quick Entry (X11 path), and window management all behave. Claude Desktop autostarts per user via XDG Autostart — the same mechanism the repo already uses for "Run on startup" persistence.

### 2. SSH-target mode (Code tab from members' own devices)

Members who have Claude Desktop on their own Mac/Windows machine don't need remote desktop for coding work: the desktop app's **SSH sessions** run Claude Code on a remote machine over SSH, with connectors, plugins, MCP, and permission modes supported. The appliance provisions itself as that target:

- per-member Unix accounts with SSH keys (Tailscale SSH is the low-friction option),
- an admin-distributable managed-settings snippet (`sshConfigs`) so the appliance appears automatically in every member's environment dropdown, marked as managed,
- optional `sshHostAllowlist` guidance for orgs that want Desktop's SSH constrained to the appliance.

This path costs no display server, no encoder, and no session state — it's the cheapest team feature the appliance offers, and it's pure upstream functionality.

### 3. Dispatch (phones and quick handoffs)

Each member's appliance session is a signed-in, always-on desktop — which is precisely the prerequisite Dispatch needs. Members message Claude from the mobile app; the work executes in their appliance session with their files and connectors; results come back to the same conversation. No appliance-side code needed beyond "keep the app running," which close-to-tray (already a repo feature) provides.

### Networking

- **Tailscale by default.** No public exposure of xrdp/VNC ever; ACL tags (`tag:cowork-appliance`) scope which members reach which ports. Works from cellular iPads without port forwarding.
- Public HTTPS is out of scope for v1. If a team can't use a tailnet, kasmVNC behind a reverse proxy with SSO is the documented escape hatch, with loud warnings.

## Multi-tenancy and security model

**One Linux account per member. No shared sign-ins.**

- Each member signs into their own Claude account (Team plan) inside their own session. Config, MCP servers, connector OAuth grants, and Cowork state live under their own `~/.config/Claude/`.
- **Keyring**: Electron `safeStorage` needs a functioning secret service or session persistence silently degrades. xrdp's PAM integration unlocks gnome-keyring at login; the launcher's `--password-store` D-Bus probing (#611) papers over the rest. The doctor check verifies a non-empty password store per user — the repo already learned that an *empty* store reads as falsely healthy (#692).
- **Cowork isolation is per user**: the daemon socket lives in each user's `$XDG_RUNTIME_DIR`, sandboxes/VMs are per-session. bwrap's read-write binds are constrained to the owning user's `$HOME` by the existing mount-config validation, which composes correctly with the one-account-per-member model.
- **AppArmor**: reuse the repo's scoped userns profiles (Electron binary + `/usr/bin/bwrap`) on Ubuntu 24.04+, so `apparmor_restrict_unprivileged_userns=1` neither breaks launch nor silently downgrades Cowork to host-direct (#687, #694).
- **Backend vs tenancy trade-off**: KVM gives the strongest inter-tenant isolation but costs VM-sized RAM per concurrent user; bwrap is namespace-level but light enough for several concurrent members on modest hardware. Sizing guidance: ~4 GB per active Cowork user on KVM, ~1–2 GB on bwrap, plus the Electron sessions themselves. A 32 GB N100/N305 box comfortably serves a small team; a 16 GB Pi 5 serves one or two.

## Update strategy

| Layer | Channel | Mechanism |
|---|---|---|
| Claude Desktop (official) | Anthropic apt repo | `unattended-upgrades` |
| Claude Desktop (repo build) | this repo's apt/dnf repo | `unattended-upgrades` |
| OS, xrdp, DE, bwrap, qemu | distro | `unattended-upgrades` |
| Tailscale | tailscale apt repo | `unattended-upgrades` |
| Appliance layer | this repo | it's config + scripts; updated like any package |

The repo's in-place upgrade detection (watching `app.asar` replacement and offering click-to-restart, #564) matters more on an appliance than anywhere else — sessions are long-lived by design, so a v(N) main process serving v(N+1) renderer assets is the steady state without it.

## Readiness check

`appliance-doctor` extends the `claude-desktop --doctor` philosophy to the appliance surface. Checks, grouped:

- **Engine**: which engine/backend rule fired; `/dev/kvm` + vsock + qemu + virtiofsd, or bwrap functional test; AppArmor userns status
- **Display**: xrdp service health, per-user session capability, GPU/encoder availability, session DE tray support
- **Identity**: per-user keyring/password-store non-empty check, signed-in state
- **Network**: tailnet reachability, ACL tag presence, no publicly bound xrdp/VNC ports (fail loudly if found)
- **Update**: unattended-upgrades enabled for every channel in the table above

Same conventions as the existing doctor: symptom-keyed output, distro-specific install hints, and no false-green PASSes on empty/unreadable probes (#692).

## Known upstream gaps to track

| Gap | Upstream state | Appliance stance |
|---|---|---|
| Computer use on Linux | macOS/Windows research preview; Pro/Max only, excluded from Team/Enterprise | Document; do not patch. Revisit when Linux ships and/or Team plans gain access. A Linux implementation would need AT-SPI2/`ydotool`-class work — greenfield, out of scope |
| Dictation on Linux | absent | Client-side OS dictation via remote session; CLI voice dictation |
| Quick Entry on native Wayland | blocked on Electron app-id handshake ([electron#51875](https://github.com/electron/electron/issues/51875)) | Appliance sessions are Xorg (xrdp), so unaffected in practice |
| Fedora/RHEL official packages | "coming in the future" | Repo build covers it |
| Official build isolation fallback | KVM-only (no bwrap equivalent) | Repo build with `COWORK_VM_BACKEND=bwrap` where KVM is unavailable |

## Implementation phases

1. **Single-user headless appliance** — `appliance/setup.sh` (bash-styleguide-conformant): engine selection + install, XFCE + xrdp with the GPU fixes, Tailscale, XDG autostart, `appliance-doctor`. Target: Debian 12/Ubuntu 24.04, x86_64 + arm64.
2. **Multi-user** — member add/remove flow (account, keyring PAM, autostart, ACL tag), per-user kasmVNC option, sizing docs.
3. **Team distribution** — managed-settings `sshConfigs` generator for SSH-target mode; admin runbook.
4. **Images** — pi-gen image for Pi 5, cloud-init for VPS/mini-PC, CI smoke tests reusing the repo's BATS + headless-launch harness patterns.
5. **R&D (explicitly deferred)** — Linux computer use, Sunshine profile tuning, Android AVF on-device experiments (repo build + bwrap; no nested KVM inside AVF).
