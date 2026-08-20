# PGenerator+ ICC Tools

Desktop tools for creating and loading ICC profiles with PGenerator+:

- **Patch Companion** displays measurement patches on the computer being
  profiled. A PGenerator+ unit controls it over the network.
- **Profile Loader** installs an ICC profile, applies it to a display in SDR or
  HDR, and checks that the display continues to use it.

Download current builds from the [latest release](../../releases/latest).

## Downloads

| Asset | Platform | Contents |
| --- | --- | --- |
| `PGeneratorPlus-ICC-Tools-Windows-x64.exe` | Windows 10/11 x64 | Installer for Patch Companion, Profile Loader, ArgyllCMS `targen`, `colprof`, and `profcheck`, Start Menu entries, and the uninstaller |
| `PGeneratorPlus-ICC-Tools-Portable-Windows-x64.zip` | Windows 10/11 x64 | Portable versions of the same programs |
| `PGeneratorPlus-ICC-Tools-Linux-x64.zip` | x86-64 Linux with glibc 2.38 or newer | Patch Companion, Profile Loader, ArgyllCMS `targen`, `colprof`, and `profcheck`, bundled SDL3, and the KDE HDR tone-mapping reset helper |
| `PGeneratorPlus-ICC-Tools-ArchLinux-x86_64.pkg.tar.zst` | Arch Linux x86-64 | Native package of the Linux tools, installed under `/opt/pgen-icc-tools` with commands linked into `/usr/bin` |
| `PGeneratorPlus-ICC-Tools-macOS-arm64.dmg` | macOS 14+ on Apple Silicon, experimental | Disk image with Patch Companion and ArgyllCMS `targen`, `colprof`, and `profcheck`; HDR presents through Metal EDR, and profile installing is not offered on macOS |

The Windows builds are not code-signed, so Windows may show a SmartScreen
warning.

## Current release

Version 1.4.26 is paired with the current PGenerator+ build. The desktop tools
in this release:

- recover and verify Windows Advanced Color when an upgrade interrupts the
  disable/re-enable reload cycle, including the case where DXGI initially
  reports HDR as off;
- start the newly installed Profile Loader after silent and interactive
  upgrades so persisted correction isolation is restored before use;
- restore an interrupted Windows correction isolation before accepting a new
  explicit cLUT request, preventing a cold start from caching the temporary
  vendor fallback profile;
- retry the requested explicit correction after that recovery completes,
  without requiring a settings toggle or another application on the display;
- isolate Windows' selected-monitor profile stage while explicit cLUT, matrix,
  or no-correction handling is active, so each test uses only the correction
  path selected by the operator;
- evaluate the profile's B2A0 transform directly for cLUT handling without
  substituting MHC2 neutral curves or applying an MHC2 inverse;
- restore the selected monitor's saved Windows profile scope and association
  when explicit correction ends or a new profile is installed;
- restore and verify the active Windows MHC2 stage after HDR presentation
  changes before acknowledging a measurement patch;
- perform the recovery handoff on the selected display, keeping foreground
  recovery independent of another application or monitor;
- keep an exact-neutral cLUT endpoint on the measured MHC2 shoulder only when
  the profile contains a genuinely held highlight plateau;
- queue profile applies received during an Advanced Color reload so the newest
  build or fine-tune profile always wins;
- preserve Windows MHC2 correction while OLED protection patches are inserted;
- classify Windows SDR and Advanced Color profile associations from ICC
  content, including PGenerator+'s explicit association marker, instead of
  relying on the file name;
- replace stale same-named profiles in the Windows color store and verify the
  installed bytes;
- preserve a saved Advanced Color association for unmarked vendor profiles;
- reload Windows Advanced Color after an MHC2 profile changes and wait for the
  reload before reporting that the profile is ready;
- bundles a colprof build that fills B2A tables across worker processes on
  Linux, cutting local profile fitting time roughly in half on multi-core
  machines while producing byte-identical profiles;
- preserves HDR relative-PCS headroom above measured white so B2A input
  shapers can represent a display's highlight rolloff;
- applies VCGT after the B2A device transform in standard ICC order, while
  retaining the encoded-domain neutral path used by MHC2;
- keeps polling PGenerator+ while Windows installs a profile, preventing the
  WebUI from reporting that Companion disconnected during a slow Windows
  color-management call;
- preserves the Companion server and pairing token when the Windows tools are
  upgraded;
- cleans up the silent Linux Profile Loader process after an install;
- reports a successful Windows profile association as soon as the selected
  per-user default is active, while Windows finishes any remaining work in
  the background;
- selects HDR correction mode from the active Windows HDR association rather
  than an unrelated SDR profile;
- always loads the patched SDL bundled with the Linux tools, preventing stock
  distro SDL builds from rejecting native HDR10 Vulkan output;
- enables Windows' per-user display profile list when installing a profile,
  matching the "Use my settings for this device" option in Color Management;
- accepts **Install & Apply** requests from the PGenerator+ profile history
  and hands the profile to Profile Loader for the display showing patches;
- adapts HDR source colors from BT.2020 D65 to the D50 B2A connection space,
  including profiles with no VCGT;
- evaluates `mft2` cLUTs with the same trilinear 3D texture interpolation used
  by KWin;
- keeps every HDR swapchain image current for 15 seconds after a patch change,
  then stops presenting while idle instead of continuously consuming GPU;
- treats KDE's SDR reference as cd/m2 and does not multiply it by desktop
  scale; and
- waits for a successful profile upload response before reporting a remote
  build as complete.

The Linux archive and Arch package also contain `reset-hdr-tonemapping.sh`.
The bundled `targen`, `colprof`, and `profcheck` binaries are built from the pinned
`ArgyllCMS_ICC4.4` submodule at commit `0613c3f` (`argyll-4.4-icc44-pgen1`),
including the ICC 4.4/CICP support and the Linux parallel B2A table builder.
The Windows package workflow cross-builds both executables from that submodule
and rejects the installer and portable archive unless their packaged
`colprof.exe` advertises the patched `-4` ICC 4.4 option.
The macOS arm64 workflow is pinned to the same commit and rejects its archive
unless the packaged `colprof` is arm64, byte-identical to that build, and
advertises the same ICC 4.4 option.
The release `SHA256SUMS` file covers all downloads.

### Installing a completed profile from the WebUI

Keep Patch Companion open on the display being profiled. Completed builds and
saved entries in Profile History then show a green **Install & Apply** button
beside **Download**.

On Windows, Patch Companion hands Profile Loader the new ICC and the exact
monitor identity. Profile Loader performs the Windows install and HDR or SDR
association, saves that monitor/profile pairing, verifies the active default,
and keeps its normal automatic reapply behavior from the tray. This also works
when Profile Loader was not already running, without forcing its window open.

On Linux, the same action runs Profile Loader silently for the selected
monitor. The profile is copied into the user's ICC directory and applied
through KWin on Plasma, or through colord on supported non-KDE sessions. The
one-shot Loader exits after applying it, and Companion verifies the selected
profile before reporting success. The WebUI does not offer this action when
Patch Companion is disconnected.

### Calibration choices

PGenerator+ offers three calibration modes, and they are not interchangeable.

- **Calibration with VCGT** stores separate curves in the VCGT tag. Patched
  KWin applies HDR neutral calibration in source-PQ coordinates.
- **Calibration without VCGT** includes the curves in the ICC transforms. KDE
  HDR cLUT profiles store them in high-resolution B2A output shapers so a
  sharp OLED rolloff is not approximated by the 3D grid.
- **No calibration** characterizes the display as measured and is intended for
  a TV or monitor already calibrated internally.

Removing VCGT from a calibrated-domain profile does not turn it into a valid
profile with included calibration. Adding VCGT to an uncalibrated profile is
wrong for the same reason. Build the profile for the path that will be active
during normal use.

### Release naming

The PGenerator+ WebUI relies on the following names:

- Tags use `v<major>.<minor>.<patch>`, for example `v1.4.0`. The tag must match
  the version reported by Patch Companion. The WebUI compares that version
  with the latest release tag and reports when the companion is out of date.
- Asset filenames remain exactly as listed in the downloads table.
- The WebUI links to `releases/latest`, not directly to an asset. This keeps the
  link stable and starts the download from GitHub over HTTPS. Downloads started
  directly by the PGenerator+ HTTP WebUI may otherwise be flagged as insecure
  by Chrome or Edge.

## Pairing with PGenerator+

Release builds are not configured for a specific PGenerator+ unit. Patch
Companion discovers and pairs with a unit when first started:

1. It resolves `pgenerator.local` through mDNS.
2. It sends a pairing request and displays a six-digit code.
3. The PGenerator+ WebUI shows the same request and code beside the Patch
   Companion status.
4. After the request is approved in the WebUI, the unit returns a token. Patch
   Companion saves the token for later connections.

The unit generates the pairing code, and no token is issued until the request
is approved.

If mDNS is unavailable, or more than one PGenerator+ is present, set the server
address in `PGenPatchCompanion.conf` beside the executable:

```ini
SERVER=http://192.0.2.10
```

Alternatively, pass it on the command line:

```sh
PGenPatchCompanion --server=http://192.0.2.10
```

An explicitly configured server takes precedence over discovery.

## KDE HDR tone-mapping reset

The Linux archive includes `reset-hdr-tonemapping.sh`. It resets KWin's HDR
peak, maximum-average and minimum-luminance overrides to the values advertised
by each monitor. It also restores KDE's display-derived SDR reference default
and cycles HDR so KWin rebuilds the live output pipeline. The selected ICC
path and HDR profile source are deliberately left untouched.

Run it from the Plasma Wayland desktop as the logged-in user, not with `sudo`.
Close the HDR brightness calibrator first. The reset briefly turns HDR off and
back on for each selected output, so do not run it during a measurement series.

Preview the detected monitors and changes first:

```sh
./reset-hdr-tonemapping.sh --dry-run
```

Reset every connected, enabled HDR monitor:

```sh
./reset-hdr-tonemapping.sh
```

Use `--output DP-2` to select one connector or `--keep-sdr` to retain its
current SDR reference brightness.

## Source layout

```text
Common/     Shared Patch Companion source, generated icon header, generator,
            Wayland protocol files, and configuration template
Windows/    Windows Profile Loader source, resources, manifests, and installer
Linux/      Linux launcher and Profile Loader source, generated font header,
            and generator
licenses/   Third-party licences included with distributed builds
favicon.ico Shared application artwork
```

`Common/pgen-icc-companion.c` is compiled unchanged on Linux and Windows.
Platform-specific code is selected with `#ifdef _WIN32`.

The Profile Loader has separate implementations:

- `Windows/pgen-profile-loader.c` uses the Windows colour-management APIs.
- `Linux/pgen-profile-loader-linux.c` uses SDL3 and communicates with KWin or
  colord.

The following generated headers are committed to the repository:

| File | Generator | Used by |
| --- | --- | --- |
| `Common/pgen-icc-companion-icon.h` | `Common/make-icon-header.py`, using `favicon.ico` | Linux Patch Companion and Linux Profile Loader |
| `Linux/pgen-ui-font.h` | `Linux/make-font-header.py`, using DejaVu fonts | Patch Companion and Linux Profile Loader |

Pillow and the DejaVu font files are needed only when regenerating these
headers. Keep `favicon.ico` at the repository root because the generators and
Windows resource scripts refer to it there.

## Linux build

### Requirements

- A C compiler. The commands below use GCC.
- SDL3 and Wayland client development files available through `pkg-config`.

Debian or Ubuntu:

```sh
sudo apt install build-essential pkg-config libsdl3-dev libwayland-dev
```

Fedora:

```sh
sudo dnf install gcc pkgconf-pkg-config SDL3-devel wayland-devel
```

Check that both libraries are available:

```sh
pkg-config --modversion sdl3 wayland-client
```

Release builds use a patched SDL3. Apply
`Linux/SDL3-vulkan-native-hdr10.patch` to the SDL source tree:

```sh
git -C SDL apply /path/to/Linux/SDL3-vulkan-native-hdr10.patch
```

The patch leaves the Vulkan swapchain colour space in pass-through mode and
prevents SDL's HDR10 shader from decoding PQ into sRGB when the output is
already a PQ swapchain. A stock SDL3 build runs, but produces incorrect native
PQ patches on Plasma. The Linux release therefore includes `libSDL3.so.0`.

### Patch Companion

Run from the repository root:

```sh
gcc -O2 -std=gnu11 -Wall -Wextra -ILinux $(pkg-config --cflags sdl3 wayland-client) \
    Common/pgen-icc-companion.c Common/pgen-color-management-v1-protocol.c \
    -o PGenPatchCompanion.bin $(pkg-config --libs sdl3 wayland-client) -lm \
    -Wl,-rpath,'$ORIGIN'
```

`Common/pgen-color-management-v1-protocol.c` provides the generated Wayland
colour-management protocol glue and must be included in the link.
Distribute `Linux/PGenPatchCompanion.sh` as `PGenPatchCompanion` beside the
binary and bundled `libSDL3.so.0`. The launcher selects the bundled library;
the binary's `$ORIGIN` runpath provides the same protection for direct launches.

### Profile Loader

```sh
gcc -O2 -std=gnu11 -Wall -Wextra -ICommon $(pkg-config --cflags sdl3) \
    Linux/pgen-profile-loader-linux.c \
    -o PGenProfileLoader $(pkg-config --libs sdl3) -lm
```

These commands have been tested with SDL3 3.4.2 and wayland-client 1.24.0.
Patch Companion links SDL3, wayland-client, and libm. Profile Loader links SDL3
and libm.

At runtime, Profile Loader uses `kscreen-doctor` on KDE Plasma or `colormgr`
from colord when available. Neither is a build dependency. On Plasma it handles
the SDR and HDR profile slots separately through `iccProfilePath` and
`hdrIccProfilePath`.

## Windows cross-build

The Windows programs can be cross-compiled on Linux with MinGW-w64.

Install the compiler and binutils on Debian or Ubuntu:

```sh
sudo apt install gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64
```

Download and unpack the official SDL3 MinGW development package. Do not commit
the archive or extracted directory.

```sh
curl -fLO https://github.com/libsdl-org/SDL/releases/download/release-3.4.14/SDL3-devel-3.4.14-mingw.tar.gz
tar xzf SDL3-devel-3.4.14-mingw.tar.gz
export SDL3=$PWD/SDL3-3.4.14/x86_64-w64-mingw32
```

The build uses headers from `$SDL3/include`, libraries from `$SDL3/lib`, and
the redistributable DLL at `$SDL3/bin/SDL3.dll`.

### Patch Companion

Run from the repository root. Build the resource file from `Windows/` so its
relative icon and manifest paths resolve correctly.

```sh
(cd Windows && x86_64-w64-mingw32-windres pgen-icc-companion.rc \
    -O coff -o ../companion_rc.o)

x86_64-w64-mingw32-gcc -O2 -std=gnu11 -DUNICODE -D_UNICODE \
    -DSDL_MAIN_CALLBACK_STANDARD -I"$SDL3/include" -ILinux \
    Common/pgen-icc-companion.c companion_rc.o \
    -o PGeneratorPlusPatchCompanion.exe -L"$SDL3/lib" \
    -municode -mwindows \
    -lSDL3 -ldxguid -lws2_32 -ld3d11 -ldxgi -lcomctl32 -lmscms -lole32 \
    -luuid -lgdi32 -luser32 -lshell32 -ladvapi32 -lshlwapi -ldwmapi
```

`-DSDL_MAIN_CALLBACK_STANDARD` is required because the source defines
`SDL_MAIN_USE_CALLBACKS`. `-municode` supplies the correct entry point for the
Unicode build. `IID_IDXGISwapChain3` and `IID_IDXGISwapChain4` come from
`-ldxguid`.

Adding `-Wall` currently reports one non-fatal `-Wunused-function` warning in
the shared source.

### Profile Loader

The Windows Profile Loader is a Win32 application and does not use SDL3.

```sh
(cd Windows && x86_64-w64-mingw32-windres pgen-profile-loader.rc \
    -O coff -o ../loader_rc.o)

x86_64-w64-mingw32-gcc -O2 -std=gnu11 -DUNICODE -D_UNICODE \
    Windows/pgen-profile-loader.c loader_rc.o \
    -o PGenProfileLoader.exe \
    -municode -mwindows \
    -lcomctl32 -lcomdlg32 -lshell32 -lmscms -luxtheme -ldwmapi -lsetupapi \
    -lgdi32 -luser32 -ladvapi32 -lole32 -luuid
```

`-luuid` provides `GUID_DEVCLASS_MONITOR`.

Both outputs are 64-bit Windows PE executables. Distribute
`$SDL3/bin/SDL3.dll` beside `PGeneratorPlusPatchCompanion.exe`. Profile Loader
does not require that DLL.

## Windows installer

`Windows/pgen-icc-tools-installer.nsi` is the NSIS installer script. Run
`makensis` from the `Windows/` directory with this staging layout:

- `../icc-companion/windows-x64/` containing
  `PGeneratorPlusPatchCompanion.exe`, `PGenProfileLoader.exe`, `SDL3.dll`,
  `targen.exe`, `colprof.exe`, and `profcheck.exe`
- `../icc-companion/SDL3-LICENSE.txt` and
  `../icc-companion/ArgyllCMS-LICENSE.txt`
- `README.txt` and `PROFILE-LOADER-README.txt` in the working directory
- `../favicon.ico`
- `PGenPatchCompanion.template.conf` in the working directory

The installer stores the configuration template uncompressed. Its `SERVER` and
`TOKEN` values contain fixed-width placeholders. Patch Companion treats
unchanged placeholders as unset and starts discovery and pairing.

## Regenerating headers

Regenerate the checked-in headers only after changing the application artwork
or font rendering:

```sh
python3 Common/make-icon-header.py     # requires Pillow
python3 Linux/make-font-header.py      # requires Pillow and DejaVu fonts
```

`make-icon-header.py` reads the root `favicon.ico` and writes
`Common/pgen-icc-companion-icon.h`.

`make-font-header.py` searches the standard Debian and Fedora locations for
DejaVu TrueType fonts and writes `Linux/pgen-ui-font.h`. Set `PGEN_FONT_DIR` to
use another font directory.

## Licensing

Code in `Common/`, `Windows/`, and `Linux/` is licensed under the GNU GPL. See
`LICENSE`.

Third-party source and binaries are not stored in this repository. Their
licence files are under `licenses/` and must be included with distributed
builds as follows:

| Component | Licence | Distribution requirement |
| --- | --- | --- |
| SDL3 | zlib, `licenses/SDL3-LICENSE.txt` | Include with builds that distribute `SDL3.dll` or `libSDL3`: Patch Companion on both platforms and Linux Profile Loader |
| DejaVu fonts | Bitstream Vera, `licenses/DejaVu-LICENSE.txt` | Include with Linux Profile Loader because `pgen-ui-font.h` contains rendered DejaVu glyphs |
| ArgyllCMS | AGPLv3, `licenses/ArgyllCMS-LICENSE.txt` | Include with packages containing `targen`, `colprof`, or `profcheck`, along with the required source offer; the bundled binaries are built from our fork, vendored at `vendor/ArgyllCMS_ICC4.4` and published at [BigShoots/ArgyllCMS_ICC4.4](https://github.com/BigShoots/ArgyllCMS_ICC4.4) |

`favicon.ico` is the PGenerator+ application artwork.
