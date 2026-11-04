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
# aarch64: dropped the x86 BCJ filter (`-Xbcj x86`); it is x86-only.
#
# zstd, not xz. Arch's x86 releng profile uses xz for the smallest possible image, but
# xz is by far the slowest to DEcompress, and every file the live installer touches is
# decompressed on the fly -- on an ARM CPU, reading from a USB stick. That is the single
# biggest reason the installer took minutes to come up. zstd at level 19 costs roughly
# 10-20% more image size and is several times faster to read back.
#
# -b 1M keeps the block size; squashfs-tools has zstd built in, so no new build dep.
# (erofs with -zlz4hc is faster still, but needs erofs-utils in the build container.)
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
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
