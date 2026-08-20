PGenerator+ ICC Tools for macOS (Apple Silicon)
===============================================

This package contains the Patch Companion, the SDL3 library it uses, and the
ArgyllCMS targen, colprof, and profcheck tools the PGenerator+ offloads chart
generation and profile fits to. Extract the ZIP and run the programs from where they land. Nothing is
installed and nothing is written outside your user account.

Requirements: macOS 14 or newer on Apple Silicon (arm64).

First start
===========

macOS quarantines downloaded programs. If the Companion will not open, either
right-click PGenPatchCompanion in Finder and choose Open once, or clear the
quarantine mark from a Terminal in the extracted folder:

    xattr -dr com.apple.quarantine .

If the executable bit was not preserved by your unarchiver, run
`chmod +x PGenPatchCompanion targen colprof profcheck` once.

Pairing
=======

A copy downloaded from a PGenerator+ arrives already paired with that unit and
needs nothing from you.

A copy downloaded from the GitHub releases page is the same file for everyone,
so it pairs itself the first time it runs:

1. It finds your PGenerator+ by resolving the name pgenerator.local.
2. It shows a six-digit code and waits. The same request and code appear in
   the PGenerator+ WebUI beside the Patch Companion status.
3. Approve it there, once. The companion saves the result and never asks
   again.

If the name cannot be resolved -- more than one PGenerator+ on the network, a
routed network, or mDNS blocked -- give the address explicitly instead, either
as a line reading SERVER=http://<address> in PGenPatchCompanion.conf beside the
executable, or by starting the companion with --server=http://<address>. A
SERVER set that way always wins over discovery.

PGenerator+ Patch Companion
===========================

1. If a PGenPatchCompanion.conf came with this package, keep it beside the
   executable.
2. Run PGenPatchCompanion. It initially opens in a movable, resizable window.
   Use the ICC Profile workspace to switch it live between a resizable window
   and borderless fullscreen output. In fullscreen mode, the WebUI Patch Size
   setting controls centered window and APL patterns.
   Use the white crosshair on the black alignment screen to center the meter.
3. Return to the PGenerator+ WebUI from another screen or device and start the
   ICC profile measurements.
4. Press F11 if you need to override fullscreen locally. Press Escape to exit.

The companion must remain connected for the entire measurement run.
PGenerator+ waits for each patch to be presented before it asks the meter to
read. The alignment target returns whenever profiling finishes, is stopped,
or fails.

HDR on macOS
============

macOS has no application path that carries PQ/BT.2020 code values to the
display the way Windows (DXGI HDR10) and Plasma (Wayland color management)
do. HDR patches are therefore presented through Apple's EDR pipeline: the
Companion decodes each PQ code to light locally and hands macOS linear values
where 1.0 equals the display's current SDR white.

What that means in practice:

* macOS does not publish the physical luminance of SDR white, so the mapping
  assumes 100 cd/m2 for it. The result is a stable, repeatable code-to-light
  mapping rather than an absolute PQ one. That is sufficient for
  characterization -- the meter reads the absolute light -- but keep the
  display brightness FIXED for the whole run, because changing it rescales
  every patch.
* HDR needs EDR headroom. On Apple displays the headroom shrinks as SDR
  brightness rises and reaches zero at full brightness, so lower the
  brightness or select a High Dynamic Range reference mode before starting an
  HDR profile. The Companion reports the reason when macOS offers no
  headroom.
* Patch channel values are presented in the display surface's extended sRGB
  primaries, so a BT.2020 saturation target lands at the sRGB chromaticity.
  Greyscale is unaffected.
* Patches brighter than the available headroom are dimmed by one common
  factor instead of being clipped per channel, so channel ratios survive.
* macOS composites every window through the display's assigned ColorSync
  profile and may apply its own color management on top. The Companion never
  changes that OS state; what the meter measures is the display's final
  output, which is exactly what characterization needs.

Correction modes on macOS
=========================

* system -- macOS's native handling of the assigned ColorSync profile,
  untouched. The patch passes through unchanged.
* none -- the Companion submits the source values unchanged. Note that macOS
  still composites through the assigned profile; the Companion does not (and
  cannot cleanly) disable that.
* clut / matrix -- the Companion evaluates the display's assigned ICC profile
  itself, using the same transform code as the Windows and Linux builds. The
  profile's vcgt tag is not re-applied by the Companion because ColorSync
  already loads it into the display pipe.

Installing finished profiles
============================

PGenProfileLoader installs a finished profile and applies it to a display
through ColorSync. Pick the display, pick the profile, and press Apply: the
profile is installed into ~/Library/ColorSync/Profiles (no administrator
rights are needed) and assigned as the display's profile. Verification
compares the profile WindowServer is actually rendering with against the
file, not just what the profile database recorded, and the loader reapplies
the assignment if macOS drops it after a display reconfiguration.

With Patch Companion connected, the Install & Apply button in the PGenerator+
Profile History downloads the finished ICC and hands it to Profile Loader for
the display showing patches, the same flow as Windows and Linux.

macOS keeps a single ColorSync profile per display, so a profile assigned
here governs SDR and HDR content alike. A profile whose calibration lives
only in a Windows MHC2 tag leaves the display uncalibrated on macOS; build
macOS profiles with VCGT calibration.

Profile build offload
=====================

targen, colprof, and profcheck are bundled so the PGenerator+ can offload its
chart generation and long-running profile fits to this computer. This happens automatically while
the Companion is connected; the tools need no setup.

Licenses for SDL3, the DejaVu fonts, and ArgyllCMS are included alongside
this file.
