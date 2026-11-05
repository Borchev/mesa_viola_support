# RADV support for the Viola (13DA/13DC) int8 matrix instructions

A patch against Mesa 26.2.6.

Viola is the GPU in the PlayStation 5 Pro. It is a GFX1013 GPU (PCI device ID 0x13DA or 0x13DC) with
extra int8 matrix instructions. This patch makes RADV use them for int8 dot products in compute
shaders and enables the GPU's compute queue. Other GFX1013 GPUs are not affected.

## Testing

Tested on 13DA hardware with CachyOS and Mesa 26.2.6:

| Workload | Stock RADV | This patch | Speedup |
|---|---|---|---|
| 3x3 conv, 32→32 | 3.58 ms | 0.39 ms | 9.1× |
| 1x1 conv, 64→64 | 1.95 ms | 0.57 ms | 3.4× |
| Peak test | ~11 TOPS\* | 224 TOPS | ~21× |
| FSR4 network, per frame | ~3.4 ms | 0.94 ms | ~3.6× |

The convolutions are int8 layers on a 1920x1080 image (int8 activations and weights, ReLU, int8
outputs). The peak test runs int8 matrix-vector products with the data in registers and weights that
are constants in the shader. Both come from a small Vulkan benchmark, run with the GPU clock pinned
at 2350 MHz and the clock driver's temperature limit raised to avoid throttling.

\* Stock RADV doesn't run the peak test: its emulation of int8 dot products runs out of registers in
that shader. ~11 TOPS is its rate on the 3x3 layer.

FSR4's int8 network was timed with a Vulkan layer in a DX12 game under Proton (FSR4 INT8 through
OptiScaler, frame generation on), with the GPU at 2350 MHz. The stock time is a measurement at
2000 MHz (3.97 ms) scaled to 2350 MHz. The patch saves about 2.4 ms of GPU time per rendered frame:
with stock RADV the game dropped to 55 to 58 rendered fps in its heaviest section, and with the
patch it stayed at its 60 fps cap.

Other checks:

- Synthetic int8 layer tests against an exact CPU reference, on the graphics and compute queues.
- Four FSR4 layers replayed from a pipeline capture with random inputs: the output matches stock
  RADV exactly for two of them. In the other two, up to 2% of the int8 outputs differ by one, from
  the fp16 accumulation.
- The Debian 13, Ubuntu 26.04 and Fedora 45 tarballs were installed in clean containers of those
  releases: all libraries resolve and the Vulkan loader loads the driver. They haven't been run on
  Viola hardware yet; the results above are from the Arch package.

## FSR4 under Proton

Steam launch options for a DX12 game with FSR4 INT8, using Proton-CachyOS (which includes
OptiScaler) with this patch installed:

```
DXVK_CONFIG='dxgi.customDeviceDesc = "AMD 100-000000735 (RADV GFX1013) GFX110"' PROTON_OPTISCALER_CONFIG="FSR.Fsr4Update=true;Log.LogToFile=true" PROTON_USE_OPTISCALER=1 %command%
```

The `GFX110` in the device description makes OptiScaler take its RDNA3 path, where the FSR4 SDK
picks the INT8 model instead of the FP8 one, which needs WMMA. `FSR.Fsr4Update=true` makes FSR4
available. `Log.LogToFile=true` only turns on OptiScaler's log file and can be left out.

## What the patch does

- Detects Viola: `ac_is_viola()`, `has_viola_ml`.
- A NIR pass (`src/amd/vulkan/nir/radv_nir_opt_viola_int8_dot.c`) finds chains of int8 dot products
  (`sdot_4x8_iadd`, from SPIR-V `OpSDot` or HLSL `dot4add_i8packed`) whose weights are constants or
  the same for the whole wave, and rewrites them to the int8 matrix ops (0x23 and 0x24).
  Requantization of the results to int8 uses the quantize op (0x28).
- ACO: the new opcodes and their encoding, register allocation constraints, hazard waits, and
  scheduling that keeps independent accumulator chains interleaved (a dependent op stalls the SIMD).
- Constant weights go in the shader's constant data, and one scalar load reads up to four sets of
  weights. The scalar cache can only supply new weights for about half of the op's rate, so when
  a shader computes the same layer for several pixels, the pass emits their ops together and ACO
  loads each set of weights once for all of them.
- Compute shaders with int8 dot products are compiled as wave32 unless they need a particular wave
  size, and those that use the ops are limited to 10 waves per SIMD.
- Exposes the compute queue on Viola and works around partial-threadgroup corruption of async
  compute dispatches on GFX1013. The workaround comes from the BC-250 community; see
  [Credits](#credits).

## Runtime options

| Variable | Default | |
|---|---|---|
| `RADV_VIOLA_ML` | `1` | Use the int8 matrix ops. `0` gives the stock RADV code. |
| `RADV_VIOLA_ML_DEBUG` | `0` | For each compiled shader with int8 dot products, print a line with the number of ops used. |
| `RADV_VIOLA_ML_MAX_WAVES` | `10` | Maximum waves per SIMD for shaders using the ops, 4 to 20. `0` removes the limit. In testing, 10 performed optimally |
| `AMD_VIOLA_COMPUTE_QUEUE` | `1` | Expose the compute queue. `0` hides it, as stock Mesa does. |

`RADV_VIOLA_ML` and `RADV_VIOLA_ML_MAX_WAVES` are part of the shader cache key, so changing them
doesn't reuse shaders compiled with other values. A `RADV_VIOLA_ML_DEBUG=1` line looks like this:
`radv viola int8: CS: 64 dot chains -> 208 int8 matrix ops, 0 dot4 emulated, 12 quantize ops`.

## Files

| File | |
|---|---|
| `radv-viola-ml.patch` | The patch. Applies to Mesa 26.2.6 with `patch -Np1`. |
| `PKGBUILD` | Arch Linux / CachyOS package: RADV only, replaces `vulkan-radeon`. |
| `docker_build.sh` | Builds the driver in a container of the target distribution: the Arch package, or a tarball for Debian, Ubuntu or Fedora. |
| `VIOLA_INSTRUCTIONS.md` | The Viola ML instructions: encoding, operations, rules and throughput. |

## Building

### Arch Linux / CachyOS

Install the build tools and the packages the driver is built against:

```sh
sudo pacman -S --needed base-devel meson ninja python-mako python-packaging python-yaml glslang \
  wayland-protocols libxrandr expat libdisplay-info libdrm libelf libx11 libxcb libxshmfence \
  spirv-tools systemd-libs vulkan-icd-loader vulkan-mesa-implicit-layers wayland xcb-util-keysyms \
  zlib zstd
```

Then, in this folder:

```sh
makepkg -si
```

This downloads `mesa-26.2.6.tar.xz` from archive.mesa3d.org, checks it, applies the patch, builds
RADV and installs it in place of `vulkan-radeon`. Only the 64-bit driver is built;
`lib32-vulkan-radeon` stays stock.

To keep a system update from replacing it, add this to the `[options]` section of
`/etc/pacman.conf`:

```
IgnorePkg = vulkan-radeon
```

To go back to the distribution's driver: `sudo pacman -S vulkan-radeon`.

### With Docker, for any supported distribution

`docker_build.sh` builds the driver in a container of the distribution that will run it, so it is
linked against that release's libraries. It needs Docker and a user that can run it (in the `docker`
group, or run the script with `sudo`). It works from any directory and whatever the folder is
called. Pass the distribution and release of the target machine:

```sh
./docker_build.sh                # Arch Linux / CachyOS: vulkan-radeon-*.pkg.tar.zst
./docker_build.sh debian:13      # mesa-viola-debian-13.tar.gz
./docker_build.sh ubuntu:26.04   # mesa-viola-ubuntu-26.04.tar.gz
./docker_build.sh fedora:45      # mesa-viola-fedora-45.tar.gz
```

The argument is a Docker image name, so other releases of these distributions work the same way if
their packages are recent enough for Mesa 26.2.6. When a release's libdrm is older than Mesa needs
(Debian 13 and Ubuntu 26.04), the script builds a newer libdrm and links it into the driver. Only
the finished package or tarball is written next to the script, owned by the user who ran it; apart
from the images in Docker's cache, nothing is left on the build machine and nothing is installed
on it.

### Installing on the target machine

Copy the one file you built for the target's distribution to it, for example with scp, then
install it as below.

#### Arch Linux / CachyOS

Keep the `./` in front of the package's file name: it contains a colon, which scp would otherwise
read as a host name.

```sh
scp ./vulkan-radeon-*.pkg.tar.zst user@target:
```

Then on the target:

```sh
sudo pacman -U ~/vulkan-radeon-*.pkg.tar.zst
```

`IgnorePkg` and going back work as for the build with makepkg above.

#### Debian, Ubuntu and Fedora

The tarball installs the driver under `/usr/local/lib/mesa-viola` and leaves the distribution's
Mesa alone. It only needs libraries that the distribution's own Vulkan driver (`mesa-vulkan-drivers`)
already uses. For example, for Debian 13:

```sh
scp ./mesa-viola-debian-13.tar.gz user@target:
```

Then on the target:

```sh
sudo tar -C / -xf ~/mesa-viola-debian-13.tar.gz
```

Programs use it when `VK_DRIVER_FILES` points at its ICD file. For one program:

```sh
VK_DRIVER_FILES=/usr/local/lib/mesa-viola/share/vulkan/icd.d/radeon_icd.x86_64.json vkcube
```

For a Steam game, put the same setting in front of `%command%` in its launch options (this hasn't
been tested with Steam's runtime container yet). To use it for everything, add this line to
`/etc/environment` and log in again. The second file keeps the distribution's 32-bit driver for
32-bit programs, since only a 64-bit driver is built:

```
VK_DRIVER_FILES=/usr/local/lib/mesa-viola/share/vulkan/icd.d/radeon_icd.x86_64.json:/usr/share/vulkan/icd.d/radeon_icd.i686.json
```

To remove it, delete `/usr/local/lib/mesa-viola` and the `VK_DRIVER_FILES` setting.

#### Checking that it's active

Look for the compute-only queue family, which stock Mesa doesn't expose on GFX1013. With the patched
driver this prints one line, with stock Mesa nothing (`vulkaninfo` is in the `vulkan-tools`
package). On Debian, Ubuntu and Fedora, run it with `VK_DRIVER_FILES` set as above unless it is set
for everything.

```sh
vulkaninfo | grep -E "queueFlags *= QUEUE_COMPUTE_BIT"
```

### Other distributions, without Docker

Build dependencies: meson, ninja, python3 with mako, packaging and PyYAML, glslang, and the
development files for libdrm (2.4.133 or newer), libelf, expat, zlib, zstd, Wayland and X11 (xcb,
xshmfence, xrandr).

```sh
curl -LO https://archive.mesa3d.org/mesa-26.2.6.tar.xz
echo "b9436b3e1a8be76fbd4823dc884f90596ab7c6ac5e1867a305e66ffccfb31a92  mesa-26.2.6.tar.xz" | sha256sum -c
tar xf mesa-26.2.6.tar.xz
patch -d mesa-26.2.6 -Np1 -i ../radv-viola-ml.patch
meson setup build mesa-26.2.6 --buildtype release \
  -D vulkan-drivers=amd -D gallium-drivers= -D platforms=x11,wayland -D llvm=disabled \
  -D opengl=false -D glx=disabled -D egl=disabled -D gbm=disabled \
  -D gles1=disabled -D gles2=disabled -D glvnd=disabled -D vulkan-layers=
ninja -C build
```

To use the driver without installing it, run applications under `meson devenv -C build`, or point
the Vulkan loader at it:

```sh
VK_DRIVER_FILES=$PWD/build/src/amd/vulkan/radeon_devenv_icd.x86_64.json vkcube
```

## Limitations

- The ops accumulate in fp16 (scaled by 2^-14), not exact int32, so results can differ slightly from
  other drivers. Errors grow with the size of the sums.
- Dot products whose weights vary within a wave keep the emulated path, for example XeSS DP4a,
  whose weights are indexed by the invocation ID.
- The weights come from scalar registers, so the hardware does a matrix-vector product per lane.
  There is no cooperative matrix (WMMA) support.
- RADV with ACO only: `RADV_DEBUG=llvm` disables it, and radeonsi/rusticl aren't wired up.

## Credits

The async compute fix comes from work on the BC-250, another GFX1013 GPU with the same problem:
RADV's internal copy and fill shaders corrupt the partial last workgroup when they run on the
compute queue. DryhoppedIPA found that GFX1013 needs the threadgroup workaround Mesa already uses for
Iceland and Tonga and wrote the fix this patch uses, adding `CHIP_GFX1013` to
`has_async_compute_threadgroup_bug` in `src/amd/common/ac_gpu_info.c`.

- [DryhoppedIPA/bc250-gfx1013-fix](https://github.com/DryhoppedIPA/bc250-gfx1013-fix): the original
  fix and compute queue support for the BC-250. The non-kernel parts are MIT licensed. Its README
  lists other contributors.
- [tri3gubki-ops/bc250-async-compute-bazzite](https://github.com/tri3gubki-ops/bc250-async-compute-bazzite):
  packages the fix as a patched RADV for Bazzite.

Viola showed the same corruption in a test of RADV's fill, copy and clear operations on the compute
queue: 101 failures without the fix and none with it. The compute queue is enabled on Viola the same
way as on the BC-250.
