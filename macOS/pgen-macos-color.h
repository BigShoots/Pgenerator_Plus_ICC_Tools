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

/* Point the window's CAMetalLayer at the display's own colour space so
 * WindowServer's match becomes an identity and the patch reaches the panel as
 * the code value we asked for. Without this, SDL leaves the layer tagged sRGB
 * and every patch is silently converted into the display profile.
 *
 * `note` receives a short human-readable description of what was actually
 * established, for the Companion's transform_note field. Returns false when
 * passthrough could not be set up, in which case the Companion must report
 * that honestly rather than claim code-value accuracy it does not have.
 */
bool pgen_macos_set_layer_passthrough(struct SDL_Window *window,
                                      unsigned int sdl_display_id,
                                      char *note, size_t note_size);

/* Bring the patch window forward. SDL_RaiseWindow alone is unreliable on
 * macOS without an explicit application activation. */
void pgen_macos_activate_window(struct SDL_Window *window);

#ifdef __cplusplus
}
#endif

#endif /* PGEN_MACOS_COLOR_H */
