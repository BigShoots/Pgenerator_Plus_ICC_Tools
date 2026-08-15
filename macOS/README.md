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
| HDR profiling | **possible via scRGB**, not yet implemented — PQ measured dead, see [HDR](#hdr) |
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

**Possible, and not yet implemented.** An earlier version of this file said
"impossible"; that was measured only on the PQ path and should not have been
stated as a claim about macOS. Retracted.

All measurements 2026-08-15, M1 Pro XDR panel, i1 DisplayPro.

### PQ does not work, with or without metadata

`CAMetalLayer` documents `EDRMetadata = nil` as rendering "without tone
mapping", so that condition was run at two brightness settings:

| target nits | D, slider 50% | E, slider 100% | E/D |
|---|---|---|---|
| 10 | 13.15 | 64.41 | 4.90 |
| 50 | 66.33 | 326.68 | 4.92 |
| 100 | 130.65 | 634.14 | 4.85 |
| 600 | 715.41 | 592.21 | 0.83 |

Up to **392%** apart on nothing but the brightness slider, and non-monotonic at
the top. Omitting the metadata does not help: PQ content is renormalised
against SDR white regardless. Do not use PQ on macOS.

### Extended linear (scRGB) does work

`kCGColorSpaceExtendedLinearSRGB`, `RGBA16Float`, no EDR metadata. 1.0 is SDR
white by definition, so every reading is normalised against the 1.0
measurement:

| value | F normalised (SDR white 37.9 cd/m²) | G normalised (SDR white 631.2) | agreement |
|---|---|---|---|
| 0.125 | 0.127 | 0.129 | 1.5% |
| 0.25 | 0.258 | 0.261 | 1.3% |
| 0.5 | 0.511 | 0.518 | 1.4% |
| 1.0 | 1.000 | 1.000 | — |
| 1.5 | 1.509 | 1.074 | G clipped |
| 2.0 | 2.011 | 0.921 | G clipped |

**The normalised response is linear and agrees to 1.5% across a 17× change in
SDR white.** That is passthrough.

Three further sweeps confirm it behaves like a display rather than merely
tracking:

- **Proportional to 0.3% up to 4× SDR white** (302 cd/m² measured), with no
  ceiling reached. The clipping in G above was that panel's full-field power
  limit at a much higher SDR white, not a limit of the path.
- **Additive.** Measured XYZ(R) + XYZ(G) + XYZ(B) matched XYZ(white) to 0.5% at
  value 1.0 and 1.5% at 0.5 — the assumption an ICC matrix profile rests on.
- **Reproducible to 0.1%.** Two sweeps whose SDR white differed by exactly 2×
  normalised to 0.127 / 0.258 / 0.511 and 0.127 / 0.258 / 0.512.

That last point also settles the small deviation from ideal linearity at low
values: it is identical run to run, so it is a fixed characteristic of the
display, not noise — exactly the sort of thing a profile exists to record.

G's clipping is the panel, not the OS: the claimed headroom of 2.667 × 631 cd/m²
implies 1683 cd/m², but full-field output tops out near 678. XDR panels are
power-limited on full-field white. **Headroom overstates what a full-screen
patch can actually reach**, so a run has to establish the real ceiling by
measurement rather than trusting the reported figure.

### Using it

```bash
PGeneratorPlusPatchCompanion --sdr-white=150
```

`--sdr-white` is this display's SDR white in cd/m², measured with a full white
patch. macOS will not supply it — SDL reports 1.0 on Apple platforms, which is
a ratio rather than a luminance — so HDR is refused until it is given, rather
than guessed at. Patches are then presented as multiples of it.

Two refusals guard the path, and both are deliberate:

- no `--sdr-white`, so there is nothing to convert against
- the display is not granting extended range (headroom 1.0), in which case
  every patch above SDR white would clip and the run would measure a ceiling
  rather than a display

Enable HDR for the display first, and re-measure SDR white whenever the
brightness changes: it moves with the slider, and the conversion moves with it.

### How it is implemented

- `colorspace_for_hdr()` returns `SDL_COLORSPACE_SRGB_LINEAR` on macOS. SDL's
  Metal renderer already supports that, so **no bespoke CAMetalLayer is needed**
  — the earlier argument that PQ required one was correct, and irrelevant, since
  PQ is not the path.
- Each patch is converted by `patch_to_scrgb()`: PQ code → absolute nits via
  the ST 2084 EOTF → scRGB value = nits ÷ SDR white. The texture is float on
  macOS whether or not the run is HDR, since extended linear needs it either
  way.
- SDR white in nits is the one unknown. SDL reports it as 1.0 on Apple
  platforms, which is a ratio, not a luminance. It has to be measured — and the
  meter is already in the loop, so the natural answer is to present scRGB 1.0
  at the start of a run and let PGenerator+ measure it.

  The IORegistry shortcut does not work. `AppleARMBacklight` publishes
  `IODisplayParameters.BrightnessMilliNits`, but measured against three
  different SDR whites it tracked neither that nor the panel peak, and reported
  an identical 381.8 cd/m² on two different Macs. Recorded, not used.

  There may be a better one. Across three brightness settings the reported EDR
  headroom behaved as `min(16, panel_peak ÷ SDR_white)`:

  | SDR white | headroom | product |
  |---|---|---|
  | 37.9 | 16.000 | 607 |
  | 75.8 | 16.000 | 1213 |
  | 149.6 | 11.429 | **1710** |

  The first two sit under a hard cap of 16 so reveal nothing; the third is
  above it, and the product lands on what looks like the panel's peak. If that
  holds, one measurement of SDR white yields `panel_peak`, and thereafter SDR
  white is derivable from headroom alone at any brightness where headroom is
  below 16 — so brightness changes could be tracked without re-measuring. This
  rests on a single informative data point and needs two or three more
  brightness settings before it is worth relying on.
- Refuse, or mark as clipped, any patch whose absolute target exceeds the
  measured full-field ceiling. The ceiling has to be measured; reported
  headroom overstates it badly.

Reproduce with `macOS/tools/run-experiment-2.sh`: `<id> <label>` for PQ,
`--scrgb <id> <label>` for extended linear. Both refuse to report numbers
unless the display is actually granting extended range.

## Monitor-side control (DDC/CI)

Surveyed 2026-08-15 with `macOS/tools/ddc-probe.sh`. **Not usable as a
dependency on macOS**, though the transport does exist.

DDC/CI reaches a monitor's own controls — RGB gain and black level, contrast,
picture preset, brightness — which is the half of calibration PGenerator+
leaves to the operator, and which would let brightness be *pinned* rather than
merely watched for drift.

| display | connection | reading | verdict |
|---|---|---|---|
| Dell U2723QE | USB-C / DP | 65 / 75 / 100 / 100 / 100 | genuinely answers |
| ASUS VE228 | HDMI→DVI | 82 / 82 / 82 / 82 / 82 | not a reading |

Three findings, in order of how much they matter:

1. **m1ddc returns a plausible number instead of failing.** Brightness,
   contrast and all three colour gains reporting the *same* value is the
   signature — no panel ships that way. It appears to be the built-in's
   brightness percentage answering every query. A single reading cannot be
   trusted without a cross-check, which makes this a poor foundation.
2. **HDMI-attached panels are unreachable.** m1ddc addresses USB-C and
   DisplayPort Alt Mode; its own help excludes the built-in HDMI port on M1 and
   entry-level M2 Macs. Note this is a macOS transport limitation, not a DVI
   one — DDC runs over DVI perfectly well.
3. **No public API exists.** The Apple Silicon route is the private
   `IOAVService`, which is present in the IORegistry but is the wrong thing for
   a calibration binary to link.

**The Pi is the right home for this.** It is already connected to the display
over HDMI, so it already owns that I²C channel, and `ddcutil` there is public
and supported. Upstream does not do it today — the only related file is
`usr/lib/scdc_tool.c`, which is HDMI 2.0 scrambling control and unrelated.

Also worth recording: Apple Silicon exposes no raw EDID in the IORegistry, only
an `EDID UUID` carrying vendor, product and a few header bytes. Panel
chromaticities and HDR static metadata are therefore not readable without DDC.

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
| Native HDR patches | yes, DXGI PQ | yes, Wayland PQ | via scRGB, measured viable, unimplemented |
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
