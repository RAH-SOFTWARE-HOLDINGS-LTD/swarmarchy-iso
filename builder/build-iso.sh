#!/bin/bash

set -e

# Target architecture — Swarmarchy: aarch64 (Snapdragon X Elite).
# Must match `arch=` in configs/profiledef.sh; archiso reads packages.${ARCH}.
ARCH="${ARCH:-aarch64}"

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Pre-import the omarchy signing key so pacman can verify packages without a keyserver lookup
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# Install omarchy-keyring for package verification during build
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
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
  sed -i -E '/^(intel-ucode|amd-ucode|memtest86\+|memtest86\+-efi|syslinux|edk2-shell|b43-fwcutter)$/d' \
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

# Persist OMARCHY_MIRROR so it's available at install time
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"

# Setup Omarchy itself
if [[ -d /omarchy ]]; then
  cp -rp /omarchy "$build_cache_dir/airootfs/root/omarchy"
else
  git clone -b $OMARCHY_INSTALLER_REF https://github.com/$OMARCHY_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/omarchy"
fi

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/omarchy/bin/omarchy-upload-log" "$build_cache_dir/airootfs/usr/local/bin/omarchy-upload-log"


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
# aarch64: dropped `linux-t2` (Apple) and `plymouth`. `omarchy-keyring` is x86-only
# (TODO: provide an aarch64 keyring/repo before this will resolve).
arch_packages=(git gum jq openssl tzupdate lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.$ARCH"

# Build list of all the packages needed for the offline mirror
all_packages=($(cat "$build_cache_dir/packages.$ARCH"))
# First-token parse so inline "package  # what it is" comments are ignored.
strip_pkgs() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1" | awk '{print $1}'; }
all_packages+=($(strip_pkgs "$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages"))
all_packages+=($(strip_pkgs "$build_cache_dir/airootfs/root/omarchy/install/omarchy-other.packages"))
all_packages+=($(strip_pkgs /builder/archinstall.packages))

# Download all the packages to the offline mirror inside the ISO
mkdir -p /tmp/offlinedb
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb
repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/omarchy/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/omarchy/mirror/offline
mkdir -p /var/cache/omarchy/mirror
ln -s "$offline_mirror_dir" "/var/cache/omarchy/mirror/offline"

# Copy the offline pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted. 
cp $build_cache_dir/pacman-offline.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
