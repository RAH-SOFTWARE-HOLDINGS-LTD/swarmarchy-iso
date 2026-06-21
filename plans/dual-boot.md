# Dual-Boot Installation Support for Swarmarchy ISO

## Context

Currently, the Swarmarchy installer wipes the entire selected disk (`"wipe": true`) and creates two partitions: a 2GB FAT32 ESP and a LUKS-encrypted Btrfs root. This means users must dedicate an entire disk to Swarmarchy. Adding dual-boot support lets users install alongside an existing OS (typically Windows) while keeping the Swarmarchy partition encrypted.

## Core Approach: `pre_mounted_config`

**Do our own partitioning, then hand off to archinstall for package installation only.**

archinstall's `manual_partitioning` mode has a long history of bugs with existing partitions and LUKS (archinstall issues #998, #2072, #2444). Instead, we:

1. Detect existing partitions and free space ourselves (with `sgdisk`/`parted`)
2. Create the LUKS partition and Btrfs subvolumes ourselves (with `cryptsetup`/`mkfs.btrfs`)
3. Mount everything at `/mnt/archinstall`
4. Tell archinstall to use `"config_type": "pre_mounted_config"` — it installs packages into our pre-mounted tree and does zero disk operations
5. Handle encryption config (crypttab, mkinitcpio hooks, bootloader cmdline) in post-install

The existing full-disk path stays completely unchanged. Dual-boot is a parallel code path.

## Implementation Guardrails

- **Run target changes in chroot** — all target-system commands (`mkinitcpio -P`, `limine-scan`, bootloader config updates) must run via `arch-chroot "$INSTALL_ROOT" ...`
- **Edit target files under `$INSTALL_ROOT` only** — write `mkinitcpio` hook config, `limine.conf`, `crypttab`, and related files in `$INSTALL_ROOT/etc` and `$INSTALL_ROOT/boot` (never in the live environment root)
- **Settle kernel partition state** — after creating the new partition, run `partprobe "$DISK"` and `udevadm settle` before `cryptsetup` to avoid device-node races
- **Deterministic fstab** — always generate `/etc/fstab` for dual-boot with overwrite semantics (e.g., `genfstab -U "$INSTALL_ROOT" > "$INSTALL_ROOT/etc/fstab"`) to avoid duplicate entries on retries
- **Hook compatibility** — when updating mkinitcpio hooks, add `encrypt` for busybox initramfs or `sd-encrypt` for systemd initramfs; never assume one universally
- **Safe rollback on failure** — on any dual-boot setup failure: unmount mounts, close LUKS mapping, and surface recovery guidance; optionally delete the just-created partition only if it was created in this run

## Scope Constraints

- **UEFI/GPT only** — dual-boot on MBR/BIOS is too fragile; those users get full-disk only
- **No auto-shrinking** — users must free up space from their existing OS first (e.g., Windows Disk Management). Too risky to shrink partitions automatically
- **Minimum 20GB free space** required for Swarmarchy

## User Flow

```
Select disk → Detect layout →

  If disk has existing OS + ESP + ≥20GB free space:
    "How would you like to install?"
      → "Install alongside Windows (use 85GB free space)"
      → "Erase entire disk"

  If disk is empty or no free space:
    Existing "Confirm overwriting" flow (unchanged)
```

## File Changes

### 1. `configs/airootfs/root/configurator`

**Add after disk selection (line 233), before config generation:**

- `detect_disk_layout()` — examines selected disk for:
  - GPT partition table (required for dual-boot)
  - Existing ESP partition (via `lsblk` PARTTYPE matching EFI GUID)
  - Free unallocated space (via `sgdisk -F`/`-E` or `parted print free`)
  - OS detection for installer UX warnings/prompts (not boot correctness): mount ESP read-only, check common vendor paths like `EFI/Microsoft`, `EFI/systemd`, `EFI/ubuntu`, `EFI/fedora`, `EFI/GRUB`

- `install_mode_form()` — shows gum choose with dual-boot vs erase options when conditions are met. Sets `DUAL_BOOT=true/false`.

**Generate different JSON when `DUAL_BOOT=true`:**

```json
{
    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": "/mnt/archinstall"
    }
}
```

No `device_modifications`, no `disk_encryption`, no `btrfs_options` — we handle all of that ourselves. Everything else (hostname, kernels, packages, etc.) stays the same.

**Write `install_mode.sh`** alongside the other config files:

```bash
DUAL_BOOT=true
DISK=/dev/nvme0n1
ESP_PARTITION=/dev/nvme0n1p1
```

### 2. `configs/airootfs/root/.automated_script.sh`

**Source `install_mode.sh`** in `run_configurator()` if it exists.

**Add `setup_dual_boot_partitions()`** — runs before archinstall when `DUAL_BOOT=true`:

1. Select the largest contiguous free region and run `sgdisk` to create new partition there (type 8309 = Linux LUKS)
2. `partprobe "$DISK"` + `udevadm settle` so new partition node is present
3. `cryptsetup luksFormat` + `luksOpen` with user's password
4. `mkfs.btrfs` on `/dev/mapper/swarmarchy_root`
5. Create Btrfs subvolumes: `@`, `@home`, `@log`, `@pkg`
6. Mount subvolumes at `/mnt/archinstall` with `compress=zstd`
7. Mount existing ESP (untouched) at `/mnt/archinstall/boot`
8. Generate target `/etc/fstab` from mounted filesystems before post-install steps

**Add `configure_dual_boot_post_install()`** — runs after archinstall:

1. Write `/etc/crypttab` entry using LUKS UUID/PARTUUID (stable identifier), e.g. `swarmarchy_root UUID=<luks-uuid> none luks,discard`
2. Update mkinitcpio hooks before `filesystems`: `encrypt` (busybox) or `sd-encrypt` (systemd)
3. Regenerate initramfs with `arch-chroot "$INSTALL_ROOT" mkinitcpio -P`
4. Configure Limine kernel cmdline to match initramfs mode:
   - busybox `encrypt`: `cryptdevice=UUID=<uuid>:swarmarchy_root root=/dev/mapper/swarmarchy_root`
   - systemd `sd-encrypt`: `rd.luks.name=<uuid>=swarmarchy_root root=/dev/mapper/swarmarchy_root` (or equivalent `rd.luks.uuid=` form)
5. Run `arch-chroot "$INSTALL_ROOT" limine-scan` to detect other OS boot entries (Windows, etc.)
6. Preserve current firmware default boot order unless user explicitly chooses to make Limine first (capture and restore `BootOrder` if `efibootmgr` side effects reorder entries)

**Use `$INSTALL_ROOT` variable** — defaults to `/mnt` for full-disk, `/mnt/archinstall` for dual-boot. Post-install steps (offline mirror bind-mount, sudoers, swarmarchy copy) reference this instead of hardcoded `/mnt`.

### 3. `builder/build-iso.sh` + `builder/archinstall.packages`

Add `parted` to packages available in the live ISO (needed for free space detection).

## Bootloader Coexistence

Limine installs to `ESP/EFI/arch-limine/` and registers via `efibootmgr`. This sits alongside:
- Windows Boot Manager at `ESP/EFI/Microsoft/Boot/bootmgfw.efi`
- Any other bootloader in its own ESP subdirectory

`limine-scan` auto-detects other UEFI boot entries and adds them to `limine.conf`. Users can choose OS at boot.

**Boot order policy**: creating a new EFI entry must not silently change the current default boot target. Keep existing firmware boot order by default and only promote Limine when user opts in.

Implementation note: when registering Limine with `efibootmgr`, do not pass reorder flags by default; if firmware still changes order, explicitly restore prior `BootOrder` unless the user opted to promote Limine.

**ESP size note**: Windows typically creates a 100-260MB ESP. This is enough for Limine + kernel + initramfs, but Snapper boot snapshots (which copy kernels to ESP) will be limited or disabled.

**ESP free-space threshold**:
- If ESP has `<100MB` free at install time: show a strong warning (do not block install)
- If ESP has `<64MB` free: hide dual-boot option and require full-disk install (or user frees space first)

**BitLocker warning**: If Windows is detected, show a warning about having the BitLocker recovery key ready, since modifying ESP/UEFI entries can trigger recovery.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Disk is empty | Full-disk install only (current behavior) |
| Existing OS but no free space | Full-disk install only, with note to free space first |
| Free space < 20GB | Dual-boot option not shown |
| MBR/BIOS disk | Dual-boot option not shown |
| ESP < 100MB free after mount | Warn user; continue allowed |
| ESP < 64MB free after mount | Dual-boot option not shown |
| Multiple free regions | Use largest contiguous region |
| Partitioning/setup failure mid-run | Cleanup mounts/LUKS and abort safely |

## Verification

1. **Regression**: Full-disk install in VM with empty disk — must work identically to today
2. **Dual-boot with Windows**: VM with Windows installed + 40GB free space — detect Windows, install alongside, both OSes boot
3. **Dual-boot with Linux**: VM with another Linux + free space — similar test
4. **No free space**: VM with fully partitioned disk — dual-boot option should not appear
5. **Encryption**: After dual-boot install, verify LUKS unlock prompt at boot and encrypted root
6. **Initramfs mode**: Validate both busybox and systemd hook paths boot correctly (`encrypt` vs `sd-encrypt`)
7. **Boot order**: Verify existing default UEFI entry remains unchanged unless user opted to promote Limine
