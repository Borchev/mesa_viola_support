#!/bin/sh
# Build the patched RADV in a container of the target distribution. Output goes next to this script.
#
#   ./docker_build.sh                Arch Linux / CachyOS package (vulkan-radeon-*.pkg.tar.zst)
#   ./docker_build.sh debian:13      tarball for that distribution and release, installed under
#   ./docker_build.sh ubuntu:26.04   /usr/local/lib/mesa-viola (mesa-viola-<distro>-<release>.tar.gz)
#   ./docker_build.sh fedora:45
#
# Build on the same release as the machine that will run the driver.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
target=${1:-archlinux}
owner="$(id -u):$(id -g)"

# The Mesa version and its checksum come from the PKGBUILD.
pkgver=$(sed -n 's/^pkgver=//p' "$dir/PKGBUILD")
sha256=$(sed -n 's/^sha256sums=(\([0-9a-f]*\) .*/\1/p' "$dir/PKGBUILD")

# Linked statically into the driver when the distribution's libdrm is older than Mesa needs.
libdrm_ver=2.4.133
libdrm_sha256=fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5

case "$target" in
arch | archlinux | archlinux:*)
   docker run --rm -v "$dir":/pkg -e OWNER="$owner" archlinux bash -c '
set -e
pacman -Syu --noconfirm --needed \
  base-devel meson ninja python-mako python-packaging python-yaml glslang \
  wayland-protocols libxrandr libxxf86vm expat libdisplay-info libdrm libelf \
  libx11 libxcb libxshmfence systemd-libs vulkan-icd-loader \
  vulkan-mesa-implicit-layers wayland xcb-util-keysyms zlib zstd

# makepkg refuses to run as root.
useradd -m builder
mkdir -p /tmp/out
chown builder /tmp/out
su builder -c "cd /pkg && BUILDDIR=/tmp/out SRCDEST=/tmp/out PKGDEST=/tmp/out makepkg -f"

cp /tmp/out/*.pkg.tar.zst /pkg/
chown $OWNER /pkg/*.pkg.tar.zst
'
   ls -l "$dir"/vulkan-radeon-*.pkg.tar.zst
   exit 0
   ;;
debian:* | ubuntu:*)
   deps='
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl xz-utils patch pkg-config bison flex \
  meson ninja-build python3-mako python3-packaging python3-yaml glslang-tools \
  libdrm-dev libelf-dev libexpat1-dev zlib1g-dev libzstd-dev libudev-dev \
  libwayland-dev wayland-protocols libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev \
  libxcb1-dev libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev libxcb-shm0-dev \
  libxcb-xfixes0-dev libxcb-randr0-dev libxshmfence-dev libxrandr-dev libxxf86vm-dev'
   ;;
fedora:*)
   deps='
dnf install -y \
  gcc gcc-c++ curl xz tar gzip patch pkgconf-pkg-config bison flex \
  meson ninja-build python3-mako python3-packaging python3-pyyaml glslang \
  libdrm-devel elfutils-libelf-devel expat-devel zlib-devel libzstd-devel systemd-devel \
  wayland-devel wayland-protocols-devel libX11-devel libXext-devel libXfixes-devel \
  libxcb-devel libxshmfence-devel libXrandr-devel libXxf86vm-devel'
   ;;
*)
   echo "Unsupported target: $target (use archlinux, debian:<release>, ubuntu:<release> or fedora:<release>)" >&2
   exit 1
   ;;
esac

out=mesa-viola-$(echo "$target" | tr ':/' '--').tar.gz

docker run --rm -v "$dir":/pkg -e OWNER="$owner" -e PKGVER="$pkgver" -e SHA256="$sha256" \
   -e LIBDRM_VER="$libdrm_ver" -e LIBDRM_SHA256="$libdrm_sha256" -e OUT="$out" \
   "$target" sh -c "set -e
$deps"'
cd /tmp
curl -fsSLO "https://archive.mesa3d.org/mesa-$PKGVER.tar.xz"
echo "$SHA256  mesa-$PKGVER.tar.xz" | sha256sum -c
tar xf "mesa-$PKGVER.tar.xz"
patch -d "mesa-$PKGVER" -Np1 -i /pkg/radv-viola-ml.patch

need=$(sed -n "s/^_drm_amdgpu_ver = .\(.*\)./\1/p" "mesa-$PKGVER/meson.build")
if ! pkg-config --atleast-version="$need" libdrm_amdgpu; then
   if [ "$(printf "%s\n%s\n" "$need" "$LIBDRM_VER" | sort -V | head -n 1)" != "$need" ]; then
      echo "Mesa $PKGVER needs libdrm $need, newer than libdrm $LIBDRM_VER in this script" >&2
      exit 1
   fi
   echo "The system libdrm is older than $need: linking libdrm $LIBDRM_VER statically"
   curl -fsSLO "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz"
   echo "$LIBDRM_SHA256  libdrm-$LIBDRM_VER.tar.xz" | sha256sum -c
   tar xf "libdrm-$LIBDRM_VER.tar.xz"
   # Read the GPU name table from where the distribution installs it.
   q=$(printf "\047")
   sed -i "s|^datadir_amdgpu = .*|datadir_amdgpu = ${q}/usr/share/libdrm${q}|" \
      "libdrm-$LIBDRM_VER/amdgpu/meson.build"
   meson setup libdrm-build "libdrm-$LIBDRM_VER" --prefix=/opt/libdrm --libdir=lib \
     --buildtype=release -D default_library=static -D amdgpu=enabled \
     -D intel=disabled -D radeon=disabled -D nouveau=disabled -D vmwgfx=disabled \
     -D omap=disabled -D exynos=disabled -D freedreno=disabled -D tegra=disabled \
     -D etnaviv=disabled -D cairo-tests=disabled -D man-pages=disabled -D valgrind=disabled \
     -D udev=false -D tests=false -D install-test-programs=false
   ninja -C libdrm-build install
   export PKG_CONFIG_PATH=/opt/libdrm/lib/pkgconfig
fi

# Without libdisplay-info (monitor EDID names for VK_KHR_display) and xcb-keysyms (a trace capture
# hotkey), the driver only needs libraries that the distribution Mesa already uses.
meson setup build "mesa-$PKGVER" --prefix=/usr/local/lib/mesa-viola --libdir=lib \
  --buildtype=release -D display-info=disabled \
  -D vulkan-drivers=amd -D gallium-drivers= -D platforms=x11,wayland -D llvm=disabled \
  -D opengl=false -D glx=disabled -D egl=disabled -D gbm=disabled \
  -D gles1=disabled -D gles2=disabled -D glvnd=disabled -D vulkan-layers= \
  -D valgrind=disabled -D libunwind=disabled
ninja -C build
DESTDIR=/tmp/stage ninja -C build install

tar -C /tmp/stage --owner=0 --group=0 -czf "/pkg/$OUT" usr
chown "$OWNER" "/pkg/$OUT"
'
ls -l "$dir/$out"
