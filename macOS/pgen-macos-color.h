/* PGenerator+ ICC Tools - macOS platform backend
 *
 * Everything the shared Patch Companion source needs from macOS lives behind
 * this header, so Common/pgen-icc-companion.c stays almost untouched and keeps
 * rebasing cleanly onto a fast-moving upstream. The implementation is
 * Objective-C (pgen-macos-color.m, pgen-macos-display.m); this is the only
 * thing the C side ever sees.
 *
 * The Windows and Linux backends answer the same three questions:
 *   - which profile is the OS currently applying to this display?
 *   - can I stop it applying that profile to my patch window?
 *   - where and how big is my patch window?
 * The names below follow those, not the ColorSync API's own vocabulary.
 */

#ifndef PGEN_MACOS_COLOR_H
#define PGEN_MACOS_COLOR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct SDL_Window;

/* Called from SDL_AppInit before anything else, to read --platform-compat and
 * set the SDL hints that have to be in place before the video subsystem comes
 * up. Safe to call with argc 0. */
void pgen_macos_early_init(int argc, char *argv[]);

/* What this build reports to PGenerator+ as its platform. Normally "macos".
 *
 * A stock unit validates the reported platform against (windows|linux) and
 * rejects a pairing request outright otherwise, so --platform-compat=linux
 * lets the Companion work against a unit that has not taken the server-side
 * patch. "linux" is the better masquerade of the two: the WebUI then labels
 * the control "compositor profile handling", which is at least conceptually
 * right for WindowServer, where "windows" would promise MHC2 semantics that
 * do not exist here. */
const char *pgen_macos_platform_string(void);

/* SDR white in cd/m2, from --sdr-white, or 0 when unknown.
 *
 * This is the one number the extended-linear HDR path needs and macOS will not
 * supply: SDL reports SDR white as 1.0 on Apple platforms, which is a ratio,
 * not a luminance. Measured 2026-08-15, the response is linear in multiples of
 * it to 0.3% up to 4x, so one figure converts every patch. Until it is known,
 * HDR is refused rather than guessed. */
double pgen_macos_sdr_white_nits(void);

/* What the OS currently reports for one display. The counterpart of
 * windows_active_profile() and kwin_output_state(). */
typedef struct {
    bool valid;
    char name[256];          /* human-readable, reported as display_hex */
    char uuid[64];           /* CGDisplay UUID, the stable identity we persist */
    char icc_path[1024];     /* active ColorSync profile, empty when none */
    bool hdr;                /* EDR headroom above 1.0 is available */
    double edr_headroom;     /* NSScreen maximumExtendedDynamicRange... */
    double edr_potential_headroom;
    uint32_t display_id;     /* CGDirectDisplayID */
} PgenMacDisplay;

/* Resolve an SDL display id to its CoreGraphics display and read its current
 * ColorSync state. Returns false when the display cannot be matched. */
bool pgen_macos_display_state(unsigned int sdl_display_id, PgenMacDisplay *out);

/* ---- Profile Loader side -------------------------------------------- *
 * The Companion only ever reads. These are the write half, used by the macOS
 * Profile Loader, and they are what replaces kscreen-doctor and colormgr.
 */

/* Every online display, in CoreGraphics order. Returns how many were written.
 * Unlike the Linux path there is no compositor to interrogate and no colord
 * fallback to arrange - ColorSync is always present. */
int pgen_macos_enumerate_displays(PgenMacDisplay *out, int capacity);

/* Assign a profile to a display, keyed by the UUID from PgenMacDisplay. Pass
 * NULL for icc_path to fall back to the display's factory profile, which is
 * the documented kCFNull path and the macOS equivalent of clearing.
 *
 * macOS has one profile slot per display - no SDR/HDR pair like Windows'
 * COLORPROFILESUBTYPE 7 and 8, or KWin's iccProfilePath and hdrIccProfilePath
 * - so there is nothing to choose between here. */
bool pgen_macos_assign_profile(const char *display_uuid, const char *icc_path,
                               char *message, size_t message_size);

/* Copy a profile into ~/Library/ColorSync/Profiles and register it, in one
 * call, with no privileges required. `installed_path` receives where it landed.
 * The profile is validated first; an unreadable or malformed one is refused
 * here rather than at assignment time. */
bool pgen_macos_install_profile(const char *source_path,
                                char *installed_path, size_t installed_size,
                                char *message, size_t message_size);

/* Whether WindowServer is actually rendering with this profile, as opposed to
 * the device database merely recording it. The two can disagree, and only the
 * first one means the display is really calibrated - so this is what "verified"
 * should be based on. Compares the ICC payload, because a display colour space
 * has no useful name to compare. */
bool pgen_macos_windowserver_uses(const char *display_uuid, const char *icc_path);

/* Open System Settings at the display colour section. */
void pgen_macos_open_display_settings(void);

/* Where a user's own profiles belong: ~/Library/ColorSync/Profiles. */
void pgen_macos_user_profile_directory(char *out, size_t out_size);

/* Read the bytes of the profile the OS is applying to this display. The caller
 * owns the returned buffer and frees it with pgen_macos_free(). Returns NULL
 * when no profile could be read. */
void *pgen_macos_copy_active_profile(unsigned int sdl_display_id, size_t *size);
void pgen_macos_free(void *data);

/* Confirm the patch window is reaching the panel as device code values.
 *
 * This started life as a fix and turned out to be a check. CAMetalLayer's
 * contract is explicit - "the colorspace of the rendered frames. If nil, no
 * colormatching occurs" - and SDL's Metal renderer only sets that property for
 * its scRGB path, leaving it nil for an ordinary SDR window. So macOS hands
 * our pixels to the panel unconverted already, and the job here is to verify
 * that rather than to arrange it.
 *
 * It is still worth checking on every renderer creation. If a future SDL
 * starts tagging the layer, every patch would silently begin going through a
 * conversion, and a calibration tool that did not notice would characterise
 * the wrong thing.
 *
 * `note` receives a short description for the Companion's transform_note.
 * Returns false when the layer is tagged with anything other than the
 * display's own colour space, which is the case the Companion must report
 * rather than quietly claim code-value accuracy it no longer has.
 */
bool pgen_macos_check_layer_passthrough(struct SDL_Window *window,
                                        unsigned int sdl_display_id,
                                        char *note, size_t note_size);

/* Whether a non-identity vcgt is loaded in the GPU transfer table for this
 * display. vcgt is applied after compositing, so unlike the ICC transform it
 * does reach our patches, and it is the one OS-side correction the Companion
 * cannot escape by leaving the layer untagged. `profile_name` receives the
 * profile it came from, for the operator-facing note. */
bool pgen_macos_vcgt_is_active(unsigned int sdl_display_id,
                               char *profile_name, size_t name_size);

/* Bring the patch window forward. SDL_RaiseWindow alone is unreliable on
 * macOS without an explicit application activation. */
void pgen_macos_activate_window(struct SDL_Window *window);

#ifdef __cplusplus
}
#endif

#endif /* PGEN_MACOS_COLOR_H */
