# PGenerator+ ICC Tools

This is where the PGenerator+ ICC tools are **released**. Downloads for every
supported platform are on the [Releases](../../releases/latest) page, and the
source they are built from is in this repository.

- **Patch Companion** — displays the measurement patches on the computer being
  profiled, driven over the network by a PGenerator+ unit.
- **Profile Loader** — installs a finished ICC profile and applies it to a
  display, in SDR and in HDR, then keeps checking that it is still the profile
  the display is actually using.

The PGenerator+ WebUI links straight to the latest release here. The WebUI is
served over plain http, and browsers judge a download by the origin of the page
that started it, so anything the unit served itself would be flagged insecure.
Releases come over https from GitHub instead, which is the whole reason this
repository exists.

## Downloads

| Asset | For | Contains |
| --- | --- | --- |
| `PGeneratorPlus-ICC-Tools-Windows-x64.exe` | Windows 10/11 x64 | Installer: Patch Companion, Profile Loader, ArgyllCMS `colprof`/`profcheck`, Start Menu entries and an uninstaller |
| `PGeneratorPlus-ICC-Tools-Portable-Windows-x64.zip` | Windows 10/11 x64 | The same programs, extracted and run in place, with nothing installed |
| `PGeneratorPlus-ICC-Tools-Linux-x64.zip` | x86-64 Linux, glibc 2.38 or newer | Patch Companion, Profile Loader, ArgyllCMS `colprof`/`profcheck`, bundled SDL3 |

Windows may show a SmartScreen warning, because these builds are not
code-signed.

### Release naming — a contract, not a convention

The WebUI parses these, so they do not change casually:

- **Tags** are `v<major>.<minor>.<patch>`, e.g. `v1.4.0`, and match the Patch
  Companion's own reported version. The WebUI compares the version a connected
  Companion reports against the newest release tag here and says so when the
  Companion is behind.
- **Asset filenames** are exactly the three above, fixed across releases. The
  WebUI opens `releases/latest` — the release *page*, not an asset — so the link
  never needs updating and the download originates from GitHub over https.
  Chrome and Edge judge a download by the origin of the page that started it, so
  a direct asset link from the plain-http WebUI is flagged insecure no matter how
  the asset itself is served.

## Pairing: these downloads are not tied to any one PGenerator+

A release asset is the same file for everybody, so unlike a copy downloaded
from a PGenerator+ unit it cannot arrive knowing which unit it belongs to. It
works it out instead:

1. **Finding the unit.** PGenerator+ answers to the name `pgenerator.local` —
   it runs its own mDNS responder, so this does not depend on the unit's other
   services. The Companion resolves that name at startup.
2. **Getting permission.** It then asks the unit to pair and shows a six-digit
   code on screen. The same request, with the same code, appears in the
   PGenerator+ WebUI next to the Patch Companion status, with Approve and Deny
   buttons. Approving hands the Companion its token, once; it saves it and
   never asks again.

Nothing is handed out to a program that merely asks: a human has to approve
the request in the WebUI, and the code is minted by the unit so that a request
cannot pick a code to impersonate another machine's.

If the name cannot be resolved — several PGenerator+ units on one network,
a routed network, or mDNS blocked — override it either way:

```
PGenPatchCompanion.conf, beside the executable:
    SERVER=http://192.0.2.10

or on the command line:
    PGenPatchCompanion --server=http://192.0.2.10
```

An explicitly configured `SERVER` always wins over discovery — use it where
mDNS is blocked, or where more than one unit shares a network.

## Building from source

Everything below is optional — the releases above are built exactly this way.

### Layout

```
Common/     the single Patch Companion source, its generated icon header and
            the script that regenerates it, and the template config
Windows/    Windows-only source: the Profile Loader, resource scripts,
            manifests and the installer script
Linux/      Linux-only source: the Profile Loader, plus its generated font
            header and the script that regenerates it
licenses/   third-party licences that must travel with the built artifacts
favicon.ico the shared application artwork
```

**The Patch Companion is one source file, compiled for both platforms.**
`Common/pgen-icc-companion.c` builds unmodified on Windows and on Linux, with
the platform differences behind `#ifdef _WIN32`. It is not duplicated into
`Windows/` or `Linux/`: two copies of the same program would drift apart the
first time either one changed, so there is exactly one file and both builds
compile it.

**The Profile Loader is genuinely two separate programs.** The Windows one
(`Windows/pgen-profile-loader.c`) is a Win32 application built on the Windows
colour-management APIs. The Linux one (`Linux/pgen-profile-loader-linux.c`) is
drawn with SDL3 and talks to KWin or colord. They share a workflow, not code,
so unlike the Companion they live apart on purpose.

Two headers are generated and checked in rather than built at compile time:

| File | Regenerated by | Used by |
| --- | --- | --- |
| `Common/pgen-icc-companion-icon.h` | `Common/make-icon-header.py`, from `favicon.ico` | Companion (Linux) and Profile Loader (Linux) |
| `Linux/pgen-ui-font.h` | `Linux/make-font-header.py`, from the DejaVu fonts | Profile Loader (Linux) |

Committing them means **building the tools needs no Pillow and no font
files** — those are only needed to regenerate the headers after changing the
artwork or the type. Windows takes its icon from the resource script instead,
which is why `Windows/pgen-icc-companion.rc` and `Windows/pgen-profile-loader.rc`
both point at `../favicon.ico`, and why `make-icon-header.py` reads the same
file from `Common/../favicon.ico`. Keep `favicon.ico` at the repository root.

### Prerequisites

**Linux (native)**

- A C compiler (these commands were verified with gcc).
- SDL3 and Wayland client development files, discoverable through `pkg-config`.
  The Companion binds the Wayland colour-management protocol directly, so
  `wayland-client` is a build dependency alongside SDL3:

  ```sh
  sudo apt install build-essential pkg-config libsdl3-dev libwayland-dev   # Debian/Ubuntu
  sudo dnf install gcc pkgconf-pkg-config SDL3-devel wayland-devel         # Fedora
  ```

  Confirm both resolve before building:

  ```sh
  pkg-config --modversion sdl3 wayland-client
  ```

- For a binary that matches the shipped one, a **patched** SDL3 rather than the
  distribution package. `Linux/SDL3-vulkan-native-hdr10.patch` applies to SDL's
  Vulkan renderer and does two things the stock library does not: it leaves the
  swapchain colour space as pass-through so the Companion's own colour-management
  surface is the only HDR description attached, and it stops the HDR10 shader
  decoding PQ into sRGB when the output is already a PQ swapchain. Building
  against stock SDL3 compiles and runs, but native PQ patches on Plasma are
  wrong — which is why the release archive bundles `libSDL3.so.0` and the
  Companion is documented as requiring the bundled library.

  ```sh
  git -C SDL apply /path/to/Linux/SDL3-vulkan-native-hdr10.patch
  ```

**Windows (cross-compiled from Linux)**

- MinGW-w64:

  ```sh
  sudo apt install gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64   # Debian/Ubuntu
  ```

- The official SDL3 **MinGW devel** package (system SDL3 is not usable for a
  mingw cross-build). Fetch and unpack it — do not commit the tarball or the
  extracted tree:

  ```sh
  curl -fLO https://github.com/libsdl-org/SDL/releases/download/release-3.4.14/SDL3-devel-3.4.14-mingw.tar.gz
  tar xzf SDL3-devel-3.4.14-mingw.tar.gz
  export SDL3=$PWD/SDL3-3.4.14/x86_64-w64-mingw32
  ```

  `$SDL3/include` and `$SDL3/lib` are what the commands below use;
  `$SDL3/bin/SDL3.dll` is what you ship beside the Companion executable.

### Building on Linux

Run these from the repository root.

**Patch Companion** — `pgen-color-management-v1-protocol.c` is the generated
Wayland protocol glue for the colour-management interface the Companion binds,
and its client header is beside it in `Common/`, so it needs no extra include
path. Leaving the protocol source out fails the link on `wp_color_manager_v1`:

```sh
gcc -O2 -std=gnu11 -Wall -Wextra $(pkg-config --cflags sdl3 wayland-client) \
    Common/pgen-icc-companion.c Common/pgen-color-management-v1-protocol.c \
    -o PGenPatchCompanion $(pkg-config --libs sdl3 wayland-client) -lm
```

**Profile Loader** — `-ICommon` is what lets it find
`pgen-icc-companion-icon.h`; `pgen-ui-font.h` is beside the source file and
needs no extra include path:

```sh
gcc -O2 -std=gnu11 -Wall -Wextra -ICommon $(pkg-config --cflags sdl3) \
    Linux/pgen-profile-loader-linux.c \
    -o PGenProfileLoader $(pkg-config --libs sdl3) -lm
```

Both commands were run against SDL3 3.4.2 and wayland-client 1.24.0 and
produced a clean build with no warnings. The Companion links SDL3,
wayland-client and libm; the Profile Loader links only SDL3 and libm. The
Profile Loader additionally *runs* `kscreen-doctor` (part of KDE Plasma) or
`colormgr` (part of colord) if either is present at run time; neither is a build
dependency. On Plasma it reads and writes the SDR and HDR profile slots
separately (`iccProfilePath` / `hdrIccProfilePath`), because an HDR output
otherwise reports no profile even when its HDR slot is populated.

### Building for Windows

These are the exact commands that were run and verified, cross-compiling on
Linux with MinGW-w64. Run them from the repository root, with `$SDL3` set as
above.

**Patch Companion** — compile the resource script first, with `Windows/` as
the working directory so its `../favicon.ico` and `.manifest` references
resolve, then compile and link the source against it:

```sh
(cd Windows && x86_64-w64-mingw32-windres pgen-icc-companion.rc \
    -O coff -o ../companion_rc.o)

x86_64-w64-mingw32-gcc -O2 -std=gnu11 -DUNICODE -D_UNICODE \
    -DSDL_MAIN_CALLBACK_STANDARD -I"$SDL3/include" \
    Common/pgen-icc-companion.c companion_rc.o \
    -o PGeneratorPlusPatchCompanion.exe -L"$SDL3/lib" \
    -municode -mwindows \
    -lSDL3 -ldxguid -lws2_32 -ld3d11 -ldxgi -lcomctl32 -lmscms -lole32 \
    -luuid -lgdi32 -luser32 -lshell32 -ladvapi32 -lshlwapi -ldwmapi
```

`-DSDL_MAIN_CALLBACK_STANDARD` is required: the source sets
`SDL_MAIN_USE_CALLBACKS`, and without this define the link fails with an
undefined reference to `WinMain`. `-municode` is required because `-DUNICODE`
makes the SDL entry-point shim emit `wWinMain`. `IID_IDXGISwapChain3`/`4` need
`-ldxguid`, not `-luuid`. Adding `-Wall` produces one harmless
`-Wunused-function` note; it is not fatal and was left alone rather than
edited into the shared source.

**Profile Loader** — no SDL3, it is a plain Win32 application:

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

`-luuid` provides `GUID_DEVCLASS_MONITOR`; without it the link fails with an
undefined reference to that symbol.

Both `.exe` files were confirmed with `file` to be PE32+ executables for
64-bit Windows. Ship `$SDL3/bin/SDL3.dll` beside
`PGeneratorPlusPatchCompanion.exe`; the Profile Loader needs no DLL.

### Installer

`Windows/pgen-icc-tools-installer.nsi` is the NSIS script behind the released
installer. It is built with `makensis` and, as written, expects to be invoked
from the `Windows/` directory with a staging tree beside this repository:

- `..\icc-companion\windows-x64\` holding `PGeneratorPlusPatchCompanion.exe`,
  `PGenProfileLoader.exe`, `SDL3.dll`, `colprof.exe` and `profcheck.exe`
- `..\icc-companion\SDL3-LICENSE.txt` and `..\icc-companion\ArgyllCMS-LICENSE.txt`
  — note the path: the script reads them from that staging directory, not from
  this repository's `licenses/`
- `README.txt` and `PROFILE-LOADER-README.txt` in the working directory, the
  end-user notes installed alongside the programs
- `..\favicon.ico` for the installer and uninstaller icon, and
  `PGenPatchCompanion.template.conf` for the pairing config it stores
  uncompressed

That last file ships with its `SERVER`/`TOKEN` slots holding fixed-width
placeholder text. The Companion recognises the untouched placeholders as "no
address, no token" and falls through to discovery and approval, which is how a
release download configures itself with nothing filled in ahead of time.

### Regenerating the generated headers

Only needed after changing `favicon.ico` or the font rendering; never needed
to build the tools, since both headers are already committed.

```sh
python3 Common/make-icon-header.py     # requires Pillow
python3 Linux/make-font-header.py      # requires Pillow and the DejaVu fonts
```

`make-icon-header.py` reads `favicon.ico` at the repository root and rewrites
`Common/pgen-icc-companion-icon.h`. `make-font-header.py` reads the DejaVu
TrueType fonts (checked at the usual Debian/Fedora font paths, overridable
with `PGEN_FONT_DIR`) and rewrites `Linux/pgen-ui-font.h`. Both reproduce the
committed headers byte for byte from the committed inputs.

## Licensing

The code in `Common/`, `Windows/` and `Linux/` is licensed under the GNU GPL;
see `LICENSE`.

Third-party components are **not** included here as source or binaries — only
their licences are, in `licenses/`, because they must travel with anything you
build and distribute from this source:

| Component | Licence | Must travel with |
| --- | --- | --- |
| SDL3 | zlib (`licenses/SDL3-LICENSE.txt`) | Any build that links `SDL3.dll`/`libSDL3` — the Patch Companion on both platforms, and the Linux Profile Loader. |
| DejaVu fonts | Bitstream Vera licence (`licenses/DejaVu-LICENSE.txt`) | The Linux Profile Loader, whose `pgen-ui-font.h` contains glyph bitmaps rendered from these fonts. No font file is redistributed, only the rendered glyphs. |
| ArgyllCMS | AGPLv3 (`licenses/ArgyllCMS-LICENSE.txt`) | Any package bundling the ArgyllCMS `colprof`/`profcheck` binaries, as every release here does. Those binaries are not part of this repository. If you distribute them yourself, this licence and a source offer must go with them; source is at argyllcms.com. |

`favicon.ico` is the PGenerator+ application artwork.
