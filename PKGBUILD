# RADV only, with the Viola (13DA/13DC) int8 matrix instruction patch.
pkgname=vulkan-radeon
epoch=1
pkgver=26.2.6
pkgrel=1.14
pkgdesc="Open-source Vulkan driver for AMD GPUs (Viola int8 matrix patch)"
arch=(x86_64)
url="https://www.mesa3d.org/"
license=('MIT AND BSD-3-Clause AND SGI-B-2.0')
depends=(expat glibc libdisplay-info libdrm libelf libgcc libstdc++ libx11 libxcb libxshmfence
         spirv-tools systemd-libs vulkan-icd-loader vulkan-mesa-implicit-layers wayland
         xcb-util-keysyms zlib zstd)
makedepends=(meson ninja python-mako python-packaging python-yaml glslang wayland-protocols
             libxrandr)
provides=(vulkan-driver)
options=(!debug)
source=("https://archive.mesa3d.org/mesa-$pkgver.tar.xz" radv-viola-ml.patch)
sha256sums=(b9436b3e1a8be76fbd4823dc884f90596ab7c6ac5e1867a305e66ffccfb31a92 11bb1313e1339482d1733004bf6db05b7bc8409de44a3372a6095b0c61fa316d)

prepare() {
  patch -d mesa-$pkgver -Np1 -i ../radv-viola-ml.patch
}

build() {
  # arch-meson without --auto-features enabled, which would need gallium and GL.
  meson setup mesa-$pkgver build --prefix /usr --libexecdir lib --sbindir bin --buildtype plain \
    --wrap-mode nodownload -D b_pie=true -D python.bytecompile=1 \
    --optimization 2 \
    -D b_ndebug=true \
    -D platforms=x11,wayland \
    -D vulkan-drivers=amd \
    -D gallium-drivers= \
    -D opengl=false -D glx=disabled -D egl=disabled -D gbm=disabled -D gles1=disabled -D gles2=disabled -D glvnd=disabled \
    -D llvm=disabled \
    -D video-codecs=all \
    -D vulkan-layers= \
    -D vulkan-manifest-per-architecture=false \
    -D amdgpu-virtio=true \
    -D android-libbacktrace=disabled -D libunwind=disabled -D valgrind=disabled
  meson compile -C build
}

package() {
  DESTDIR="$pkgdir" meson install -C build
  # Owned by the mesa package.
  rm "$pkgdir/usr/share/drirc.d/00-mesa-defaults.conf"
  install -Dm644 mesa-$pkgver/docs/license.rst -t "$pkgdir/usr/share/licenses/$pkgname"
}
