# Building the Swarmarchy ISO for aarch64 (Snapdragon X Elite)

This repo was forked from `omarchy-iso` (x86_64) and is being retargeted to
**aarch64** for the Lenovo Yoga Slim 7x (Snapdragon X Elite X1E78100).

## What the aarch64 surgery already changed

- **`configs/profiledef.sh`** — `arch=aarch64`; `bootmodes=('uefi.grub')` (dropped
  BIOS/syslinux, which is x86-only); removed the `-Xbcj x86` squashfs filter.
- **`builder/build-iso.sh`** —
  - Added `ARCH` (default `aarch64`).
  - Renames the releng `packages.x86_64` → `packages.$ARCH` and strips x86-only
    entries (`intel-ucode`, `amd-ucode`, `memtest86+`, `syslinux`, …); maps
    `linux`/`linux-headers` → `linux-aarch64`/`linux-aarch64-headers`.
  - Node.js download switched `linux-x64` → `linux-arm64`.
  - Live-ISO extras: dropped `linux-t2`, `plymouth`, `omarchy-keyring`.
- **`builder/archinstall.packages`** — dropped x86 microcode + `sof-firmware`;
  `linux` → `linux-aarch64`.
- **`.github/workflows/build-iso.yml`** — runs on a native `ubuntu-24.04-arm`
  runner in an ARM Arch container.

## What still blocks a *bootable* image (ordered by severity)

1. ~~No aarch64 mirror wired in.~~ **DONE** — `configs/pacman-online-*.conf` now point at
   the **Arch Linux ARM** mirror (no `omarchy.org`, no `[omarchy]` repo, no `multilib`),
   and `build-iso.sh` verifies packages with `archlinuxarm-keyring`.
2. **AUR-only packages.** `walker`, `yay`, `displaylink`/`evdi`, and a Snapdragon kernel
   aren't in ALARM — build them from the AUR on first boot (or host your own repo). See
   the `AARCH64 / SNAPDRAGON-X TODO` block in the installer repo's
   `install/swarmarchy-other.packages`.
3. **archiso `releng` is x86_64-only.** There is no upstream aarch64 releng
   profile. The bootloader path (`uefi.grub`) and the live kernel need an aarch64
   profile. Consider `archboot` (which does build aarch64 ISOs) as an alternative
   assembler if mkarchiso/releng proves too x86-bound.
4. **Snapdragon X kernel + firmware** — *smaller than originally feared.*
   - **Kernel: use mainline.** Yoga Slim 7x (X1E80100) support landed in **Linux
     6.11** and has improved since; the device tree `qcom/x1e80100-lenovo-yoga-
     slim7x.dtb` is **upstreamed**. So a recent mainline/ALARM **`linux-aarch64`
     (6.14+) plus the upstream DTB** should boot the laptop — no from-scratch
     `linux-x1e` build required. Verify which version covers your hardware.
   - **GPU works:** Adreno **X1-85** uses Mesa **turnip** (Vulkan) + **freedreno**
     (GL) — already in tree (`mesa` + `vulkan-freedreno`). (The bleeding-edge work
     in the news is the newer **X2** Elite, not this machine.)
   - **Firmware = extract from Windows.** Licensing blocks redistribution, so pull
     the Qualcomm blobs from the Windows partition:
     `\Windows\System32\DriverStore\FileRepository\*\*.mbn`/`.jsn`/`dtbs.elf`.
     Convenient here since the machine dual-boots Windows.
   - **Known rough edges (verify current):** early support lacked working
     touchpad, internal mics (DMICs), and battery monitoring.

## Reference implementations — don't reinvent
The X1E Yoga has already been brought up by the community; follow these:
- **Arch Linux ARM on this exact laptop:** joske's gist —
  `https://gist.github.com/joske/52be3f1e5d0239706cd5a4252606644b` (primary guide).
- **Full NixOS config for the X1E Yoga:** `https://github.com/kuruczgy/x1e-nixos-config`
  (authoritative list of kernel/firmware/quirks).
- **Easiest known-good baseline:** Ubuntu "Concept" ISO (24.10).
- **Daily-driver writeup:** `https://varunpriolkar.com/2025/07/daily-driving-an-arm-linux-laptop/`

> Strategy note: `swarmarchy` is a post-install layer, so the lowest-risk path is to
> get a working Arch aarch64 base on the laptop (per joske's guide), then run the
> installer over it — the custom ISO is polish, not a prerequisite.

## How to exercise the pipeline now

`workflow_dispatch` the `Build ISO (aarch64)` action (or run
`SWARMARCHY_MIRROR=stable ARCH=aarch64 ./bin/swarmarchy-iso-make --no-boot-offer`).
Expect it to fail at the `pacman -Syw` offline-mirror step until blockers #1–#2
are resolved — that failure is the current, known frontier, not a regression.
