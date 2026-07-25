#!/bin/bash

set -e

# Target architecture — Swarmarchy: aarch64 (Snapdragon X Elite).
# Must match `arch=` in configs/profiledef.sh; archiso reads packages.${ARCH}.
ARCH="${ARCH:-aarch64}"

# Note that these are packages installed to the Arch container used to build the ISO.
# --disable-sandbox: the build host's kernel predates Landlock, so pacman's sandbox user
# switch fails ("Landlock ruleset could not be applied"). Same reason the manual install
# needed it (see swarmarchy docs/05).
PACMAN="pacman --noconfirm --disable-sandbox"
pacman-key --init
$PACMAN -Sy archlinux-keyring
$PACMAN -Sy git sudo base-devel jq grub curl

# archiso is NOT in the Arch Linux ARM repos (it's an x86-project package), but the package
# is arch=any — mkarchiso is a pure bash script that runs fine on aarch64. So pull the `any`
# package straight from a regular Arch mirror instead of `pacman -S archiso` (which 404s on
# ALARM). This is what lets us keep mkarchiso instead of switching to archboot.
archiso_pkg=$(curl -s https://geo.mirror.pkgbuild.com/extra/os/x86_64/ \
  | grep -o 'archiso-[0-9][^"]*-any.pkg.tar.zst' | sort -u | tail -1)
$PACMAN -U "https://geo.mirror.pkgbuild.com/extra/os/x86_64/$archiso_pkg"

# Generic build: verify ALARM packages with the Arch Linux ARM keyring (no omarchy repo/key).
$PACMAN -Sy archlinuxarm-keyring
pacman-key --populate archlinuxarm

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/swarmarchy/mirror/offline"
mkdir -p $build_cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config.
# NOTE(aarch64): upstream archiso ships ONLY an x86_64 `releng` profile. The copy
# below is x86-centric (packages.x86_64, syslinux/BIOS, x86 microcode). A fully
# bootable aarch64 ISO needs this profile adapted for Arch Linux ARM. See
# BUILD-AARCH64.md. We retarget the package-list filename and strip x86-only pkgs.
cp -r /archiso/configs/releng/* $build_cache_dir/
rm "$build_cache_dir/airootfs/etc/motd"

# archiso reads packages.${arch}; rename the releng x86_64 list to our target arch
# and drop entries that cannot resolve on aarch64.
if [[ "$ARCH" != "x86_64" && -f "$build_cache_dir/packages.x86_64" ]]; then
  mv "$build_cache_dir/packages.x86_64" "$build_cache_dir/packages.$ARCH"
  # x86-only / VM-guest / Arch-only entries from the releng packages.x86_64 list that have no
  # aarch64 package in ALARM: microcode, memtest, syslinux(BIOS), broadcom-wl, VM guest tools
  # (hyperv/open-vm-tools/virtualbox), refind (we boot via grub), reflector (Arch mirror tool).
  sed -i -E '/^(intel-ucode|amd-ucode|memtest86\+|memtest86\+-efi|syslinux|edk2-shell|b43-fwcutter|broadcom-wl|hyperv|open-vm-tools|virtualbox-guest-utils-nox|refind|reflector)$/d' \
    "$build_cache_dir/packages.$ARCH"
  # ALARM ships the generic kernel as `linux-aarch64`, not `linux`.
  sed -i -E 's/^linux$/linux-aarch64/; s/^linux-headers$/linux-aarch64-headers/' \
    "$build_cache_dir/packages.$ARCH"
fi

# Avoid using reflector for mirror identification as we are relying on the global CDN
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our configs
cp -r /configs/* $build_cache_dir/

# ALARM ships linux-aarch64.preset (builds /boot/initramfs-linux.img with our archiso.conf
# HOOKS drop-in). The releng profile's linux.preset targets the x86 `linux` package we never
# install; left in place it triggers a spurious (non-fatal) mkinitcpio failure during pacstrap
# ("-k /boot/vmlinuz-linux must be readable"). Remove it so only linux-aarch64.preset runs.
rm -f "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux.preset"

# Persist SWARMARCHY_MIRROR so it's available at install time
echo "$SWARMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/swarmarchy_mirror"

# Setup Swarmarchy itself
if [[ -d /swarmarchy ]]; then
  cp -rp /swarmarchy "$build_cache_dir/airootfs/root/swarmarchy"
else
  git clone -b $SWARMARCHY_INSTALLER_REF https://github.com/$SWARMARCHY_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/swarmarchy"
fi

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/swarmarchy/bin/swarmarchy-upload-log" "$build_cache_dir/airootfs/usr/local/bin/swarmarchy-upload-log"


# Download and verify Node.js binary for offline installation
NODE_DIST_URL="https://nodejs.org/dist/latest"

# Get checksums and parse filename and SHA
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-arm64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-arm64.tar.gz" | awk '{print $1}')

# Download the tarball
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"

# Verify SHA256 checksum
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c - || {
    echo "ERROR: Node.js checksum verification failed!"
    exit 1
}

# Copy to ISO
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Add our additional packages to the live ISO package list.
# aarch64: dropped `linux-t2` (Apple) and `plymouth`.
arch_packages=(git gum jq openssl tzupdate lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.$ARCH"

# Build list of all the packages needed for the offline mirror
all_packages=($(cat "$build_cache_dir/packages.$ARCH"))
# First-token parse so inline "package  # what it is" comments are ignored.
strip_pkgs() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1" | awk '{print $1}'; }
all_packages+=($(strip_pkgs "$build_cache_dir/airootfs/root/swarmarchy/install/swarmarchy-base.packages"))
all_packages+=($(strip_pkgs "$build_cache_dir/airootfs/root/swarmarchy/install/swarmarchy-other.packages"))
all_packages+=($(strip_pkgs /builder/archinstall.packages))

# Download all the packages to the offline mirror inside the ISO
mkdir -p /tmp/offlinedb
pacman --config /configs/pacman-online-${SWARMARCHY_MIRROR}.conf --noconfirm --disable-sandbox -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb
# ALARM packages (and our custom repo pkgs, host makepkg PKGEXT=.pkg.tar.xz) are xz-compressed,
# not zst. Match both extensions via nullglob so an unmatched pattern expands to nothing instead
# of a literal glob string (which repo-add would treat as a missing file, tripping set -e).
# The *.pkg.tar.{xz,zst} patterns exclude the detached *.sig signatures by construction.
shopt -s nullglob
offline_pkgs=("$offline_mirror_dir/"*.pkg.tar.zst "$offline_mirror_dir/"*.pkg.tar.xz)
shopt -u nullglob
repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "${offline_pkgs[@]}"

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/swarmarchy/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/swarmarchy/mirror/offline
mkdir -p /var/cache/swarmarchy/mirror
ln -s "$offline_mirror_dir" "/var/cache/swarmarchy/mirror/offline"

# Copy the offline pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted. 
cp $build_cache_dir/pacman-offline.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# aarch64 boot: the Snapdragon X Elite Yoga needs its board device tree handed to the kernel
# by GRUB (`devicetree` in grub.cfg/loopback.cfg). mkarchiso copies any non-.cfg file from the
# profile's grub/ dir verbatim into the ISO's /boot/grub/, so stage the DTB there. It ships
# inside ALARM's linux-aarch64 package (already downloaded to the offline mirror) at
# boot/dtbs/qcom/x1e80100-lenovo-yoga-slim7x.dtb.
dtb_rel="boot/dtbs/qcom/x1e80100-lenovo-yoga-slim7x.dtb"
linux_pkg=$(ls -1 "$offline_mirror_dir/"linux-aarch64-*.pkg.tar.* 2>/dev/null | grep -vE '\.sig$' | head -1)
if [[ -z "$linux_pkg" ]]; then
  echo "ERROR: linux-aarch64 package not found in offline mirror; cannot extract board DTB." >&2
  exit 1
fi
mkdir -p "$build_cache_dir/grub"
bsdtar -xOf "$linux_pkg" "$dtb_rel" > "$build_cache_dir/grub/x1e80100-lenovo-yoga-slim7x.dtb"
if [[ ! -s "$build_cache_dir/grub/x1e80100-lenovo-yoga-slim7x.dtb" ]]; then
  echo "ERROR: extracted Yoga DTB is empty (expected $dtb_rel in $linux_pkg)." >&2
  exit 1
fi

# mkarchiso hardcodes the GRUB modules baked into the EFI core image (grubmodules=(...) in
# _make_bootmode_uefi.grub). That static list is x86-centric: it includes `at_keyboard` (PS/2,
# which has no arm64-efi .mod so grub-mkstandalone aborts) and omits `fdt` (which provides the
# `devicetree` command the Snapdragon needs). Rather than hard-code an arm64 module list that
# could drift with the grub package, inject a filter right after the array definition that adds
# `fdt` and keeps only modules that actually have a .mod under /usr/lib/grub/$grub_target.
if ! grep -q 'SWARMARCHY_GRUBMOD_FILTER' /usr/bin/mkarchiso; then
  awk '
    { print }
    /usbserial_pl2303 usbserial_usbdebug video xfs zstd\)/ {
      print "    # SWARMARCHY_GRUBMOD_FILTER: add fdt, keep only modules present for $grub_target"
      print "    { local _gm=() _m; for _m in fdt \"${grubmodules[@]}\"; do [[ -f \"/usr/lib/grub/${grub_target}/${_m}.mod\" ]] && _gm+=(\"$_m\"); done; grubmodules=(\"${_gm[@]}\"); }"
    }
  ' /usr/bin/mkarchiso > /tmp/mkarchiso.patched && cat /tmp/mkarchiso.patched > /usr/bin/mkarchiso
fi
grep -q 'SWARMARCHY_GRUBMOD_FILTER' /usr/bin/mkarchiso || { echo "ERROR: failed to patch mkarchiso grubmodules filter." >&2; exit 1; }

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
