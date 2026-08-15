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
