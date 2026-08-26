#!/usr/bin/env bash
set -euo pipefail

use_swarmarchy_helpers() {
  export SWARMARCHY_PATH="/root/swarmarchy"
  export SWARMARCHY_INSTALL="/root/swarmarchy/install"
  export SWARMARCHY_INSTALL_LOG_FILE="/var/log/swarmarchy-install.log"
  export SWARMARCHY_MIRROR="$(cat /root/swarmarchy_mirror)"
  source /root/swarmarchy/install/helpers/all.sh
}

run_configurator() {
  set_tokyo_night_colors
  ./configurator
  export SWARMARCHY_USER="$(jq -r '.users[0].username' user_credentials.json)"
}

install_arch() {
  clear_logo
  gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Installing..."
  echo

  touch /var/log/swarmarchy-install.log

  start_log_output

  # Set CURRENT_SCRIPT for the trap to display better when nothing is returned for some reason
  CURRENT_SCRIPT="install_base_system"
  install_base_system > >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>/var/log/swarmarchy-install.log) 2>&1
  unset CURRENT_SCRIPT
  stop_log_output
}

install_swarmarchy() {
  chroot_bash -lc "sudo pacman -S --noconfirm --needed gum" >/dev/null
  chroot_bash -lc "source /home/$SWARMARCHY_USER/.local/share/swarmarchy/install.sh || bash"

  configure_login_for_unencrypted_install

  # Reboot if requested by installer
  if [[ -f /mnt/var/tmp/swarmarchy-install-completed ]]; then
    reboot
  fi
}

# Set Tokyo Night color scheme for the terminal
set_tokyo_night_colors() {
  if [[ $(tty) == "/dev/tty"* ]]; then
    # Tokyo Night color palette
    echo -en "\e]P01a1b26" # black (background)
    echo -en "\e]P1f7768e" # red
    echo -en "\e]P29ece6a" # green
    echo -en "\e]P3e0af68" # yellow
    echo -en "\e]P47aa2f7" # blue
    echo -en "\e]P5bb9af7" # magenta
    echo -en "\e]P67dcfff" # cyan
    echo -en "\e]P7a9b1d6" # white
    echo -en "\e]P8414868" # bright black
    echo -en "\e]P9f7768e" # bright red
    echo -en "\e]PA9ece6a" # bright green
    echo -en "\e]PBe0af68" # bright yellow
    echo -en "\e]PC7aa2f7" # bright blue
    echo -en "\e]PDbb9af7" # bright magenta
    echo -en "\e]PE7dcfff" # bright cyan
    echo -en "\e]PFc0caf5" # bright white (foreground)

    # Set default foreground and background
    echo -en "\033[0m"
    clear
  fi
}

install_disk() {
  jq -er 'first(.disk_config.device_modifications[]? | select(.wipe == true) | .device)' user_configuration.json
}

cleanup_install_disk() {
  local disk="$1"

  if [[ -z "$disk" || ! -b "$disk" ]]; then
    echo "Could not determine install disk for cleanup" >&2
    return 1
  fi

  echo "Cleaning up existing holders on install disk: $disk"

  # Ensure that no mounts exist from past install attempts.
  findmnt -R /mnt >/dev/null && umount -R /mnt || true

  # Turn off swap and unmount anything backed by the selected disk, including
  # device-mapper children from a previous install. Active LVM/swap holders can
  # prevent the kernel from re-reading the partition table after archinstall
  # wipes and recreates it.
  while read -r dev; do
    [[ -b "$dev" ]] || continue

    swapoff "$dev" 2>/dev/null || true

    while read -r target; do
      [[ -n "$target" ]] || continue
      umount "$target" 2>/dev/null || true
    done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
  done < <(lsblk -rnpo PATH "$disk")

  # Deactivate any LVM volume groups whose physical volumes live on the selected
  # disk. This is the common case when replacing Fedora/Alma/RHEL installs.
  while read -r dev type; do
    [[ "$type" == "disk" || "$type" == "part" || "$type" == "crypt" ]] || continue

    while read -r vg; do
      [[ -n "$vg" ]] || continue
      vgchange -an "$vg" 2>/dev/null || true
    done < <(pvs --noheadings -o vg_name "$dev" 2>/dev/null | awk '{$1=$1; print}' | sort -u)
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  # Close any LUKS mappings stacked on the selected disk after filesystems and
  # swap have been released.
  while read -r dev type; do
    [[ "$type" == "crypt" ]] || continue
    cryptsetup close "$dev" 2>/dev/null || true
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  blockdev --flushbufs "$disk" 2>/dev/null || true
  partprobe "$disk" 2>/dev/null || true
  udevadm settle || true
}

# ── Dual-boot (Step 5.2) ─────────────────────────────────────────────────
# The configurator writes user_dualboot.env when the user picks an alongside
# install. In that mode archinstall runs with config_type=pre_mounted_config, so
# it does NO partitioning, formatting or mounting -- everything below is ours.

dualboot_enabled() {
  [[ -f user_install_mode.txt && $(<user_install_mode.txt) == "dualboot" ]]
}

# Create the root partition inside the free region the configurator measured,
# format it Btrfs, lay out the subvolumes and mount the whole tree at /mnt.
# The existing ESP is mounted, never formatted -- it is shared with Windows.
prepare_dualboot_target() {
  # shellcheck source=/dev/null
  source user_dualboot.env

  local end_mib=$((DUALBOOT_FREE_START_MIB + DUALBOOT_FREE_SIZE_MIB))

  # parted reports a trailing free region as running to the very end of the
  # device, but the GPT backup header lives there -- asking for that exact end
  # fails with "location N is outside of the device". Keep 1MiB in reserve.
  local disk_mib
  disk_mib=$(parted -ms "$DUALBOOT_DISK" unit MiB print 2>/dev/null |
    awk -F: 'NR==2 { gsub(/MiB/, "", $2); print int($2) }')
  if [[ -n $disk_mib ]] && (( end_mib > disk_mib - 1 )); then
    end_mib=$((disk_mib - 1))
  fi

  # Swarmarchy gets its OWN ESP at the head of the free region. Sharing the
  # Windows ESP means our kernels/UKIs/snapshot entries compete with Windows for
  # space -- and a full ESP breaks Windows' boot writes too. A dedicated one also
  # means the Limine fallback (EFI/BOOT) lands on our partition instead of
  # overwriting whatever bootloader already owns the existing ESP.
  local esp_end_mib=$((DUALBOOT_FREE_START_MIB + DUALBOOT_ESP_MIB))

  echo "Dual-boot: ESP ${DUALBOOT_FREE_START_MIB}MiB-${esp_end_mib}MiB, root ${esp_end_mib}MiB-${end_mib}MiB on $DUALBOOT_DISK"

  # Identify new partitions by difference -- GPT numbering is not predictable
  # (a freed slot renumbers), so we never assume "the next number".
  local before after esp_part root_part
  before=$(lsblk -rnpo PATH "$DUALBOOT_DISK" | sort)

  parted -s --align optimal "$DUALBOOT_DISK" unit MiB \
    mkpart swarmarchy-boot fat32 "$DUALBOOT_FREE_START_MIB" "$esp_end_mib"
  partprobe "$DUALBOOT_DISK" 2>/dev/null || true
  udevadm settle

  after=$(lsblk -rnpo PATH "$DUALBOOT_DISK" | sort)
  esp_part=$(comm -13 <(echo "$before") <(echo "$after") | head -n1)
  if [[ -z $esp_part || ! -b $esp_part ]]; then
    echo "Dual-boot: could not identify the new ESP" >&2
    return 1
  fi

  # Mark it as an EFI System Partition so firmware (and other installers) see it.
  local esp_num
  esp_num=$(cat "/sys/class/block/$(basename "$esp_part")/partition")
  parted -s "$DUALBOOT_DISK" set "$esp_num" esp on
  parted -s "$DUALBOOT_DISK" set "$esp_num" boot on 2>/dev/null || true

  before="$after"
  parted -s --align optimal "$DUALBOOT_DISK" unit MiB \
    mkpart swarmarchy btrfs "$esp_end_mib" "$end_mib"
  partprobe "$DUALBOOT_DISK" 2>/dev/null || true
  udevadm settle

  after=$(lsblk -rnpo PATH "$DUALBOOT_DISK" | sort)
  root_part=$(comm -13 <(echo "$before") <(echo "$after") | head -n1)
  if [[ -z $root_part || ! -b $root_part ]]; then
    echo "Dual-boot: could not identify the new root partition" >&2
    return 1
  fi

  echo "Dual-boot: ESP=$esp_part root=$root_part"

  mkfs.vfat -F32 -n SWARMBOOT "$esp_part"
  mkfs.btrfs -f -L swarmarchy "$root_part"

  # Subvolume layout mirrors the wipe path so snapshots/rollback behave the same.
  mount "$root_part" /mnt
  local sv
  for sv in @ @home @log @pkg @snapshots; do
    btrfs subvolume create "/mnt/$sv"
  done
  umount /mnt

  local opts="compress=zstd,noatime"
  mount -o "$opts,subvol=@" "$root_part" /mnt
  mkdir -p /mnt/home /mnt/var/log /mnt/var/cache/pacman/pkg /mnt/.snapshots /mnt/boot
  mount -o "$opts,subvol=@home" "$root_part" /mnt/home
  mount -o "$opts,subvol=@log" "$root_part" /mnt/var/log
  mount -o "$opts,subvol=@pkg" "$root_part" /mnt/var/cache/pacman/pkg
  mount -o "$opts,subvol=@snapshots" "$root_part" /mnt/.snapshots

  # Limine reads only FAT/ISO9660, so the kernel, initramfs, DTB and UKIs all
  # have to live on the ESP rather than on Btrfs. This is ours alone.
  mount "$esp_part" /mnt/boot

  DUALBOOT_ROOT_PART="$root_part"
  DUALBOOT_ROOT_UUID=$(blkid -s UUID -o value "$root_part")
  DUALBOOT_ESP="$esp_part"
  export DUALBOOT_ROOT_PART DUALBOOT_ROOT_UUID DUALBOOT_ESP

  echo "Dual-boot: mounted tree"
  findmnt -R /mnt -o TARGET,SOURCE,FSTYPE,OPTIONS
}

# Keep the ESP small: linux-aarch64 ships ~120MiB of device trees, but a given
# machine needs exactly one. Without this the shared ESP fills up and there is
# no headroom left for Limine snapshot entries.
limit_target_dtbs() {
  local keep="$1"
  [[ -n $keep ]] || return 0

  cat >>/mnt/etc/pacman.conf <<EOF

# Swarmarchy: keep only this board's device tree on the shared ESP.
NoExtract = boot/dtbs/*
NoExtract = !$keep
EOF
}

# Install Limine into its OWN directory on the shared ESP and register it with
# the firmware. EFI/Microsoft and EFI/BOOT are left exactly as they are, so
# Windows' bootloader and the existing boot order keep working.
install_dualboot_bootloader() {
  local esp_dir="/mnt/boot/EFI/swarmarchy"
  local loader='\EFI\swarmarchy\BOOTAA64.EFI'

  mkdir -p "$esp_dir"
  cp /usr/share/limine/BOOTAA64.EFI "$esp_dir/BOOTAA64.EFI"

  # Board-gated kernel arguments. These are what the Yoga Slim 7x needs to boot;
  # on anything else only the generic root= arguments are used.
  local board_args=""
  local dtb_rel="" dtb_line=""
  if grep -qa "x1e80100" /sys/firmware/devicetree/base/compatible 2>/dev/null; then
    board_args=" pd_ignore_unused clk_ignore_unused fw_devlink=off efi=novamp cma=128M rootwait"
    dtb_rel="boot/dtbs/qcom/x1e80100-lenovo-yoga-slim7x.dtb"
    [[ -f "/mnt/$dtb_rel" ]] || dtb_rel=""
  fi
  [[ -n $dtb_rel ]] && dtb_line="    dtb_path: boot():/${dtb_rel#boot/}"

  # ALARM installs the kernel as /boot/Image, not /boot/vmlinuz-linux.
  local kernel_img="Image"
  [[ -f /mnt/boot/$kernel_img ]] || kernel_img="vmlinuz-linux"

  # Write the config at the ESP ROOT, not next to the binary. Limine checks
  # "<EFI app path>/limine.conf" FIRST and, failing that, scans the ESP for
  # /limine.conf (CONFIG.md "Location of the config file") -- so both find it
  # here. Critically, /boot IS the ESP on the installed system, so this is the
  # "/boot/limine.conf" that the swarmarchy layer's install/login/limine-snapper.sh
  # searches for; that script exits 1 if it finds no config, and it deliberately
  # preserves this path while deleting configs found anywhere else. Putting a
  # limine.conf in $esp_dir as well would shadow it and hide the layer's entries.
  cat >"/mnt/boot/limine.conf" <<EOF
timeout: 3

/Swarmarchy
    protocol: linux
    path: boot():/$kernel_img
    cmdline: root=UUID=$DUALBOOT_ROOT_UUID rootflags=subvol=@ rw$board_args
    module_path: boot():/initramfs-linux.img
$dtb_line
EOF

  # Refresh the copied binary whenever the limine package is upgraded.
  mkdir -p /mnt/etc/pacman.d/hooks
  cat >/mnt/etc/pacman.d/hooks/99-limine.hook <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Limine after upgrade...
When = PostTransaction
Exec = /bin/sh -c "/usr/bin/cp /usr/share/limine/BOOTAA64.EFI /boot/EFI/swarmarchy/BOOTAA64.EFI"
EOF

  limit_target_dtbs "$dtb_rel"

  # Register with the firmware, preserving the existing boot order. efibootmgr
  # puts a new entry first; we restore the previous order with ours appended so
  # the machine keeps booting whatever it booted before until the user chooses.
  local esp_disk esp_partnum prev_order new_num
  esp_disk=$(lsblk -no PKNAME "$DUALBOOT_ESP" | tail -n1)
  esp_disk="/dev/$esp_disk"
  esp_partnum=$(cat "/sys/class/block/$(basename "$DUALBOOT_ESP")/partition" 2>/dev/null)
  prev_order=$(efibootmgr | awk -F': *' '/^BootOrder:/ {print $2}')

  if [[ -n $esp_partnum ]]; then
    efibootmgr --create --disk "$esp_disk" --part "$esp_partnum" \
      --label "Swarmarchy" --loader "$loader" --unicode >/dev/null || true

    new_num=$(efibootmgr | awk '/^Boot[0-9A-Fa-f]{4}\*? Swarmarchy$/ {print substr($1,5,4); exit}')
    if [[ -n $new_num && -n $prev_order ]]; then
      efibootmgr --bootorder "${prev_order},${new_num}" >/dev/null || true
    fi
  else
    echo "Dual-boot: could not determine ESP partition number; skipping NVRAM entry" >&2
  fi

  echo "Dual-boot: Limine installed to EFI/swarmarchy (Windows entries untouched)"
}

# archinstall's Snapper support is part of its btrfs_options, which the
# pre_mounted_config path never reads (device.py returns early for Pre_mount).
# Set it up ourselves so an alongside install gets the same rollback story as a
# wipe install. Non-fatal: a missing snapper config does not stop the machine
# from booting.
configure_dualboot_snapper() {
  arch-chroot /mnt command -v snapper >/dev/null 2>&1 || {
    echo "Dual-boot: snapper not present, skipping snapshot config" >&2
    return 0
  }

  # create-config insists on making /.snapshots itself, so hand it a clean path
  # and then swap our @snapshots subvolume back in underneath.
  umount /mnt/.snapshots 2>/dev/null || true
  rmdir /mnt/.snapshots 2>/dev/null || true

  if ! arch-chroot /mnt snapper --no-dbus -c root create-config /; then
    echo "Dual-boot: snapper create-config failed, continuing" >&2
  fi

  # Drop the subvolume create-config just made and restore ours.
  if [[ -d /mnt/.snapshots ]]; then
    btrfs subvolume delete /mnt/.snapshots 2>/dev/null || rm -rf /mnt/.snapshots
  fi
  mkdir -p /mnt/.snapshots
  mount -o compress=zstd,noatime,subvol=@snapshots "$DUALBOOT_ROOT_PART" /mnt/.snapshots
  chmod 750 /mnt/.snapshots

  arch-chroot /mnt systemctl enable snapper-timeline.timer snapper-cleanup.timer >/dev/null 2>&1 || true

  echo "Dual-boot: snapper configured on @snapshots"
}

install_base_system() {
  # Initialize and populate the keyring
  pacman-key --init
  pacman-key --populate archlinux
  pacman-key --populate archlinuxarm

  # Sync the offline database so pacman can find packages
  pacman -Sy --noconfirm

  if dualboot_enabled; then
    # Only release a previous attempt's mounts. The rest of this disk belongs to
    # other operating systems, so the whole-disk cleanup must not run.
    findmnt -R /mnt >/dev/null && umount -R /mnt || true
    prepare_dualboot_target
  else
    cleanup_install_disk "$(install_disk)"
  fi

  # Workarounds for archinstall 4.2 regressions under Python 3.14:
  # 1. sync_log_to_install_medium: `self.target / absolute_logfile` drops
  #    self.target because the RHS is absolute, so Path.copy() raises EINVAL
  #    (source == target).
  # 2. _add_limine_bootloader: `Path.copy(efi_dir_path)` raises IsADirectoryError
  #    because 3.14's Path.copy treats target as a literal path, not a directory
  #    (shutil.copy used to auto-append the source filename).
  sed -i \
    -e 's|logfile_target = self\.target / absolute_logfile$|logfile_target = self.target / absolute_logfile.relative_to("/")|' \
    -e 's|(limine_path / file)\.copy(efi_dir_path)|(limine_path / file).copy(efi_dir_path / file)|' \
    -e "s|(limine_path / 'limine-bios.sys')\.copy(boot_limine_path)|(limine_path / 'limine-bios.sys').copy(boot_limine_path / 'limine-bios.sys')|" \
    /usr/lib/python3.14/site-packages/archinstall/lib/installer.py

  # Install using files generated by the ./configurator
  # Skip NTP and WKD sync since we're offline (keyring is pre-populated in ISO)
  archinstall \
    --config user_configuration.json \
    --creds user_credentials.json \
    --silent \
    --skip-ntp \
    --skip-wkd \
    --skip-wifi-check \
    --skip-boot

  # After archinstall sets up the base system but before our installer runs,
  # we need to ensure the offline pacman.conf is in place
  cp /etc/pacman.conf /mnt/etc/pacman.conf

  # archinstall ran with "No bootloader" for an alongside install, so nothing has
  # been written to the shared ESP yet. Do it ourselves, in our own EFI subdir.
  if dualboot_enabled; then
    install_dualboot_bootloader
    configure_dualboot_snapper
  fi

  # Mount the offline mirror so it's accessible in the chroot
  mkdir -p /mnt/var/cache/swarmarchy/mirror/offline
  mount --bind /var/cache/swarmarchy/mirror/offline /mnt/var/cache/swarmarchy/mirror/offline

  # Mount the packages dir so it's accessible in the chroot
  mkdir -p /mnt/opt/packages
  mount --bind /opt/packages /mnt/opt/packages

  # No need to ask for sudo during the installation (swarmarchy itself responsible for removing after install)
  mkdir -p /mnt/etc/sudoers.d
  cat >/mnt/etc/sudoers.d/99-swarmarchy-installer <<EOF
root ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$SWARMARCHY_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 440 /mnt/etc/sudoers.d/99-swarmarchy-installer

  # Copy the local swarmarchy repo to the user's home directory
  mkdir -p /mnt/home/$SWARMARCHY_USER/.local/share/
  cp -r /root/swarmarchy /mnt/home/$SWARMARCHY_USER/.local/share/

  chown -R 1000:1000 /mnt/home/$SWARMARCHY_USER/.local/

  # Ensure all necessary scripts are executable
  find /mnt/home/$SWARMARCHY_USER/.local/share/swarmarchy -type f -path "*/bin/*" -exec chmod +x {} \;
  chmod +x /mnt/home/$SWARMARCHY_USER/.local/share/swarmarchy/boot.sh 2>/dev/null || true
  find /mnt/home/$SWARMARCHY_USER/.local/share/swarmarchy/default/waybar -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

  # Stage the per-machine Qualcomm X Elite board firmware onto the new root. Licensing forbids
  # shipping it in the ISO, so this sources the five board blobs from a user-staged qcom-firmware/
  # dir or the dual-boot Windows DriverStore and drops them at the exact board path the msm /
  # remoteproc drivers probe. Best-effort and non-fatal (no-op on non-Yoga hardware).
  swarmarchy-stage-qcom-firmware /mnt || true
}

configure_login_for_unencrypted_install() {
  if [[ $(<user_encrypt_installation.txt) != "false" ]]; then
    return
  fi

  # Unencrypted installs must stop at SDDM so the user password is entered
  # before reaching the desktop. Swarmarchy's normal encrypted path may autologin
  # because the disk password was already entered at boot.
  #
  # Keep the Swarmarchy SDDM theme and seed SDDM's last user/session state so
  # first boot looks like the SDDM screen shown after logging out of Swarmarchy.
  mkdir -p /mnt/etc/sddm.conf.d
  rm -f /mnt/etc/sddm.conf.d/autologin.conf
  cat >/mnt/etc/sddm.conf.d/99-swarmarchy-login.conf <<EOF
[Theme]
Current=swarmarchy

[Users]
RememberLastUser=true
RememberLastSession=true
EOF

  mkdir -p /mnt/var/lib/sddm
  cat >/mnt/var/lib/sddm/state.conf <<EOF
[Last]
Session=swarmarchy.desktop
User=$SWARMARCHY_USER
EOF

  rm -f /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf
  arch-chroot /mnt chown sddm:sddm /var/lib/sddm /var/lib/sddm/state.conf >/dev/null 2>&1 || true
  arch-chroot /mnt systemctl enable sddm.service >/dev/null 2>&1 || true
}

chroot_bash() {
  HOME=/home/$SWARMARCHY_USER \
    arch-chroot -u $SWARMARCHY_USER /mnt/ \
    env SWARMARCHY_CHROOT_INSTALL=1 \
    SWARMARCHY_USER_NAME="$(<user_full_name.txt)" \
    SWARMARCHY_USER_EMAIL="$(<user_email_address.txt)" \
    SWARMARCHY_MIRROR="$SWARMARCHY_MIRROR" \
    USER="$SWARMARCHY_USER" \
    HOME="/home/$SWARMARCHY_USER" \
    /bin/bash "$@"
}

if [[ $(tty) == "/dev/tty1" ]]; then
  use_swarmarchy_helpers
  run_configurator
  install_arch
  install_swarmarchy
fi
