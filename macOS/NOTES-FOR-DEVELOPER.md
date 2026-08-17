# Notes for the developer thread

Measurements taken 2026-08-15 against the v1.4.19 macOS build and a set of
purpose-built probes. Hardware: MacBook Pro M5 (built-in XDR) and an M1 Pro,
ASUS VE228 over HDMI→DVI, Dell U2723QE over USB-C, X-Rite i1 DisplayPro.

Each section below is self-contained — send whichever are useful, in any order.
**Everything here has been measured** except where it says otherwise.

---

## 1. PQ numbers, if you want them for the docs

Your README says absolute PQ placement isn't available on macOS. Agreed, and
here's the supporting data in case it's useful to point at.

PQ codes through a `CAMetalLayer` with `kCGColorSpaceITUR_2100_PQ`, EDR granted
(headroom 2.24), same codes at two SDR brightness settings:

| target nits | slider 50% | slider 100% | ratio |
|---|---|---|---|
| 10 | 14.63 | 21.12 | 1.44 |
| 100 | 138.63 | 241.55 | 1.74 |
| 203 | 275.17 | 465.41 | 1.69 |
| 600 | 707.53 | 542.94 | 0.77 |

Also non-monotonic near peak — a 600-nit target read 708 cd/m², a 1000-nit
target read 559 — and varying the EDR mastering metadata moved the curve by up
to 35%.

Worth noting we also tested `EDRMetadata = nil`, since `CAMetalLayer.h`
documents that as rendering "without tone mapping". It doesn't help: same codes
measured up to **392%** apart between the two brightness settings. So the
renormalisation isn't the metadata.

## 2. The EDR path measures very well

Extended linear, normalised against the 1.0 (SDR white) reading:

| value | SDR white 37.9 | SDR white 631.2 | agreement |
|---|---|---|---|
| 0.125 | 0.127 | 0.129 | 1.5% |
| 0.25 | 0.258 | 0.261 | 1.3% |
| 0.5 | 0.511 | 0.518 | 1.4% |

Three further checks:

- **proportional to 0.3%** up to 4× SDR white (302 cd/m² measured), no ceiling
- **additive**: XYZ(R)+XYZ(G)+XYZ(B) matched XYZ(white) to 0.5% at 1.0 and 1.5%
  at 0.5
- **reproducible to 0.1%** across a 2× change in SDR white

The small positive bias at low values (~2–3%) is identical run to run, so it
looks like a fixed display characteristic rather than noise.

## 3. Reported headroom overstates what a full-field patch can reach

On the M5 at full brightness: headroom 2.667 × SDR white 631 cd/m² implies
1683 cd/m², but full-field white topped out near **678**. A patch above the real
ceiling then measures the same as one at it, which flattens the top of a profile
without any error being raised.

Reproduced on 2026-08-16 in the HDR Video (P3-ST 2084) reference mode with SDR
white measured at 108.4 cd/m²: macOS granted 10.00× (1084 cd/m²) and the panel
delivered **567**. So the overstatement is not a one-off, and its size varies
with the mode — 2.5× here, 1.9× there.

**Correction to an earlier draft of this note**, which attributed the gap to
full-field power limiting. That explanation is wrong. Measured on the same
panel: SDR white is flat within 1% across test-window scales from 0.4 to 2.0,
and TechSpot's review of the same panel family reports *"no major difference
between sustained and peak brightness, so there's no automatic brightness
limiter"*. Whatever produces the gap, it is not ABL.

Possibly worth a line in the README, or a measured cap. Note that a cap derived
from reported headroom would still be wrong by roughly 2× — it has to be
measured.

## 4. Headroom may be a usable proxy for SDR white — speculative

Across three brightness settings, reported headroom behaved as
`min(16, panel_peak ÷ SDR_white)`:

| SDR white | headroom | product |
|---|---|---|
| 37.9 | 16.000 | 607 |
| 75.8 | 16.000 | 1213 |
| 149.6 | 11.429 | **1710** |

The first two are pinned at a cap of 16 and reveal nothing; the third is above
it and the product lands on what looks like the panel's peak. If it holds, one
measurement of SDR white gives `panel_peak`, and thereafter SDR white follows
from headroom alone wherever headroom is below 16 — which would let a brightness
change mid-session be tracked rather than invalidating the run.

**One informative data point, so treat it as a hypothesis.** Two or three more
settings above the cap would confirm or kill it.

## 5. `AppleARMBacklight` is not the SDR white figure

In case it looks tempting: `IODisplayParameters.BrightnessMilliNits` in the
IORegistry reads 381.8 cd/m² and tracked neither measured SDR white (149.6) nor
the implied peak (1710) — and reported the *same* 381.8 on two different Macs.
We recorded it and moved on.

## 6. The package has no Info.plist — question, not a bug report

The macOS release is a flat folder rather than an `.app` bundle, so there's no
`Info.plist` and therefore no `NSLocalNetworkUsageDescription`. On macOS 15+,
outbound LAN access is gated at the socket layer, and `pgenerator.local` +
connecting to a LAN address is exactly what that gate covers.

**We haven't been able to verify this bites**, because a Terminal launch
inherits the terminal's grant and would mask it — testing needs a Finder launch
against a real unit. Flagging it because the failure would present as "the
Companion can't find my PGenerator+", which is a confusing thing to debug.

## 7. Offer: a macOS Profile Loader

Your README notes there's no Profile Loader in the macOS package and Install &
Apply is unavailable. We built one while working on this, forked from
`pgen-profile-loader-linux.c` with the UI kept and the backend replaced:

- installs via `ColorSyncProfileInstall` into `~/Library/ColorSync/Profiles`,
  no privileges needed — the whole `pkexec` layer disappears
- assigns with `ColorSyncDeviceSetCustomProfiles`
- **verifies against WindowServer**, not the profile database: it compares the
  ICC payload `CGDisplayCopyColorSpace` actually returns against the file,
  because the device DB will happily report an assignment the compositor hasn't
  adopted
- self-heals on the Windows guard rails (two consecutive mismatches, max one
  reassociation a minute, never reinstall from the timer), plus an immediate
  re-check on display add/remove/move
- `SDL_Tray` menu-bar item
- Install & Apply wired up: Companion forks it with `--apply-from-companion`
  and a `CGDisplay` UUID, and waits on the Windows-style result file

Also labels the cases macOS can't honour: one ColorSync slot per display, so an
HDR profile also governs SDR; and a Windows profile whose calibration lives only
in MHC2 leaves the display uncalibrated here, which is indistinguishable from a
working one in a file listing.

Happy to send it over in whatever form is easiest.

---

## 8. Correction modes confirmed working — and one small residual

We initially disagreed with your README's "macOS still composites through the
assigned profile" on the strength of our own probe, and it turns out the probe
was measuring the wrong thing (a bare `CAMetalLayer` with `colorspace = nil`,
which is not what SDL presents). Your design is right, measured against your
shipped v1.4.19 build:

With a profile whose red and green colorants were swapped assigned to the
display, asking for red:

| mode | measured | |
|---|---|---|
| `system` | x 0.2888, y 0.6203 | green primary — the profile is applied |
| `matrix` | x 0.5965, y 0.3739 | back to red — the inverse cancels it |

`system` reproduced three times. Two small things you may find useful:

- The matrix recovery is close but not exact — x 0.5965 against ~0.632 for the
  panel's native red. Probably gamut clipping while driving one channel to
  reproduce another under a deliberately absurd profile; noted in case a
  subtler version shows up with real profiles.
- `clut` on an Apple-generated display profile reports "The selected ICC
  correction is not ready", correctly — those profiles are matrix/TRC with no
  B2A0. A wording tweak ("this profile has no cLUT") might save a user some
  confusion, since the current message reads like a transient state.


## 9. The macOS build cannot pair with a current unit — now confirmed on hardware

Verified on our side, worth checking on yours: the macOS Companion reports
`"platform":"macos"` in its pair request (confirmed by running the shipped
binary against a protocol mock), but `PGICCProfile.pm` on the unit validates
the platform against `(windows|linux)` in both the pair-request handler (~:386)
and the poll handler (~:604), and rejects the pairing outright with "Invalid
pairing request".

As of today the PGenerator-Plus repo's main still has the old regexes, so
unless a unit-side update ships alongside the macOS tools, users who download
the DMG will get a pairing failure with no hint why.

The whole fix is widening the two regexes to `(windows|linux|macos)` — we
carry it as a patch (with optional WebUI wording for a macos case: download
asset map, OS sniff, the "Compositor profile handling (KWin)" label) and can
send it over.

**Confirmed against a real unit on 2026-08-17** (unit reporting
`shipped_version 1.4.14.1`), by POSTing to `/api/icc/companion/pair-request`
directly, so the result is the server's and not the Companion's:

```
{"client":"probe","platform":"macos","version":"1.4.20"}
  -> {"status":"error","message":"Invalid pairing request"}

{"client":"probe","platform":"windows","version":"1.4.20"}
  -> {"status":"pending","request":"e7b8b2b5…","code":"276502","expires_in":180}
```

Same request, one field different. The request never reaches the WebUI, so
`pair_requests` in `/api/icc/companion/status` stays empty and the operator has
nothing to approve — there is no failure to see from the unit's side at all.

Until the server-side patch lands, `--platform-compat=windows` is the way
through — but **only for a binary built from this fork.** The released
upstream v1.4.20 DMG does not carry the flag:

```
$ strings -a PGenPatchCompanion | grep platform-compat   # nothing
$ strings -a PGenPatchCompanion | grep -x -E 'macos|windows|linux'
macos
```

`macos` is its only platform literal, so there is nothing for the flag to
select even if it parsed. Unrecognised arguments are ignored silently, so
passing `--platform-compat=windows` to that build looks like it worked and
still fails with "Invalid pairing request" — which is a worse failure than
not having the flag at all, because it costs the user the one workaround they
were told to try. Building from this fork fixed it immediately.

Worth stating in the README where users will find it: the flag is argv-only,
since `pgen_macos_early_init()` reads it from the command line and
`load_config()` only consults the conf file for `SERVER`, `TOKEN` and
`DISPLAY`. Putting it in `PGenPatchCompanion.conf` is the obvious first guess
and it silently does nothing.

---

*Sections 10 and 11 added 2026-08-16 after measuring against an independent
reference (ArgyllCMS driving the same meter directly). Both correct things the
earlier sections had assumed.*

## 10. An untagged `CAMetalLayer` is sRGB, not a passthrough

This is the one we would most want you to check, because it silently affects
every macOS measurement.

**How this relates to section 8.** That section concluded your design is right
and macOS does composite through the assigned profile — which still holds, and
this section is the other half of it rather than a reversal. Section 8 also
said a nil-colorspace layer "is not what SDL presents"; that part was wrong.
SDL does leave it nil for an ordinary SDR window, and we observed exactly that
at runtime. The compositor then treats nil as sRGB, so the transform section 8
demonstrated is real, and its *source* space is sRGB rather than the device.

The SDR path assumed that leaving `layer.colorspace` nil means no colour
matching, so device values reach the panel. The compositor instead treats nil
as **sRGB**, and on a wide-gamut display converts every patch on the way out.

Measured on an Apple XDR (P3), same patches, display on its factory profile,
ArgyllCMS measuring through an identity transform as the reference:

| | untagged layer | ArgyllCMS | sRGB primary |
|---|---|---|---|
| red | 0.6433 / 0.3400 | 0.6733 / 0.3267 | 0.640 / 0.330 |
| green | 0.2971 / 0.6045 | 0.2648 / 0.6921 | 0.300 / 0.600 |
| blue | 0.1493 / 0.0610 | 0.1493 / 0.0609 | 0.150 / 0.060 |

The Companion was sitting on the sRGB primaries — 0.093 away from the display's
native green. **Blue agreed to four decimals, but sRGB and P3 share a blue
primary**, so the one channel that matched was the one that could not disagree.
Checking blue alone would have confirmed the wrong answer, which is roughly how
this survived unnoticed.

What does deliver device values is an identity conversion: tag the layer with
the display's own colour space, so source and destination match and the
transform collapses. That is also why ArgyllCMS is correct on this platform —
its window is colour-managed too, but with the display's own profile assigned
the transform is an identity. After the change, the primaries agree with
ArgyllCMS to four decimals: red 0.6732/0.3268, green 0.2640/0.6926, blue
0.1493/0.0610.

Two consequences worth stating: any ICC built through the unfixed path
characterises sRGB-converted output rather than the display, and the fix makes
the Companion's output depend on which profile is assigned, so reverting to the
display's own profile before profiling becomes a real requirement.

We also had `swapchain_cs` reporting `"device"` throughout, because it was
derived from what the code attempted rather than from what the layer actually
was. Same class of problem as the hardcoded `"scrgb-linear"` fixed earlier.
Worth a general rule: a reported state should be an observation or be labelled
unverified.

## 11. Measure in a reference mode — general modes tone-map

macOS exposes each display's preset table through CoreDisplay. Reading it
(`CoreDisplay_Display_CopyPreset(displayID, index)`) gives the rule directly:

```
[0]  Apple XDR Display (P3-1600 nits)   wp=0.3127,0.329   SDR=600  HDR=1600  toneMapOff=0
[1]  Apple Display (P3-600 nits)        wp=0.3127,0.329   SDR=600  HDR= 600  toneMapOff=0
[2]  HDR Video (P3-ST 2084)             wp=0.3127,0.329   SDR=100  HDR=1000  toneMapOff=1
[3]  HDTV Video (BT.709-BT.1886)        wp=0.3127,0.329   SDR=100  HDR= 100  toneMapOff=1
[9]  Photography (P3-D65)               wp=0.3127,0.329   SDR=160  HDR= 160  toneMapOff=1
[10] Internet & Web (sRGB)              wp=0.3127,0.329   SDR= 80  HDR=  80  toneMapOff=1
```

`PresetHostDisableHDRToneMapping` is 0 in exactly the two general modes and 1
in every reference mode. **Tone mapping is active in the general modes**, which
is where a user who has never touched the preset menu will be.

It shows up in the numbers. Measuring white in the general XDR mode gave
0.266/0.316; switching to Photography (P3-D65) and re-measuring gave
0.3039/0.3324 against a D65 target of 0.3127/0.3290 — from 0.047 off to 0.009
off, with nothing else changed. We had spent a while suspecting the instrument,
True Tone, and Apple's new CMF 2026 before the preset table settled it.

Suggestion: the Companion could read this and refuse, or at least warn, when
asked to profile through an active tone mapper — the same shape as the Linux
build refusing to make an unverifiable HDR claim. The preset dictionary also
carries the white point target, SDR and HDR maxima and gamma, which is enough
to report *what the display is currently configured to be* alongside any
measurement.

One caveat if you go looking: `CoreDisplay_Display_CopyPresetUniqueID` did not
track the active preset for us — it kept returning the first entry after the
preset had actually changed. A luminance measurement caught it. Enumeration
works; identifying the active one through that call did not.

---

*Section 12 added 2026-08-17, from a clean install of the released v1.4.20 DMG
on a Mac that had never run the tools before.*

## 12. Running from the mounted DMG cannot work — Gatekeeper blocks the dylib

A first-time user who downloads the DMG, mounts it and runs `PGenPatchCompanion`
where it sits — which is what the README's instructions read as, since we ship a
bare binary rather than a bundle — gets no window and no error dialog. The
process dies at launch:

```
Library not loaded: @loader_path/libSDL3.0.dylib
Reason: tried: '/Volumes/PGenerator+ ICC Tools/…/libSDL3.0.dylib'
        (code signature not valid for use in process:
         library load disallowed by system policy)
```

`termination: DYLD, Library missing`, `SIGABRT`, before `main`. Both the binary
and `libSDL3.0.dylib` are adhoc-signed with no Team ID, and the disk image
carries `com.apple.quarantine` from the browser. Gatekeeper permits the adhoc
main executable but refuses the adhoc dylib load off a quarantined volume, so
the dependency never resolves. Reproduced on macOS 26.5.2 (25F84), arm64.

This presents to the user as "the app does nothing" or, if they had got as far
as expecting a code, "it won't pair" — the crash log is the only evidence, and
nothing points them at it.

The install is: copy the folder off the image first, then clear quarantine.

```sh
cp -R "/Volumes/PGenerator+ ICC Tools/PGenerator+ ICC Tools" ~/Applications/
chmod -R u+w "$HOME/Applications/PGenerator+ ICC Tools"
xattr -dr com.apple.quarantine "$HOME/Applications/PGenerator+ ICC Tools"
```

The `chmod` is not optional and is easy to miss. `libSDL3.0.dylib` is mode 444
on the image, the copy preserves it, and `xattr -dr` then fails on that one
file while succeeding on every other — leaving the exact file whose quarantine
matters still quarantined, and the failure unchanged. It looks like the fix
didn't work.

Worth fixing at the source rather than in documentation, in rough order of how
much it would help:

- Ship a `.app` bundle and notarize it. Removes this entirely, and gives §6 its
  `Info.plist` at the same time.
- Failing that, make the DMG's window a drag-to-`/Applications` layout, so the
  copy is the obvious gesture rather than an undocumented prerequisite.
- Either way, write the files mode 644 into the image, so a `xattr -dr` on the
  copied folder does what the person running it thinks it did.
- A `README.txt` on the image saying "copy this folder out before running" would
  cost nothing and covers the case where someone runs it in place anyway.

## 13. If you do bundle, `save_config()` will break the signature

Found while acting on the first suggestion above, so it is a prerequisite for
it rather than a separate issue.

`save_config()` writes `PGenPatchCompanion.conf` to `SDL_GetBasePath()` first.
For a `.app` that path is `Contents/Resources`, which is inside the sealed
bundle. The write succeeds, and the next `codesign --verify` fails:

```
PGeneratorPlusPatchCompanion.app: a sealed resource is missing or invalid
```

So the app is correctly signed when shipped, and invalidates its own signature
the moment a user pairs — the one action every first-run user performs. An
adhoc-signed app still launches that way, which is why this is easy to miss,
but it will not survive notarization or a quarantined copy.

`Contents/Resources` is the right home for `colprof`, `profcheck` and the
nested Loader, since `companion_tool_path()` also uses `SDL_GetBasePath()` and
those are read-only at runtime. It is the wrong home for the one file that
gets written.

The fallback is already there and already correct — `save_config()` drops to
`SDL_GetPrefPath()` when the base path cannot be written, which is the
Program Files case the comment describes. Making it fire on macOS took only
denying writes to the directory:

```sh
chmod u-w "PGeneratorPlusPatchCompanion.app/Contents/Resources"
```

Do that after signing; `codesign` seals file contents, not directory modes, so
the signature stays valid across the change and across a pairing run. Verified:
paired, token written to `~/Library/Application Support/PGeneratorPlus/
PatchCompanion/`, seal still valid, and a relaunch reconnected on the saved
token without re-pairing.

Cleaner still would be preferring `SDL_GetPrefPath()` for writes on macOS and
leaving the base path read-only by construction, rather than relying on a
permission bit to force the fallback. Worth deciding before a bundle ships,
because the `chmod` is invisible and nothing in the build enforces it.

---

*Section 14 added 2026-08-17. Feature proposal rather than a defect, and the
only section here arguing for new scope. Measured, not sketched.*

## 14. Closed-loop DDC/CI white point and brightness — worth building

`ddc-probe.sh` already argues this from the read side. We have now run the
write side as a closed loop against a real panel, so here are the numbers.

Dell U2723QE over USB-C, i1Display Pro Plus, patches from the Patch Companion,
every value below measured rather than read back from the monitor:

| step | Y cd/m² | x | y | CCT | Δu′v′ vs D65 |
|---|---|---|---|---|---|
| as found | 154.63 | 0.2954 | 0.3359 | 7403 | 0.0144 |
| brightness to target | 120.97 | 0.2956 | 0.3365 | 7383 | 0.0145 |
| gains R100 G89 B90 | 98.68 | 0.3138 | 0.3293 | 6441 | 0.0007 |
| brightness re-trimmed | 120.39 | 0.3134 | 0.3289 | 6470 | 0.0005 |

From 7403 K to Δu′v′ 0.0005 in six measurement iterations, fully unattended.
Nothing about that needs an operator, and it is the step most likely to be
skipped or done badly by hand.

**Why it belongs before profiling, not instead of it.** Every bit of white
point left uncorrected on the monitor has to be carried by VCGT instead, in the
GPU LUT, where it costs bit depth. Correcting x by 0.017 in the panel's own
gains is free; correcting it in VCGT is not. The profile then describes a
display already close to its target, which is the case its cLUT fits best.

**The design point the measurements settled: this is a loop, not a sequence.**
Trimming gains cost 18% of the light — 120.97 down to 98.68 — because gains are
attenuators and the only headroom is downward once a channel sits at 100. So
brightness had to be re-trimmed afterwards, 46 to 61. Anything that sets
brightness once and then adjusts gains will land low, silently, by roughly the
size of the white point error. Converge on both together, or set gains first
and brightness last.

**Guard the transport, not just the result.** `m1ddc` reported luminance 65 for
this display when the true value was 50, exactly the misaddressing failure
`ddc-probe.sh` documents — it answers for the default display rather than
failing. A DDC readback is therefore not evidence that a write landed on the
intended panel. What settled it was writing two brightness values and measuring
that the panel tracked them (65 → 154.9, 40 → 109.1). Any feature built on this
should verify through the meter it already has, and refuse to proceed if a
commanded change does not show up in a measurement.

Not established here, and worth deciding before shipping:

- Which OSD preset the gains landed in, and whether they persist across a power
  cycle or input change. On many panels writes made in a fixed preset either do
  not stick or silently switch preset — that is a per-model behaviour and needs
  a survey, not an assumption.
- Whether to write black level as well. We left it alone; it interacts with
  contrast and is much easier to get wrong than white.
- The transport on each platform. Shelling out to `m1ddc` was deliberate for a
  probe and is probably wrong for the product; DDC/CI has no public macOS API
  and the Apple Silicon route is the private `IOAVService`.

The conservative version of this feature is worth having on its own: read the
monitor's brightness at the start of a run, and refuse or warn if it changes
before the end. That fixes by prevention the drift the meter probes can
currently only detect after the fact, and needs no write path at all.
