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

1. **No aarch64 package mirror wired in.** `configs/pacman-online-*.conf` point at
   `omarchy.org` (x86_64 only). Use `configs/pacman-online-aarch64.example.conf`
   (Arch Linux ARM mirror) and wire it into the `pacman --config …` lines in
   `builder/build-iso.sh`. ALARM has no `multilib` and different repo names.
2. **Omarchy custom packages aren't on ALARM.** `walker`, `omarchy-*`,
   `omarchy-keyring`, `yay`, `displaylink`/`evdi`, and a Snapdragon kernel must be
   rebuilt for aarch64 and hosted in a custom repo (or installed from AUR on first
   boot). See the `AARCH64 / SNAPDRAGON-X TODO` block in the installer repo's
   `install/omarchy-other.packages`.
3. **archiso `releng` is x86_64-only.** There is no upstream aarch64 releng
   profile. The bootloader path (`uefi.grub`) and the live kernel need an aarch64
   profile. Consider `archboot` (which does build aarch64 ISOs) as an alternative
   assembler if mkarchiso/releng proves too x86-bound.
4. **Snapdragon X kernel + firmware.** The generic `linux-aarch64` won't fully
   drive the X1E78100 (GPU/Wi-Fi/audio). Track the `linux-x1e` / aarch64-laptops
   work and bake the right kernel + Qualcomm firmware.

## How to exercise the pipeline now

`workflow_dispatch` the `Build ISO (aarch64)` action (or run
`OMARCHY_MIRROR=stable ARCH=aarch64 ./bin/omarchy-iso-make --no-boot-offer`).
Expect it to fail at the `pacman -Syw` offline-mirror step until blockers #1–#2
are resolved — that failure is the current, known frontier, not a regression.
