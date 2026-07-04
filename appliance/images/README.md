# Appliance images

Flash-and-go bootstrap paths for the Cowork appliance.

## cloud-init (VPS, mini-PC with Ubuntu autoinstall)

[`cloud-init.yaml`](cloud-init.yaml) is standard user-data: replace
`__HOSTNAME__` and `__ADMIN_KEY__`, feed it to your provider
(DigitalOcean/Hetzner user-data field, Ubuntu autoinstall, Proxmox
cloud-init drive). It creates the first member (`cowork`), clones
this repo to `/opt/claude-appliance`, and runs `setup.sh`. The
interactive credential steps (tunnel login, Access policy, Claude
sign-in) are listed in the box's `/etc/motd` and stay manual on
purpose — no secrets in user-data.

Engine note: most VPSes have no nested virtualization, so engine
auto-selection lands on this repo's build with the bwrap Cowork
backend. That is the expected configuration, not a degraded one.

## Raspberry Pi 5 (pi-gen)

A dedicated image is Phase 5 follow-up work; until then, on stock
Raspberry Pi OS (Bookworm, arm64):

```bash
sudo apt install git && git clone \
  https://github.com/aaddrick/claude-desktop-debian
sudo claude-desktop-debian/appliance/setup.sh \
  --user pi --hostname claude.example.com
```

For a pi-gen stage, the recipe is: base `stage2`, a stage that
installs `git` + clones the repo + runs
`appliance/setup.sh --engine auto --profile kasmvnc` with
`APPLIANCE_KASMVNC_VERSION` pinned, and a firstboot script that
prints the manual steps. Sizing and encoder caveats:

- 16 GB Pi 5 recommended; bwrap backend is the practical choice for
  multi-member (KVM guests are RAM-hungry).
- The Pi 5 has **no H.264 hardware encoder** — kasmVNC (JPEG/WebP
  regions) performs well; don't plan on Sunshine/Moonlight there.
- Use an NVMe HAT or USB3 SSD; Cowork sessions are I/O-heavy on
  first VM download/extract.
