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


## 9. The v1.4.19 macOS build may not be able to pair with a current unit

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

We haven't been able to test against a real unit yet, so if your units already
have this server-side, ignore this section entirely.

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
