# PGenerator+ ICC Tools for macOS

Apple Silicon builds of the Patch Companion and Profile Loader, so a Mac's
display can be profiled with a PGenerator+ unit.

The shared Patch Companion source in `Common/` is compiled unchanged apart from
platform guards; everything macOS-specific lives in this directory.

## Status

| | |
|---|---|
| SDR profiling | works, verified end to end against a mock unit |
| Install & Apply from the WebUI | works |
| HDR (PQ) profiling | **not supported** — see [HDR](#hdr) |
| Architecture | Apple Silicon (arm64) |
| Signing | ad-hoc only — see [Gatekeeper](#gatekeeper) |

## Build

Needs Command Line Tools and Homebrew. Xcode is not required.

```bash
brew install sdl3 && make -C macOS
```

That produces both bundles in `~/.cache/pgen-icc-tools-macos/dist/`. A copy of
the Loader binary is nested inside the Companion's `Contents/Resources` so
**Install & Apply** works wherever the apps are dragged.

Build output deliberately lives outside the checkout. This repo is in iCloud
Drive, which stamps `com.apple.FinderInfo` and `com.apple.fileprovider`
attributes on everything it manages; `codesign` rejects those as "resource
fork, Finder information, or similar detritus", and `xattr -c` cannot remove
them because the file provider immediately puts them back. A bundle built in
place cannot be signed at all.

`make dist` zips both for release. `make clean` removes everything.

The Homebrew build links SDL3 dynamically and warns that the dylib targets a
newer macOS than the deployment target. That is expected for the development
loop. Release builds should link SDL3 statically, which also removes the whole
`@rpath` and dylib-signing problem:

```bash
cmake -B build -G Ninja -S SDL -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON
```

## Before the Pi will talk to a Mac

A stock PGenerator+ validates the platform a Companion reports against
`(windows|linux)` and **rejects the pairing request outright**, so a macOS
Companion cannot pair at all until the unit is patched.

Apply `pgen-server-macos-platform.patch` to the PGenerator-Plus repo, or to
`/usr/share/PGenerator/` on the unit itself. It widens two regexes and adds a
macOS case to the WebUI's wording and download hint.

Until then, start the Companion with `--platform-compat=linux`. It pairs and
runs correctly; the only cost is that the WebUI describes KWin where it means
ColorSync. The Companion logs a notice whenever compat mode is active, so
nobody spends an hour debugging the wrong label.

## Running it

```bash
open ~/.cache/pgen-icc-tools-macos/dist/PGeneratorPlusPatchCompanion.app
```

It finds the unit by resolving `pgenerator.local`, shows a six-digit pairing
code, and waits for approval in the WebUI. To point it somewhere explicitly:

```bash
PGeneratorPlusPatchCompanion.app/Contents/MacOS/PGeneratorPlusPatchCompanion --server=http://192.0.2.10
```

Useful flags: `--display="<name>"` skips the display picker,
`--platform-compat=linux` as above.

macOS will ask for permission to find devices on the local network the first
time. Denying it leaves the app unable to reach the unit at all.

Turn off **True Tone**, **Night Shift** and **automatic brightness** on the
display being profiled. All three modulate the output and none can be read or
disabled through a public API, so no tool can compensate for them.

## Gatekeeper

The builds are ad-hoc signed, not notarised. Downloaded from GitHub, macOS 15
and later will refuse to open them with "Apple could not verify…" and the old
right-click → Open bypass no longer works.

Open **System Settings → Privacy & Security**, scroll to the blocked app and
click **Open Anyway**, then confirm. Or, from a terminal:

```bash
xattr -dr com.apple.quarantine /Applications/PGeneratorPlusPatchCompanion.app
```

## How macOS differs

Three of these are real limits, not missing work.

### macOS does not colour-manage the patch window

`CAMetalLayer` performs no colour matching while its `colorspace` is nil, and
SDL leaves it nil for an ordinary SDR window. Patches therefore reach the panel
as device code values with nothing converting them, which is what a pattern
generator wants. The Companion re-checks this on every renderer creation, so a
future SDL that starts tagging the layer cannot silently change what is being
measured.

It does mean `system` correction means something different here. On Windows and
KDE it means "the compositor applies the display profile to the patches". On
macOS it means "device code values, plus whatever vcgt is loaded".

### The cLUT and matrix correction modes are refused

Those modes apply the active profile's inverse because the compositor is
expected to apply the forward transform afterwards — that is what makes the
pair cancel on Windows and KWin. macOS applies neither, so the inverse alone
would correct once in the wrong direction and produce a plausible, wrong
profile. The Companion refuses them and says why, rather than running them.

Use `system` or `none`. `none` is additionally refused when a non-identity vcgt
is loaded, because vcgt is applied after compositing and reaches the patches
regardless — it is the one OS-side stage an untagged layer cannot escape.

### One profile slot per display

Windows keeps separate SDR and HDR defaults (`COLORPROFILESUBTYPE` 7 and 8) and
KWin keeps `iccProfilePath` and `hdrIccProfilePath`. macOS keeps one. A profile
applied here governs SDR and HDR content alike, and the Profile Loader labels
HDR profiles accordingly instead of letting the surprise arrive on the desktop.

### MHC2 is inert

A profile PGenerator+ built for Windows carries its calibration in an MHC2 tag
that only Windows consumes. If it also has vcgt, macOS applies that and the
profile is useful. If the calibration lives **only** in MHC2 — PGenerator+'s
"calibration without VCGT" — assigning it on macOS leaves the display
uncalibrated. The two are indistinguishable in a file listing, so the Loader
distinguishes them.

Build macOS profiles as SDR with VCGT.

## HDR

Not supported, and this is a limitation rather than an omission.

SDL3's Metal renderer accepts only `SDL_COLORSPACE_SRGB` and
`SDL_COLORSPACE_SRGB_LINEAR` and fails renderer creation for anything else, so
PQ cannot come through the shared rendering path at all. It would need a
bespoke `CAMetalLayer`, the way Windows uses a bespoke DXGI swapchain.

Whether that would even work is an open question: macOS composites through EDR,
where PQ 1.0 means 100 nits and WindowServer may tone-map, and there is no
equivalent of `IDXGIOutput6::GetDesc1().ColorSpace` to *prove* native HDR is
active. `macOS/tools/pgen-macos-hdr-probe.m` is the experiment that would
settle it; it needs a colorimeter and an HDR display.

Rather than silently profile a tone-mapped conversion, an HDR run fails. That
is the same choice the Linux build makes when it cannot get a native HDR
surface.

## Parity with Windows and KDE

| | Windows | KDE/Linux | macOS |
|---|---|---|---|
| Patch display, exact SDR code values | yes | yes | yes |
| Reads the display's active profile | yes | yes (1.4.2+) | yes |
| Install & Apply from the WebUI | yes | yes | yes |
| Result reported back definitively | yes, result file | inferred from the compositor | yes, result file |
| Tray / menu-bar item | yes | no | yes |
| Continuous verification | yes | yes | yes |
| Self-healing reassociation | yes | no | yes |
| Separate SDR and HDR profile slots | yes | yes | **impossible** — one slot |
| Application-managed cLUT/matrix correction | yes | yes | **impossible** — see above |
| Native HDR (PQ) patches | yes, DXGI | yes, Wayland | not yet — see [HDR](#hdr) |
| Autostart at login | yes | no | not yet |
| Bundled ArgyllCMS `colprof` for build offload | yes | yes | not yet |

The macOS verification is stricter than either sibling: it compares the ICC
payload WindowServer is actually rendering with against the file on disk,
rather than trusting what the profile database recorded. The two can disagree,
and only the first one means the display is really calibrated.

Self-healing follows the Windows guard rails, which are what keep a self-healer
from becoming a fight with the user: act only on a second consecutive mismatch,
at most one reassociation a minute, never reinstall from the timer, and give up
after three failures with an explanation. macOS additionally re-checks
immediately on display add, remove, move and orientation change, because those
are exactly the events after which it drops an assignment.

## What is not here yet

- Login-item autostart (`SMAppService` wants a properly signed, `/Applications`
  bundle, so this lands with notarisation)
- A bundled ArgyllCMS `colprof`, so the build-offload path is unused and the Pi
  fits profiles itself. Homebrew's `argyll-cms` is 3.5.0, an exact match for the
  Pi's version gate, so this is packaging rather than code.
- Notarisation

## Files

| | |
|---|---|
| `pgen-macos-color.{h,m}` | the whole macOS backend, shared by both apps |
| `pgen-profile-loader-macos.c` | forked from the Linux loader; UI kept, backend replaced |
| `Makefile`, `Info.plist.in`, `make-icns.sh` | build and bundle |
| `mock-pgen-server.py` | a stand-in unit, so the client can be exercised with no hardware |
| `pgen-server-macos-platform.patch` | the Pi-side change |
| `tools/pgen-colorsync-probe.m` | read/assign/restore a display profile from the command line |
| `tools/pgen-layer-probe.m` | reports what the patch window's Metal layer is tagged with |
| `tools/make-permuted-profile.py` | builds a deliberately wrong profile, to prove colour management is or is not happening |

### Testing without a PGenerator+

```bash
python3 macOS/mock-pgen-server.py          # interactive: type `help`
```

It speaks the pairing handshake, the poll/ack loop and the Install & Apply
push, and auto-approves pairing. `--no-console` plus the `/mock/*` HTTP routes
make it scriptable:

```bash
curl "http://127.0.0.1:8080/mock/patch?r=128&g=128&b=128&size=50"
curl "http://127.0.0.1:8080/mock/state"     # what the Companion is reporting
curl "http://127.0.0.1:8080/mock/install?path=/path/to/profile.icc"
```
