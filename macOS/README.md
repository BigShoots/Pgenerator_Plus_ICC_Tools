# PGenerator+ ICC Tools for macOS

Apple Silicon builds of the Patch Companion and Profile Loader, so a Mac's
display can be profiled with a PGenerator+ unit.

The shared Patch Companion source in `Common/` is compiled unchanged apart from
platform guards; everything macOS-specific lives in this directory.

## Status

| | |
|---|---|
| SDR profiling | works, verified end to end against a mock unit |
| Code-value passthrough | **partial** — see below; the display profile still reaches the patches |
| Install & Apply from the WebUI | works |
| HDR (PQ) profiling | **not possible** — macOS tone-maps PQ; measured, see [HDR](#hdr) |
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

### macOS colour-manages the patch window in two stages, and we escape only one

Measured on 2026-08-15 with an X-Rite i1 DisplayPro on an 8-bit ASUS VE228 over
HDMI-to-DVI. Drift across the whole series was 0.0000, so these are stable and
fully reversible.

**Stage 1 — CoreAnimation colour matching. Our layer escapes this.** With a
display profile whose red and green colorants were swapped, a nominal red
measured:

| | x | y |
|---|---|---|
| our layer, colorspace nil | 0.5767 | 0.3898 |
| sRGB-tagged control layer | 0.2893 | 0.6205 |

The control landed on the green primary. Ours did not. `CAMetalLayer` performs
no colour matching while its `colorspace` is nil, and SDL leaves it nil for an
ordinary SDR window, so this part behaves exactly as documented.

**Stage 2 — a further, profile-derived transform. Our layer does NOT escape
this.** Swapping only two bytes of the display profile — the `rXYZ` and `gXYZ`
tag signatures, with every other byte identical — still moved our layer:

| | own profile | swapped | delta |
|---|---|---|---|
| red | 0.6319, 0.3470 @ 24.55 cd/m² | 0.5799, 0.3870 @ 29.94 | 0.0656 |
| white | 0.3110, 0.3310 @ 113.24 cd/m² | 0.2999, 0.3483 @ 122.83 | 0.0205 |

White moving is the informative part: a neutral is invariant under a red/green
colorant swap, since it sums the same three colorants either way. Both colours
moved the same direction — greener and brighter — which is a per-channel drive
change rather than a colorimetric conversion. White rising from 113 to 123 cd/m²
means the panel was not being driven to full beforehand.

A no-op control settles that this is caused by the profile's content and not by
the act of assignment: re-assigning a byte-identical copy moved red by 0.0000
and white by 0.0004.

**What this means for profiling.** What the Companion puts on the panel is not
independent of the assigned display profile. An earlier version of this file
claimed patches "reach the panel as the code values we ask for"; that is too
strong and has been retracted. A measurement made with one profile assigned does
not describe the panel under another, so a profiling run has to control which
profile is active — and record it.

The mechanism is not yet characterised. Reproduce with
`macOS/tools/run-experiment-1.sh`, which has `--vcgt` for the two-byte
comparison and `--noop` for the control.

### The cLUT and matrix correction modes are refused

Those modes apply the active profile's inverse because the compositor is
expected to apply the forward transform afterwards — that is what makes the
pair cancel on Windows and KWin. macOS applies neither, so the inverse alone
would correct once in the wrong direction and produce a plausible, wrong
profile. The Companion refuses them and says why, rather than running them.

Use `system` or `none`. `none` is additionally refused when a non-identity vcgt
is loaded, because vcgt is applied after compositing and reaches the patches
regardless — it is the one OS-side stage an untagged layer cannot escape.

That second claim showed up in the measurement too. Our layer read x 0.6321
under the panel's own profile and x 0.5767 under the permuted one — a real
shift, even though the ICC transform demonstrably was not touching it. The
permuted profile has vcgt stripped, so the GPU transfer table changed between
the two readings. `run-experiment-1.sh --vcgt <id>` isolates this by swapping
the colorants while leaving vcgt alone; with the GPU table held constant an
unmanaged layer should not move at all.

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

Not supported, and now known to be impossible rather than merely unbuilt.

**Measured 2026-08-15**, M1 Pro XDR panel, i1 DisplayPro, PQ codes presented
through a `CAMetalLayer` with `kCGColorSpaceITUR_2100_PQ` and extended dynamic
range granted (live headroom 2.24). Same codes, three conditions:

| target nits | A, slider 50% | B, slider 100% | B/A | C, metadata max 600 |
|---|---|---|---|---|
| 1 | 1.91 | 2.39 | 1.25 | 1.84 |
| 10 | 14.63 | 21.12 | 1.44 | 14.34 |
| 100 | 138.63 | 241.55 | **1.74** | 129.62 |
| 203 | 275.17 | 465.41 | 1.69 | 257.56 |
| 400 | 518.60 | 439.04 | 0.85 | 463.34 |
| 600 | 707.53 | 542.94 | 0.77 | 459.80 |
| 1000 | 559.39 | 572.84 | 1.02 | 532.37 |

Every pass criterion fails:

- **A vs B differ by up to 74%.** This is the decisive one. Nothing changed
  between those runs except the SDR brightness slider. A passthrough cannot
  depend on it; a tone-mapper must, because its map is a function of EDR
  headroom and headroom follows that slider.
- **Non-monotonic.** A 600-nit target measured 708 cd/m², a 1000-nit target
  measured 559. Higher code, less light.
- **Nowhere near the target.** Ratios run from 2.7× at 0.1 nits to 1.3× at 400.
- **The mastering metadata changes the curve**, by up to 35% — so the content
  is being interpreted, not passed through.
- **Neutrality collapses at the top.** At the 1000-nit code, A measured
  x 0.235, y 0.238 against a neutral near 0.31, 0.33.

So an HDR profile built this way would characterise WindowServer's tone mapper
under one particular brightness setting, not the display. The Companion refuses
HDR runs with that explanation rather than producing one.

This is not a gap that more work closes. SDL3's Metal renderer accepts only
`SDL_COLORSPACE_SRGB` and `SDL_COLORSPACE_SRGB_LINEAR`, so PQ already needs a
bespoke `CAMetalLayer` — and the measurement above was taken through exactly
such a layer, configured the way an HDR build would configure it. There is no
`IDXGIOutput6::GetDesc1().ColorSpace` equivalent to escape to.

Reproduce with `macOS/tools/run-experiment-2.sh`, which refuses to report
numbers unless the display is actually granting extended range.

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
| Native HDR (PQ) patches | yes, DXGI | yes, Wayland | **impossible** — macOS tone-maps PQ |
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
