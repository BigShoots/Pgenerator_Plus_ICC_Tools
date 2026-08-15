/* PGenerator+ ICC Tools - macOS platform backend.
 *
 * Everything Common/pgen-icc-companion.c needs from macOS. The C side calls
 * only what pgen-macos-color.h declares, so the shared source keeps rebasing
 * onto upstream with a handful of guard-line changes.
 *
 * The Windows backend answers "which profile is the OS applying, and how do I
 * stop it applying that to my patch window". On macOS only the first half is a
 * question: CAMetalLayer performs no colour matching while its colorspace is
 * nil, and SDL leaves it nil for an ordinary SDR window, so patches already
 * reach the panel as device code values. What is left is reading the profile
 * accurately, identifying the display stably, and being honest about the one
 * OS-side stage that does still reach the patches - vcgt in the GPU table.
 */

#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>

#include <SDL3/SDL.h>
#include <string.h>

#include "pgen-macos-color.h"

/* ------------------------------------------------------------------ *
 * Platform string and early init
 * ------------------------------------------------------------------ */

static char g_platform[16] = "macos";
static double g_sdr_white_nits = 0.0;

void pgen_macos_early_init(int argc, char *argv[])
{
    for (int index = 1; index < argc; index++) {
        const char *value = NULL;
        if (!strncmp(argv[index], "--platform-compat=", 18))
            value = argv[index] + 18;
        else if (!strcmp(argv[index], "--platform-compat") && index + 1 < argc)
            value = argv[++index];
        if (!value) continue;

        if (!strcmp(value, "linux") || !strcmp(value, "windows") ||
            !strcmp(value, "macos")) {
            snprintf(g_platform, sizeof(g_platform), "%s", value);
            if (strcmp(value, "macos"))
                SDL_Log("macOS: reporting platform \"%s\" for compatibility with a "
                        "PGenerator+ that predates macOS support. The WebUI's "
                        "wording will describe that platform, not this one.", value);
        } else {
            SDL_Log("macOS: ignoring --platform-compat=%s (expected linux, "
                    "windows or macos)", value);
        }
    }

    for (int index = 1; index < argc; index++) {
        const char *value = NULL;
        if (!strncmp(argv[index], "--sdr-white=", 12)) value = argv[index] + 12;
        else if (!strcmp(argv[index], "--sdr-white") && index + 1 < argc)
            value = argv[++index];
        if (!value) continue;
        g_sdr_white_nits = atof(value);
        if (g_sdr_white_nits > 0.0)
            SDL_Log("macOS: SDR white taken as %.1f cd/m2; HDR patches will be "
                    "presented as multiples of it", g_sdr_white_nits);
        else
            SDL_Log("macOS: ignoring --sdr-white=%s", value);
    }

    /* Both hints must be set before the video subsystem starts.
     *
     * Spaces-based fullscreen is SDL's default on macOS and is wrong for a
     * patch generator: it animates into a new Space over about 0.7s, hides the
     * menu bar asynchronously, and lets Mission Control move the window to
     * another display mid-series. With Spaces off, SDL resizes to the display
     * bounds and hides the menu bar synchronously. */
    SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES, "0");
    SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY, "0");
}

const char *pgen_macos_platform_string(void)
{
    return g_platform;
}

double pgen_macos_sdr_white_nits(void)
{
    return g_sdr_white_nits;
}

/* ------------------------------------------------------------------ *
 * Display identity
 * ------------------------------------------------------------------ */

/* SDL exposes no CGDirectDisplayID property, so the mapping is built here.
 * Both sides use top-left-origin global point coordinates with the main
 * display at the origin, so matching bounds is exact rather than a heuristic;
 * the name is only a tiebreak for the pathological identical-geometry case. */
static CGDirectDisplayID display_id_for_sdl_display(SDL_DisplayID sdl_display)
{
    SDL_Rect bounds;
    CGDirectDisplayID displays[16];
    uint32_t count = 0;

    if (!sdl_display || !SDL_GetDisplayBounds(sdl_display, &bounds)) return 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) return 0;

    const char *wanted = SDL_GetDisplayName(sdl_display);
    CGDirectDisplayID fallback = 0;

    for (uint32_t index = 0; index < count; index++) {
        CGRect frame = CGDisplayBounds(displays[index]);
        if ((int)frame.origin.x != bounds.x || (int)frame.origin.y != bounds.y ||
            (int)frame.size.width != bounds.w || (int)frame.size.height != bounds.h)
            continue;
        if (!fallback) fallback = displays[index];

        if (wanted) {
            for (NSScreen *screen in NSScreen.screens) {
                NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
                if (number.unsignedIntValue != displays[index]) continue;
                if (!strcmp(screen.localizedName.UTF8String, wanted))
                    return displays[index];
            }
        }
    }
    return fallback;
}

/* Authoritative once a window exists: the display the patch is actually on,
 * which is not necessarily the one that was picked at startup. */
static CGDirectDisplayID display_id_for_window(struct SDL_Window *window)
{
    if (!window) return 0;
    NSWindow *nswindow = (__bridge NSWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties((SDL_Window *)window),
        SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    NSNumber *number = nswindow.screen.deviceDescription[@"NSScreenNumber"];
    return (CGDirectDisplayID)number.unsignedIntValue;
}

/* ------------------------------------------------------------------ *
 * The active ColorSync profile
 * ------------------------------------------------------------------ */

/* Custom assignments win over factory ones, which is the precedence the
 * Displays pane shows. Returns nil when the display has no registered profile
 * at all - which happens on panels whose effective profile WindowServer
 * synthesises, so callers must have a fallback. */
static NSURL *registered_profile_url(CGDirectDisplayID display)
{
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return nil;
    NSDictionary *info = CFBridgingRelease(
        ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuid));
    CFRelease(uuid);
    if (!info) return nil;

    for (NSString *bucket in @[(__bridge NSString *)kColorSyncCustomProfiles,
                               (__bridge NSString *)kColorSyncFactoryProfiles]) {
        NSDictionary *profiles = info[bucket];
        if (![profiles isKindOfClass:NSDictionary.class] || profiles.count == 0) continue;

        NSString *defaultKey = (__bridge NSString *)kColorSyncDeviceDefaultProfileID;
        id entry = profiles[profiles[defaultKey] ?: @""];
        if (!entry) {
            /* The header notes the default key is optional when there is only
             * one profile, so take whatever single entry is present. */
            for (id key in profiles) {
                if ([key isEqual:defaultKey]) continue;
                entry = profiles[key];
                break;
            }
        }
        NSURL *url = nil;
        if ([entry isKindOfClass:NSDictionary.class])
            url = entry[(__bridge NSString *)kColorSyncDeviceProfileURL];
        else if ([entry isKindOfClass:NSURL.class])
            url = entry;
        if ([url isKindOfClass:NSURL.class]) return url;
    }
    return nil;
}

bool pgen_macos_display_state(unsigned int sdl_display_id, PgenMacDisplay *out)
{
    if (!out) return false;
    memset(out, 0, sizeof(*out));

    @autoreleasepool {
        CGDirectDisplayID display =
            display_id_for_sdl_display((SDL_DisplayID)sdl_display_id);
        if (!display) return false;
        out->display_id = display;

        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
        if (uuid) {
            NSString *text = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
            snprintf(out->uuid, sizeof(out->uuid), "%s", text.UTF8String);
            CFRelease(uuid);
        }

        for (NSScreen *screen in NSScreen.screens) {
            NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
            if (number.unsignedIntValue != display) continue;
            snprintf(out->name, sizeof(out->name), "%s",
                     screen.localizedName.UTF8String);
            out->edr_headroom =
                screen.maximumExtendedDynamicRangeColorComponentValue;
            out->edr_potential_headroom =
                screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
            break;
        }
        /* Headroom above 1.0 means the panel can present EDR content. It is
         * NOT the same claim as Windows' "the output is in HDR10 PQ mode",
         * and the Companion must not report it as though it were. */
        out->hdr = out->edr_potential_headroom > 1.0;

        NSURL *url = registered_profile_url(display);
        if (url) snprintf(out->icc_path, sizeof(out->icc_path), "%s",
                          url.path.UTF8String);

        out->valid = true;
        return true;
    }
}

void *pgen_macos_copy_active_profile(unsigned int sdl_display_id, size_t *size)
{
    if (size) *size = 0;
    @autoreleasepool {
        CGDirectDisplayID display =
            display_id_for_sdl_display((SDL_DisplayID)sdl_display_id);
        if (!display) return NULL;

        /* Prefer WindowServer's own view over the device database. On panels
         * driven in a reference mode the effective profile is synthesised and
         * has no on-disk URL, while the device database still lists a stale
         * factory entry - reading the file would characterise the wrong
         * thing. */
        CGColorSpaceRef space = CGDisplayCopyColorSpace(display);
        if (!space) return NULL;
        CFDataRef icc = CGColorSpaceCopyICCData(space);
        CGColorSpaceRelease(space);
        if (!icc) return NULL;

        CFIndex length = CFDataGetLength(icc);
        void *copy = length > 0 ? malloc((size_t)length) : NULL;
        if (copy) {
            memcpy(copy, CFDataGetBytePtr(icc), (size_t)length);
            if (size) *size = (size_t)length;
        }
        CFRelease(icc);
        return copy;
    }
}

void pgen_macos_free(void *data)
{
    free(data);
}

/* ------------------------------------------------------------------ *
 * Profile Loader side: enumerate, install, assign, verify
 * ------------------------------------------------------------------ */

/* An FNV-1a of the ICC payload. Identity only - a display colour space has no
 * useful name to compare, so this is how "is WindowServer using that file"
 * gets answered. */
static uint32_t icc_digest(const uint8_t *bytes, size_t length)
{
    uint32_t sum = 2166136261u;
    for (size_t index = 0; index < length; index++) {
        sum ^= bytes[index];
        sum *= 16777619u;
    }
    return sum;
}

static CGDirectDisplayID display_id_for_uuid(const char *text)
{
    if (!text || !text[0]) return 0;
    CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!string) return 0;
    CFUUIDRef uuid = CFUUIDCreateFromString(NULL, string);
    CFRelease(string);
    if (!uuid) return 0;
    CGDirectDisplayID display = CGDisplayGetDisplayIDFromUUID(uuid);
    CFRelease(uuid);
    return display;
}

static void fill_display_entry(CGDirectDisplayID display, PgenMacDisplay *out)
{
    memset(out, 0, sizeof(*out));
    out->display_id = display;

    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (uuid) {
        NSString *text = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
        snprintf(out->uuid, sizeof(out->uuid), "%s", text.UTF8String);
        CFRelease(uuid);
    }
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue != display) continue;
        snprintf(out->name, sizeof(out->name), "%s", screen.localizedName.UTF8String);
        out->edr_headroom = screen.maximumExtendedDynamicRangeColorComponentValue;
        out->edr_potential_headroom =
            screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
        break;
    }
    if (!out->name[0]) snprintf(out->name, sizeof(out->name), "Display %u", display);
    out->hdr = out->edr_potential_headroom > 1.0;

    NSURL *url = registered_profile_url(display);
    if (url) snprintf(out->icc_path, sizeof(out->icc_path), "%s", url.path.UTF8String);
    out->valid = true;
}

int pgen_macos_enumerate_displays(PgenMacDisplay *out, int capacity)
{
    if (!out || capacity <= 0) return 0;
    @autoreleasepool {
        CGDirectDisplayID displays[32];
        uint32_t count = 0;
        if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return 0;
        int written = 0;
        for (uint32_t index = 0; index < count && written < capacity; index++) {
            /* Skip a display that is only mirroring another - it has no
             * independent profile slot to assign. */
            if (CGDisplayIsInMirrorSet(displays[index]) &&
                CGDisplayMirrorsDisplay(displays[index]) != kCGNullDirectDisplay)
                continue;
            fill_display_entry(displays[index], &out[written++]);
        }
        return written;
    }
}

void pgen_macos_user_profile_directory(char *out, size_t out_size)
{
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *library = paths.firstObject ?: NSHomeDirectory();
        NSString *directory = [library stringByAppendingPathComponent:@"ColorSync/Profiles"];
        snprintf(out, out_size, "%s", directory.UTF8String);
    }
}

bool pgen_macos_install_profile(const char *source_path,
                                char *installed_path, size_t installed_size,
                                char *message, size_t message_size)
{
    if (installed_path && installed_size) installed_path[0] = '\0';
    if (message && message_size) message[0] = '\0';
    if (!source_path || !source_path[0]) return false;

    @autoreleasepool {
        NSURL *source = [NSURL fileURLWithPath:@(source_path)];
        CFErrorRef error = NULL;
        ColorSyncProfileRef profile =
            ColorSyncProfileCreateWithURL((__bridge CFURLRef)source, &error);
        if (!profile) {
            if (message)
                snprintf(message, message_size, "%s is not a readable ICC profile: %s",
                         source.lastPathComponent.UTF8String,
                         [(__bridge NSError *)error localizedDescription].UTF8String
                             ?: "no detail reported");
            return false;
        }
        /* Refuse a malformed profile here rather than at assignment, where the
         * failure would look like a ColorSync problem instead of a bad file. */
        CFErrorRef problems = NULL, warnings = NULL;
        if (!ColorSyncProfileVerify(profile, &problems, &warnings)) {
            if (message)
                snprintf(message, message_size, "%s failed ColorSync validation: %s",
                         source.lastPathComponent.UTF8String,
                         [(__bridge NSError *)problems localizedDescription].UTF8String
                             ?: "no detail reported");
            if (problems) CFRelease(problems);
            if (warnings) CFRelease(warnings);
            CFRelease(profile);
            return false;
        }
        if (problems) CFRelease(problems);
        if (warnings) CFRelease(warnings);

        /* User domain: no privileges, unlike the Linux build's pkexec step for
         * /usr/share/color/icc. ColorSyncProfileInstall both copies the file
         * into ~/Library/ColorSync/Profiles and registers it. */
        CFErrorRef install_error = NULL;
        /* subpath is the name the profile takes inside the domain's Profiles
         * directory, and it is annotated non-null, so pass the source filename
         * rather than letting ColorSync choose. */
        bool ok = ColorSyncProfileInstall(profile,
                                          kColorSyncProfileUserDomain,
                                          (__bridge CFStringRef)source.lastPathComponent,
                                          &install_error);
        if (!ok && message)
            snprintf(message, message_size, "Could not install %s: %s",
                     source.lastPathComponent.UTF8String,
                     [(__bridge NSError *)install_error localizedDescription].UTF8String
                         ?: "no detail reported");
        if (ok && installed_path) {
            CFURLRef url = ColorSyncProfileGetURL(profile, NULL);
            NSString *path = url ? ((__bridge NSURL *)url).path : nil;
            if (path) snprintf(installed_path, installed_size, "%s", path.UTF8String);
            else {
                char directory[1024];
                pgen_macos_user_profile_directory(directory, sizeof(directory));
                snprintf(installed_path, installed_size, "%s/%s", directory,
                         source.lastPathComponent.UTF8String);
            }
        }
        CFRelease(profile);
        return ok;
    }
}

bool pgen_macos_assign_profile(const char *display_uuid, const char *icc_path,
                               char *message, size_t message_size)
{
    if (message && message_size) message[0] = '\0';

    @autoreleasepool {
        CGDirectDisplayID display = display_id_for_uuid(display_uuid);
        if (!display) {
            if (message) snprintf(message, message_size,
                                  "That display is no longer attached.");
            return false;
        }
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
        if (!uuid) {
            if (message) snprintf(message, message_size,
                                  "macOS did not report a stable identifier for "
                                  "that display.");
            return false;
        }
        /* The flat shape SetCustomProfiles documents: ProfileID -> CFURLRef,
         * with kCFNull to drop back to the factory profile. This is NOT the
         * nested dictionary that device *registration* takes. */
        NSURL *url = (icc_path && icc_path[0])
            ? [NSURL fileURLWithPath:@(icc_path)] : nil;
        NSDictionary *info = @{
            (__bridge NSString *)kColorSyncDeviceDefaultProfileID:
                url ? (id)url : (id)[NSNull null],
        };
        bool ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid,
                                                   (__bridge CFDictionaryRef)info);
        CFRelease(uuid);
        if (!ok && message)
            snprintf(message, message_size,
                     "ColorSync refused the assignment for %s.",
                     display_uuid ? display_uuid : "that display");
        return ok;
    }
}

bool pgen_macos_windowserver_uses(const char *display_uuid, const char *icc_path)
{
    if (!icc_path || !icc_path[0]) return false;

    @autoreleasepool {
        CGDirectDisplayID display = display_id_for_uuid(display_uuid);
        if (!display) return false;

        NSData *wanted = [NSData dataWithContentsOfFile:@(icc_path)];
        if (!wanted) return false;

        CGColorSpaceRef space = CGDisplayCopyColorSpace(display);
        if (!space) return false;
        CFDataRef live = CGColorSpaceCopyICCData(space);
        CGColorSpaceRelease(space);
        if (!live) return false;

        bool same = CFDataGetLength(live) == (CFIndex)wanted.length &&
                    icc_digest(CFDataGetBytePtr(live), (size_t)CFDataGetLength(live)) ==
                    icc_digest(wanted.bytes, wanted.length);
        CFRelease(live);
        return same;
    }
}

void pgen_macos_open_display_settings(void)
{
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.Displays-Settings.extension"];
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

/* ------------------------------------------------------------------ *
 * vcgt
 * ------------------------------------------------------------------ */

/* Read the display's current transfer table and decide whether it is doing
 * anything. Asking CoreGraphics rather than parsing the profile's vcgt tag is
 * deliberate: what matters is the table actually loaded in the GPU, which is
 * what reaches the patches, not what some profile on disk asks for. */
bool pgen_macos_vcgt_is_active(unsigned int sdl_display_id,
                               char *profile_name, size_t name_size)
{
    if (profile_name && name_size) profile_name[0] = '\0';

    @autoreleasepool {
        CGDirectDisplayID display =
            display_id_for_sdl_display((SDL_DisplayID)sdl_display_id);
        if (!display) return false;

        uint32_t capacity = CGDisplayGammaTableCapacity(display);
        if (capacity == 0 || capacity > 4096) return false;

        CGGammaValue *red = calloc(capacity, sizeof(CGGammaValue));
        CGGammaValue *green = calloc(capacity, sizeof(CGGammaValue));
        CGGammaValue *blue = calloc(capacity, sizeof(CGGammaValue));
        uint32_t count = 0;
        bool active = false;

        if (red && green && blue &&
            CGGetDisplayTransferByTable(display, capacity, red, green, blue,
                                        &count) == kCGErrorSuccess && count > 1) {
            /* Identity is a straight ramp from 0 to 1. Allow a little slack:
             * the table is float, and a genuinely neutral profile can still
             * round a few entries. One part in 2000 is well below anything a
             * real calibration would produce and well above rounding. */
            const float tolerance = 1.0f / 2048.0f;
            for (uint32_t index = 0; index < count && !active; index++) {
                float expected = (float)index / (float)(count - 1);
                if (fabsf(red[index] - expected) > tolerance ||
                    fabsf(green[index] - expected) > tolerance ||
                    fabsf(blue[index] - expected) > tolerance)
                    active = true;
            }
        }
        free(red); free(green); free(blue);

        if (active && profile_name && name_size) {
            NSURL *url = registered_profile_url(display);
            snprintf(profile_name, name_size, "%s",
                     url ? url.lastPathComponent.UTF8String : "the active profile");
        }
        return active;
    }
}

/* ------------------------------------------------------------------ *
 * The patch window
 * ------------------------------------------------------------------ */

static CAMetalLayer *metal_layer_for_window(struct SDL_Window *window)
{
    NSWindow *nswindow = (__bridge NSWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties((SDL_Window *)window),
        SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    NSView *view = nswindow.contentView;
    if ([view.layer isKindOfClass:CAMetalLayer.class]) return (CAMetalLayer *)view.layer;
    for (NSView *child in view.subviews)
        if ([child.layer isKindOfClass:CAMetalLayer.class]) return (CAMetalLayer *)child.layer;
    return nil;
}

bool pgen_macos_check_layer_passthrough(struct SDL_Window *window,
                                        unsigned int sdl_display_id,
                                        bool hdr, char *note, size_t note_size)
{
    (void)sdl_display_id;
    if (note && note_size) note[0] = '\0';
    if (!window) return false;

    @autoreleasepool {
        CAMetalLayer *layer = metal_layer_for_window(window);
        if (!layer) {
            /* Not necessarily broken - a non-Metal renderer would land here -
             * but it does mean this check cannot vouch for the pipeline. */
            if (note) snprintf(note, note_size,
                               "Could not inspect the window's Metal layer, so "
                               "code-value accuracy is unverified");
            return false;
        }

        if (hdr) {
            /* The HDR path is extended linear by design - SDL tags the layer
             * for it, and that tagging is what makes 1.0 mean SDR white. An
             * untagged layer here would mean the scRGB surface never happened. */
            CFStringRef name = layer.colorspace ? CGColorSpaceCopyName(layer.colorspace) : NULL;
            NSString *label = name ? CFBridgingRelease(name) : nil;
            bool linear = label && [label containsString:@"Linear"];
            if (linear) {
                SDL_Log("macOS: Metal layer is %s, the extended-linear surface "
                        "the HDR path needs", label.UTF8String);
                return true;
            }
            if (note)
                snprintf(note, note_size,
                         "HDR asked for an extended-linear surface but the layer "
                         "is %s", label ? label.UTF8String : "untagged");
            return false;
        }

        if (layer.colorspace == NULL) {
            SDL_Log("macOS: Metal layer is untagged, so no colour matching is "
                    "applied and patches reach the panel as device values");
            return true;
        }

        /* Tagged with something in SDR. One case is recoverable and common:
         * after a failed HDR attempt SDL recreates the renderer with sRGB but
         * does NOT clear the extended-linear colorspace it set for the scRGB
         * surface, so the SDR fallback inherits it and every patch would be
         * silently colour-managed. Clearing it restores exactly the state SDL
         * leaves for an ordinary SDR window. */
        {
            CFStringRef stale = CGColorSpaceCopyName(layer.colorspace);
            NSString *staleName = stale ? CFBridgingRelease(stale) : nil;
            if (staleName && [staleName containsString:@"Linear"]) {
                layer.colorspace = NULL;
                SDL_Log("macOS: cleared a stale %s tag left on the layer by a "
                        "failed HDR attempt; SDR patches would otherwise have "
                        "been colour-managed", staleName.UTF8String);
                return true;
            }
        }

        /* If it happens to be the display's own space the match is an identity
         * and the result is the same, so accept that rather than failing on a
         * technicality. Anything else is a real conversion the Companion must
         * not paper over. */
        CGColorSpaceRef display_space =
            CGDisplayCopyColorSpace(display_id_for_window(window));
        bool identity = display_space &&
                        CFEqual(layer.colorspace, display_space);
        if (display_space) CGColorSpaceRelease(display_space);
        if (identity) return true;

        CFStringRef name = CGColorSpaceCopyName(layer.colorspace);
        NSString *label = name ? CFBridgingRelease(name) : @"an unnamed colour space";
        if (note)
            snprintf(note, note_size,
                     "The patch window is tagged %s, so macOS is converting "
                     "patches before they reach the panel", label.UTF8String);
        SDL_Log("macOS: %s", note ? note : "layer is colour-managed");
        return false;
    }
}

void pgen_macos_activate_window(struct SDL_Window *window)
{
    if (!window) return;
    @autoreleasepool {
        NSWindow *nswindow = (__bridge NSWindow *)SDL_GetPointerProperty(
            SDL_GetWindowProperties((SDL_Window *)window),
            SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        /* SDL_RaiseWindow alone is unreliable here: without an explicit
         * application activation the window can come forward without taking
         * key focus, which loses the F11 and Escape handling mid-series. */
        if (@available(macOS 14.0, *)) [NSApp activate];
        else [NSApp activateIgnoringOtherApps:YES];
        [nswindow makeKeyAndOrderFront:nil];
    }
}
