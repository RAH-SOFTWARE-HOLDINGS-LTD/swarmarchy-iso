#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="swarmarchy"
iso_label="SWARMARCHY_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Swarmarchy"
iso_application="Swarmarchy Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
# aarch64: UEFI only — BIOS/syslinux is x86-only and dropped.
bootmodes=('uefi.grub')
arch="aarch64"
pacman_conf="pacman-offline.conf"
airootfs_image_type="squashfs"
# aarch64: dropped the x86 BCJ filter (`-Xbcj x86`); plain xz works on any arch.
#
# NOT zstd: ALARM's linux-aarch64 is built with `# CONFIG_SQUASHFS_ZSTD is not set` (checked
# on 7.3.0 and 7.3.5), so the live initramfs cannot mount a zstd airootfs.sfs and the boot
# stops before the installer -- on the Yoga that is a black screen, since the display driver
# never loads. Every ISO built with zstd (2026-11-04 onwards) failed this way. The kernel
# reads xz, lz4, lzo and zlib; xz is what the last ISO known to boot (2026-10-28) used.
airootfs_image_tool_options=('-comp' 'lz4' '-Xhc' '-b' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/root/configurator"]="0:0:755"
  ["/var/cache/swarmarchy/mirror/offline/"]="0:0:775"
  ["/usr/local/bin/swarmarchy-upload-log"]="0:0:755"
  ["/usr/local/bin/swarmarchy-upload-file"]="0:0:755"
  ["/usr/local/bin/swarmarchy-stage-qcom-firmware"]="0:0:755"
)
