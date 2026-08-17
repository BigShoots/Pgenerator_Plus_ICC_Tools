/* PGenerator+ Profile Loader for macOS
 *
 * Forked from pgen-profile-loader-linux.c. The UI, the profile scanning and
 * the ICC tag inspection are that file's, unchanged; what is replaced is the
 * backend underneath them.
 *
 * Linux has to pick between two display backends at runtime and cope with
 * neither being present - KWin through kscreen-doctor, colord through
 * colormgr, and a prompt to install colord when there is no backend at all.
 * macOS has exactly one, ColorSync, and it is always there. That deletes the
 * backend selection, the shell-out layer, the pkexec escalation and the
 * missing-backend prompts outright.
 *
 * Two things are genuinely different here, not just simpler:
 *
 *   One slot.  macOS keeps a single ColorSync profile per display. Windows
 *              keeps separate SDR and HDR defaults (COLORPROFILESUBTYPE 7 and
 *              8) and KWin keeps iccProfilePath and hdrIccProfilePath. macOS
 *              has no equivalent, so an HDR profile assigned here also governs
 *              SDR content. The UI says so rather than letting someone find
 *              out by looking at their desktop.
 *
 *   MHC2 is    A profile PGenerator+ built for Windows carries its calibration
 *   inert.     in an MHC2 tag that only Windows consumes. If such a profile
 *              also has vcgt, macOS still applies that and the profile is
 *              useful; if the calibration lives only in MHC2, assigning it
 *              leaves the display uncalibrated. Those two cases look identical
 *              in a file listing, so the UI distinguishes them.
 *
 * Nothing here needs privileges. Installing a profile is a user-domain
 * ColorSyncProfileInstall into ~/Library/ColorSync/Profiles, which is the
 * whole of what pkexec was needed for on Linux.
 */

#define _DARWIN_C_SOURCE
#define SDL_MAIN_USE_CALLBACKS 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_tray.h>

#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <ColorSync/ColorSync.h>
#include <CoreGraphics/CoreGraphics.h>

/* The shared PGenerator+ application icon, generated from the same favicon the
 * Windows resource script compiles in. See make-icon-header.py. */
#include "pgen-icc-companion-icon.h"
/* Proportional UI font atlases. SDL alone can only draw its 8x8 monospace
 * debug font, which reads as terminal output; SDL_ttf would mean shipping a
 * second shared library, a font file and freetype. See make-font-header.py. */
#include "pgen-ui-font.h"

#define APP_NAME "PGenerator+ Profile Loader"
#define APP_VERSION "1.0.0"

/* Point sizes. See the scaling note above draw_ui(). */
#define WINDOW_DEFAULT_W 720
#define WINDOW_DEFAULT_H 556
#define WINDOW_MIN_W 460
#define WINDOW_MIN_H 360
#define MAX_DISPLAYS 16
#define MAX_PROFILES 256
#define DISPLAY_ROWS 3
#define PROFILE_ROWS 5
#define COMMAND_CAPACITY 65536
#define VERIFY_INTERVAL_MS 5000

typedef enum {
    PROFILE_KIND_UNKNOWN = 0,
    PROFILE_KIND_SDR,
    PROFILE_KIND_WINDOWS_SDR,
    PROFILE_KIND_KDE_HDR,
    PROFILE_KIND_WINDOWS_HDR
} ProfileKind;

typedef struct {
    char name[64];          /* Connector name, e.g. DP-2 */
    char model[192];        /* Friendly monitor name, e.g. the EDID model */
    char colord_id[192];    /* colord device id, when colord knows this display */
    char icc_path[1024];    /* Profile the compositor currently has applied */
    int x, y, width, height; /* Logical geometry, used to match SDL's displays */
    bool hdr;
    bool enabled;
    bool from_kwin;
} DisplayEntry;

typedef struct {
    char path[1024];
    char name[256];
    ProfileKind kind;
    bool has_mhc2;
} ProfileEntry;

typedef enum { STATUS_BAD = 0, STATUS_OK, STATUS_PENDING } StatusLevel;

/* Raised at most once per session, and only when there is genuinely nothing
 * able to apply a profile. A KWin session never sees any of these. */
typedef enum {
    PROMPT_NONE = 0,
    PROMPT_COLORD_MISSING,      /* No KWin and no colord - offer to install */
    PROMPT_NO_BACKEND           /* colord is present but reaches no display */
} PromptKind;

typedef struct {
    SDL_Window *window;
    SDL_Renderer *renderer;

    bool have_kscreen;
    bool have_colormgr;
    bool have_pkexec;
    bool colord_running;
    int colord_display_devices;

    DisplayEntry displays[MAX_DISPLAYS];
    int display_count;
    int display_index;
    int display_scroll;

    ProfileEntry profiles[MAX_PROFILES];
    int profile_count;
    int profile_index;
    int profile_scroll;

    char selected_profile[1024];
    /* What this loader actually put on a display, and which display it went to.
     * Distinct from selected_profile, which is only what the list is pointing
     * at - including the entry preselected at startup, which nobody asked for.
     * The self-healer defends this and nothing else. */
    char applied_profile[1024];
    char applied_display[256];

    SDL_Mutex *lock;
    SDL_Thread *worker;
    SDL_AtomicInt worker_busy;
    SDL_AtomicInt refresh_requested;
    char status_heading[64];
    char status_detail[768];
    StatusLevel status_level;

    uint64_t next_verify_ms;
    /* Self-healing, on the Windows loader's model rather than the Linux one.
     * macOS genuinely drops a display's profile assignment - on hotplug, on a
     * resolution or refresh change, and on wake with some external panels - so
     * reporting alone would leave someone uncalibrated without knowing.
     *
     * The guard rails are what stop a self-healer turning into a fight with
     * the user: act only on a second consecutive mismatch, at most one
     * reassociation a minute, never reinstall from the timer, and give up
     * after three failures rather than retrying forever. */
    int mismatch_count;
    int reapply_failures;
    uint64_t last_reapply_ms;
    bool reapply_attempted;
    bool auto_reapply;
    /* Menu-bar item, matching the Windows loader's tray. The Linux build has
     * none, so this is parity with Windows rather than with the sibling. It is
     * how the loader stays useful while its window is closed - which is the
     * normal state for something whose job is to keep watching. */
    SDL_Tray *tray;
    SDL_TrayEntry *tray_status;
    SDL_TrayEntry *tray_auto;
    bool dialog_open;
    PromptKind prompt;
    bool colord_prompt_done;   /* Declined or acknowledged - do not nag again */
    bool in_modal;             /* Set only while the prompt's own controls draw */
    bool kwin_driving;         /* KWin reported displays, so colord is not used */
    bool auto_sized;           /* The one-shot fit-to-content pass has happened */
    bool silent_apply;         /* Companion one-shot: apply, verify externally, exit */
    bool silent_started;
    /* The Companion's result file. Linux has no equivalent - there the
     * Companion infers the outcome by asking the compositor what it ended up
     * with - but macOS can answer definitively through ColorSync, so use the
     * Windows contract and report a real answer. */
    char result_path[1024];
    bool result_written;
    /* SDL's video functions belong to the main thread, but the enumeration
     * that needs display names runs on the worker. The main thread snapshots
     * them here and the worker only reads the snapshot. */
    struct {
        char name[192];
        SDL_Rect bounds;
    } sdl_displays[MAX_DISPLAYS];
    int sdl_display_count;

    /* Drawing state. window_w/window_h are points; density is the single
     * point-to-pixel factor, applied once by SDL_SetRenderScale. */
    float density;
    float window_w, window_h;
    float scroll_y, content_height;
    SDL_Texture *font_texture[PGEN_FACE_COUNT];

    float mouse_x, mouse_y;
    bool mouse_down, mouse_clicked;
} LoaderState;

static LoaderState app;


/* ------------------------------------------------- ColorSync backend (C) */

/* The macOS display identity and profile state the loader works with. The
 * display's stable identity is its CGDisplay UUID - it survives reboots and
 * distinguishes two identical panels, which a display name cannot. */
typedef struct {
    bool valid;
    char name[256];
    char uuid[64];
    char icc_path[1024];
    bool hdr;
    uint32_t display_id;
} PgenMacDisplay;

static CGDirectDisplayID pgen_macos_id_for_uuid(const char *text)
{
    CFStringRef string;
    CFUUIDRef uuid;
    CGDirectDisplayID display;
    if (!text || !text[0]) return 0;
    string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!string) return 0;
    uuid = CFUUIDCreateFromString(NULL, string);
    CFRelease(string);
    if (!uuid) return 0;
    display = CGDisplayGetDisplayIDFromUUID(uuid);
    CFRelease(uuid);
    return display;
}

/* The profile ColorSync has registered for a display, custom before factory -
 * the same precedence the Displays pane shows. Empty when none has a file
 * behind it, which happens for profiles WindowServer synthesises in memory. */
static void pgen_macos_registered_profile(CFUUIDRef uuid, char *out, size_t out_size)
{
    CFDictionaryRef info;
    CFStringRef buckets[2] = { kColorSyncCustomProfiles, kColorSyncFactoryProfiles };
    out[0] = '\0';
    info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuid);
    if (!info) return;
    for (int bucket = 0; bucket < 2 && !out[0]; bucket++) {
        CFDictionaryRef profiles = CFDictionaryGetValue(info, buckets[bucket]);
        CFTypeRef entry = NULL;
        CFURLRef url = NULL;
        if (!profiles || CFGetTypeID(profiles) != CFDictionaryGetTypeID()) continue;
        entry = CFDictionaryGetValue(profiles, kColorSyncDeviceDefaultProfileID);
        if (entry) entry = CFDictionaryGetValue(profiles, entry);
        if (!entry) {
            /* The default key is optional when only one profile is present. */
            CFIndex count = CFDictionaryGetCount(profiles);
            const void *keys[8], *values[8];
            if (count > 0 && count <= 8) {
                CFDictionaryGetKeysAndValues(profiles, keys, values);
                for (CFIndex index = 0; index < count; index++) {
                    if (CFEqual(keys[index], kColorSyncDeviceDefaultProfileID)) continue;
                    entry = values[index];
                    break;
                }
            }
        }
        if (entry && CFGetTypeID(entry) == CFDictionaryGetTypeID())
            url = (CFURLRef)CFDictionaryGetValue((CFDictionaryRef)entry,
                                                 kColorSyncDeviceProfileURL);
        else if (entry && CFGetTypeID(entry) == CFURLGetTypeID())
            url = (CFURLRef)entry;
        if (url && CFGetTypeID(url) == CFURLGetTypeID())
            CFURLGetFileSystemRepresentation(url, true, (UInt8 *)out, (CFIndex)out_size);
    }
    CFRelease(info);
}

static int pgen_macos_enumerate_displays(PgenMacDisplay *out, int capacity)
{
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    int written = 0;
    if (!out || capacity <= 0) return 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) return 0;
    for (uint32_t index = 0; index < count && written < capacity; index++) {
        PgenMacDisplay *entry = &out[written];
        CFUUIDRef uuid;
        /* A display that only mirrors another has no profile slot to manage. */
        if (CGDisplayIsInMirrorSet(displays[index]) &&
            CGDisplayMirrorsDisplay(displays[index]) != kCGNullDirectDisplay)
            continue;
        memset(entry, 0, sizeof(*entry));
        entry->display_id = displays[index];
        uuid = CGDisplayCreateUUIDFromDisplayID(displays[index]);
        if (!uuid) continue;
        {
            CFStringRef text = CFUUIDCreateString(NULL, uuid);
            if (text) {
                CFStringGetCString(text, entry->uuid, sizeof(entry->uuid),
                                   kCFStringEncodingUTF8);
                CFRelease(text);
            }
        }
        {
            /* Localized device name from ColorSync's registration - no AppKit
             * needed, and it matches what SDL reports for the same panel. */
            CFDictionaryRef info =
                ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuid);
            CFStringRef name = NULL;
            if (info) name = CFDictionaryGetValue(info, kColorSyncDeviceDescription);
            if (name && CFGetTypeID(name) == CFStringGetTypeID())
                CFStringGetCString(name, entry->name, sizeof(entry->name),
                                   kCFStringEncodingUTF8);
            if (info) CFRelease(info);
            if (!entry->name[0])
                SDL_snprintf(entry->name, sizeof(entry->name), "Display %u",
                             (unsigned)displays[index]);
        }
        pgen_macos_registered_profile(uuid, entry->icc_path, sizeof(entry->icc_path));
        CFRelease(uuid);
        entry->valid = true;
        written++;
    }
    return written;
}

static void pgen_macos_user_profile_directory(char *out, size_t out_size)
{
    const char *home = getenv("HOME");
    SDL_snprintf(out, out_size, "%s/Library/ColorSync/Profiles",
                 home && home[0] ? home : ".");
}

/* Whether a display can be assigned this file at all.
 *
 * ColorSync builds a CGColorSpace from whatever it is handed and SkyLight
 * asserts that the result is RGB, so handing it anything else does not fail
 * the call - it aborts the process, with no error path to report. A stock
 * macOS install is full of candidates: /Library/ColorSync/Profiles opens with
 * six abstract Lab tone profiles, and the system directory carries Gray, CMYK,
 * Lab, XYZ and named-colour ones beside the RGB displays.
 *
 * Screening is by ICC header, which settles it in 24 bytes: a display device
 * class carrying RGB data. */
static bool pgen_macos_profile_is_assignable(const char *icc_path)
{
    unsigned char header[24];
    FILE *handle;
    size_t got;
    if (!icc_path || !icc_path[0]) return false;
    handle = fopen(icc_path, "rb");
    if (!handle) return false;
    got = fread(header, 1, sizeof(header), handle);
    fclose(handle);
    if (got != sizeof(header)) return false;
    return memcmp(header + 12, "mntr", 4) == 0 &&
           memcmp(header + 16, "RGB ", 4) == 0;
}

/* Assign a profile as the display's custom default, or fall back to the
 * factory profile when icc_path is NULL - the documented kCFNull path. The
 * dictionary shape is the flat one SetCustomProfiles takes: ProfileID to
 * CFURL, distinct from the nested shape device registration uses. */
static bool pgen_macos_assign_profile(const char *display_uuid, const char *icc_path,
                                      char *message, size_t message_size)
{
    CGDirectDisplayID display = pgen_macos_id_for_uuid(display_uuid);
    CFUUIDRef uuid;
    CFURLRef url = NULL;
    CFDictionaryRef info;
    const void *key, *value;
    bool ok;
    if (message && message_size) message[0] = '\0';
    if (!display) {
        if (message) SDL_strlcpy(message, "That display is no longer attached.",
                                 message_size);
        return false;
    }
    /* NULL is the documented revert-to-factory path and stays allowed; a named
     * file has to survive the screen above, because the failure mode below
     * this line is an abort rather than a return. */
    if (icc_path && icc_path[0] && !pgen_macos_profile_is_assignable(icc_path)) {
        if (message) SDL_strlcpy(message, "That file is not an RGB display "
                                 "profile, so macOS cannot assign it to a "
                                 "display.", message_size);
        return false;
    }
    uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) {
        if (message) SDL_strlcpy(message, "macOS did not report a stable "
                                 "identifier for that display.", message_size);
        return false;
    }
    if (icc_path && icc_path[0])
        url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)icc_path,
                                                      (CFIndex)strlen(icc_path), false);
    key = kColorSyncDeviceDefaultProfileID;
    value = url ? (const void *)url : (const void *)kCFNull;
    info = CFDictionaryCreate(NULL, &key, &value, 1,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
    ok = info && ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass,
                                                  uuid, info);
    if (info) CFRelease(info);
    if (url) CFRelease(url);
    CFRelease(uuid);
    if (!ok && message)
        SDL_strlcpy(message, "ColorSync refused the profile assignment.",
                    message_size);
    return ok;
}

/* Whether WindowServer is actually rendering with this profile, as opposed to
 * the device database merely recording it. Only the first claim means the
 * display is calibrated, so verification compares the ICC payload the
 * compositor returns against the file - a display colour space has no useful
 * name to compare. */
static bool pgen_macos_windowserver_uses(const char *display_uuid, const char *icc_path)
{
    CGDirectDisplayID display = pgen_macos_id_for_uuid(display_uuid);
    CGColorSpaceRef space;
    CFDataRef live;
    FILE *handle;
    long length;
    unsigned char *wanted = NULL;
    bool same = false;
    if (!display || !icc_path || !icc_path[0]) return false;
    handle = fopen(icc_path, "rb");
    if (!handle) return false;
    if (fseek(handle, 0, SEEK_END) != 0 || (length = ftell(handle)) <= 0 ||
        fseek(handle, 0, SEEK_SET) != 0) { fclose(handle); return false; }
    wanted = SDL_malloc((size_t)length);
    if (!wanted || fread(wanted, 1, (size_t)length, handle) != (size_t)length) {
        SDL_free(wanted); fclose(handle); return false;
    }
    fclose(handle);
    space = CGDisplayCopyColorSpace(display);
    live = space ? CGColorSpaceCopyICCData(space) : NULL;
    if (space) CGColorSpaceRelease(space);
    if (live) {
        same = CFDataGetLength(live) == (CFIndex)length &&
               memcmp(CFDataGetBytePtr(live), wanted, (size_t)length) == 0;
        CFRelease(live);
    }
    SDL_free(wanted);
    return same;
}

static void pgen_macos_open_display_settings(void)
{
    (void)system("open 'x-apple.systempreferences:com.apple.Displays-Settings.extension' "
                 ">/dev/null 2>&1 || open /System/Library/PreferencePanes/Displays.prefPane "
                 ">/dev/null 2>&1");
}

/* ------------------------------------------------------------------ helpers */

static void set_status(StatusLevel level, const char *heading, const char *detail)
{
    SDL_LockMutex(app.lock);
    app.status_level = level;
    SDL_strlcpy(app.status_heading, heading, sizeof(app.status_heading));
    SDL_strlcpy(app.status_detail, detail, sizeof(app.status_detail));
    SDL_UnlockMutex(app.lock);
}

/* Linux had to hunt for kscreen-doctor, colormgr and pkexec and cope with any
 * of them missing. ColorSync is part of the system, so there is nothing to
 * look for; the flags this fed stay true and the UI keeps its shape. */
static bool tool_exists(const char *name)
{
    (void)name;
    return true;
}

/* Run a program directly - never through a shell, so profile paths containing
 * spaces or quotes cannot turn into extra arguments. stdout and stderr are
 * captured together because the tools report failures on both. */
static int run_capture(const char *const argv[], char *out, size_t out_size)
{
    int pipe_fds[2];
    pid_t child;
    size_t used = 0;
    int status = 0;
    if (out && out_size) out[0] = '\0';
    if (pipe(pipe_fds) != 0) return -1;
    child = fork();
    if (child < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return -1;
    }
    if (child == 0) {
        close(pipe_fds[0]);
        dup2(pipe_fds[1], STDOUT_FILENO);
        dup2(pipe_fds[1], STDERR_FILENO);
        close(pipe_fds[1]);
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }
    close(pipe_fds[1]);
    for (;;) {
        ssize_t got;
        char scratch[4096];
        char *target = (out && used + 1 < out_size) ? out + used : scratch;
        size_t room = (out && used + 1 < out_size) ? out_size - used - 1 : sizeof(scratch);
        got = read(pipe_fds[0], target, room);
        if (got <= 0) break;
        if (target != scratch) {
            used += (size_t)got;
            out[used] = '\0';
        }
    }
    close(pipe_fds[0]);
    if (waitpid(child, &status, 0) < 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

/* kscreen-doctor colours its human-readable output. */
static void strip_ansi(char *text)
{
    char *read_cursor = text, *write_cursor = text;
    while (*read_cursor) {
        if (*read_cursor == '\x1b') {
            while (*read_cursor && *read_cursor != 'm') read_cursor++;
            if (*read_cursor) read_cursor++;
            continue;
        }
        *write_cursor++ = *read_cursor++;
    }
    *write_cursor = '\0';
}

/* Value of the next occurrence of "key":"..." at or after *cursor, advancing
 * the cursor past it. Enough for kscreen-doctor's flat output objects. */
static bool json_next_string(const char **cursor, const char *key, char *value, size_t value_size)
{
    char needle[64];
    const char *found, *start, *end;
    SDL_snprintf(needle, sizeof(needle), "\"%s\"", key);
    found = strstr(*cursor, needle);
    if (!found) return false;
    start = strchr(found + strlen(needle), '"');
    if (!start) return false;
    end = ++start;
    while (*end && *end != '"') {
        if (*end == '\\' && end[1]) end++;
        end++;
    }
    if (*end != '"') return false;
    SDL_snprintf(value, value_size, "%.*s", (int)(end - start), start);
    *cursor = end + 1;
    return true;
}

/* ------------------------------------------------------------- profile facts */

static uint32_t read_be32(const unsigned char *bytes)
{
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

/* An MHC2 tag means the profile also carries a system calibration stage, the
 * same test the Windows loader makes. */
static bool profile_contains_mhc2(const char *path)
{
    unsigned char header[132];
    FILE *file = fopen(path, "rb");
    uint32_t count, index;
    if (!file) return false;
    if (fread(header, 1, sizeof(header), file) != sizeof(header)) {
        fclose(file);
        return false;
    }
    count = read_be32(header + 128);
    if (count > 4096) {
        fclose(file);
        return false;
    }
    for (index = 0; index < count; index++) {
        unsigned char tag[12];
        if (fread(tag, 1, sizeof(tag), file) != sizeof(tag)) break;
        if (memcmp(tag, "MHC2", 4) == 0) {
            fclose(file);
            return true;
        }
    }
    fclose(file);
    return false;
}

static bool profile_contains_hdr_cicp(const char *path)
{
    FILE *file = fopen(path, "rb");
    unsigned char header[132];
    uint32_t count, index;
    if (!file) return false;
    if (fread(header, 1, sizeof(header), file) != sizeof(header)) {
        fclose(file);
        return false;
    }
    count = read_be32(header + 128);
    if (count > 4096) {
        fclose(file);
        return false;
    }
    for (index = 0; index < count; index++) {
        unsigned char tag[12], payload[12];
        uint32_t offset, size;
        if (fseek(file, 132L + (long)index * 12L, SEEK_SET) != 0 ||
            fread(tag, 1, sizeof(tag), file) != sizeof(tag)) break;
        if (memcmp(tag, "cicp", 4) != 0) continue;
        offset = read_be32(tag + 4);
        size = read_be32(tag + 8);
        if (size < sizeof(payload) || fseek(file, (long)offset, SEEK_SET) != 0 ||
            fread(payload, 1, sizeof(payload), file) != sizeof(payload)) break;
        fclose(file);
        return memcmp(payload, "cicp", 4) == 0 && payload[8] == 9 &&
               payload[9] == 16 && payload[10] == 0 && payload[11] == 1;
    }
    fclose(file);
    return false;
}

/* The builder stamps the profile type into the file name: -SDR-, -SDR-MHC2-,
 * -KDE-HDR- and -HDR-MHC2- (icc_profile_builder.py). Classify from that first
 * and fall back to the tag table, so a renamed file is still described
 * correctly rather than mislabelled. */
static ProfileKind classify_profile(const char *path, bool has_mhc2)
{
    char upper[1024];
    size_t index;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    for (index = 0; index + 1 < sizeof(upper) && name[index]; index++)
        upper[index] = (char)SDL_toupper((unsigned char)name[index]);
    upper[index] = '\0';
    if (strstr(upper, "-KDE-HDR-")) return PROFILE_KIND_KDE_HDR;
    if (strstr(upper, "-HDR-MHC2-")) return PROFILE_KIND_WINDOWS_HDR;
    if (strstr(upper, "-SDR-MHC2-")) return PROFILE_KIND_WINDOWS_SDR;
    if (strstr(upper, "-SDR-")) return PROFILE_KIND_SDR;
    if (strstr(upper, "HDR")) return has_mhc2 ? PROFILE_KIND_WINDOWS_HDR : PROFILE_KIND_KDE_HDR;
    if (profile_contains_hdr_cicp(path))
        return has_mhc2 ? PROFILE_KIND_WINDOWS_HDR : PROFILE_KIND_KDE_HDR;
    if (has_mhc2) return PROFILE_KIND_WINDOWS_SDR;
    return PROFILE_KIND_UNKNOWN;
}

/* Wording kept in step with icc_profile_builder.py PROFILE_TYPES. */
static const char *profile_kind_label(ProfileKind kind)
{
    switch (kind) {
    case PROFILE_KIND_SDR: return "SDR display";
    case PROFILE_KIND_WINDOWS_SDR: return "SDR ICC with MHC2 system calibration";
    case PROFILE_KIND_KDE_HDR: return "HDR profile - macOS applies it to SDR content too";
    case PROFILE_KIND_WINDOWS_HDR: return "HDR ICC with MHC2 system calibration";
    default: return "ICC display profile";
    }
}

static bool profile_kind_is_hdr(ProfileKind kind)
{
    return kind == PROFILE_KIND_KDE_HDR || kind == PROFILE_KIND_WINDOWS_HDR;
}

/* ------------------------------------------------------------ profile lookup */

static void user_icc_directory(char *out, size_t out_size)
{
    pgen_macos_user_profile_directory(out, out_size);
}

static void add_profile(const char *directory, const char *name)
{
    ProfileEntry *entry;
    size_t length = strlen(name);
    if (app.profile_count >= MAX_PROFILES) return;
    if (length < 5) return;
    if (SDL_strcasecmp(name + length - 4, ".icc") && SDL_strcasecmp(name + length - 4, ".icm")) return;
    entry = &app.profiles[app.profile_count];
    SDL_snprintf(entry->path, sizeof(entry->path), "%s/%s", directory, name);
    /* The same profile in two directories is still one profile to the reader.
     * Directories are scanned canonical-first, so the copy already sitting in
     * an ICC directory is the one that survives. */
    for (int index = 0; index < app.profile_count; index++)
        if (!strcmp(app.profiles[index].path, entry->path) ||
            !SDL_strcasecmp(app.profiles[index].name, name)) return;
    if (access(entry->path, R_OK) != 0) return;
    /* Offer only what a display can actually be given. The stock profile
     * directories are mostly abstract, Gray, CMYK and Lab files, and listing
     * one invites a click that would take the process down with it. */
    if (!pgen_macos_profile_is_assignable(entry->path)) return;
    SDL_strlcpy(entry->name, name, sizeof(entry->name));
    entry->has_mhc2 = profile_contains_mhc2(entry->path);
    entry->kind = classify_profile(entry->path, entry->has_mhc2);
    app.profile_count++;
}

static void scan_directory(const char *directory)
{
    DIR *handle;
    struct dirent *item;
    if (!directory || !directory[0]) return;
    handle = opendir(directory);
    if (!handle) return;
    while ((item = readdir(handle)) != NULL) {
        if (item->d_name[0] == '.') continue;
        add_profile(directory, item->d_name);
    }
    closedir(handle);
}

/* Everywhere a downloaded PGenerator+ profile realistically lands: beside the
 * loader itself, the per-user and system ICC directories, and the usual
 * download folders. */
static void rescan_profiles(void)
{
    const char *home = getenv("HOME");
    const char *base = SDL_GetBasePath();
    char buffer[1024];
    app.profile_count = 0;
    /* Canonical ICC locations first, so an installed copy wins over the loose
     * one still sitting in a download folder. */
    user_icc_directory(buffer, sizeof(buffer));
    scan_directory(buffer);
    if (home && home[0]) {
        SDL_snprintf(buffer, sizeof(buffer), "%s/.color/icc", home);
        scan_directory(buffer);
    }
    scan_directory("/Library/ColorSync/Profiles");
    scan_directory("/System/Library/ColorSync/Profiles");
    scan_directory("/usr/local/share/color/icc");
    if (base && base[0]) {
        SDL_strlcpy(buffer, base, sizeof(buffer));
        {   /* SDL_GetBasePath keeps the trailing separator. */
            size_t length = strlen(buffer);
            if (length > 1 && buffer[length - 1] == '/') buffer[length - 1] = '\0';
        }
        scan_directory(buffer);
    }
    if (home && home[0]) {
        SDL_snprintf(buffer, sizeof(buffer), "%s/Downloads", home);
        scan_directory(buffer);
        SDL_snprintf(buffer, sizeof(buffer), "%s/Desktop", home);
        scan_directory(buffer);
    }
    if (app.profile_index >= app.profile_count) app.profile_index = app.profile_count - 1;
    if (app.profile_index < 0) app.profile_index = 0;
}

/* ------------------------------------------------------------- KWin backend */

/* The counterpart of the KWin enumeration: ask ColorSync instead of parsing
 * kscreen-doctor. There is no ANSI to strip, no JSON to scrape, and no second
 * HDR slot to reconcile - which is most of what that function was. */
static void refresh_kwin_displays(void)
{
    PgenMacDisplay found[MAX_DISPLAYS];
    int count = pgen_macos_enumerate_displays(found, MAX_DISPLAYS);

    app.display_count = 0;
    for (int index = 0; index < count && app.display_count < MAX_DISPLAYS; index++) {
        DisplayEntry *entry = &app.displays[app.display_count++];
        memset(entry, 0, sizeof(*entry));
        /* `name` is the loader's identity for a display. On Linux it is the
         * connector; here it is the UUID, which is what the Companion passes
         * on the command line and what survives a reboot. `model` is what the
         * operator reads. */
        SDL_strlcpy(entry->name, found[index].uuid, sizeof(entry->name));
        SDL_strlcpy(entry->model, found[index].name, sizeof(entry->model));
        SDL_strlcpy(entry->colord_id, found[index].uuid, sizeof(entry->colord_id));
        SDL_strlcpy(entry->icc_path, found[index].icc_path, sizeof(entry->icc_path));
        entry->hdr = found[index].hdr;
        entry->enabled = true;
        entry->from_kwin = true;
    }
}

/* The Patch Companion names displays with SDL_GetDisplayName (see its
 * select_target_display), which on Wayland is the monitor's make and model.
 * Use the same source here so both tools call the same screen the same thing,
 * matching by logical geometry because SDL does not expose connector names. */
/* Main thread only: SDL's video functions are not safe to call from the
 * worker, and calling them there silently produced rows with no model name. */
static void snapshot_sdl_displays(void)
{
    int count = 0;
    SDL_DisplayID *ids = SDL_GetDisplays(&count);
    app.sdl_display_count = 0;
    if (!ids) return;
    for (int index = 0; index < count && app.sdl_display_count < MAX_DISPLAYS; index++) {
        SDL_Rect bounds;
        const char *name;
        if (!SDL_GetDisplayBounds(ids[index], &bounds)) continue;
        name = SDL_GetDisplayName(ids[index]);
        if (!name || !name[0]) continue;
        SDL_strlcpy(app.sdl_displays[app.sdl_display_count].name, name,
                    sizeof(app.sdl_displays[0].name));
        app.sdl_displays[app.sdl_display_count].bounds = bounds;
        app.sdl_display_count++;
    }
    SDL_free(ids);
}

static void attach_display_models(void)
{
    for (int index = 0; index < app.display_count; index++) {
        DisplayEntry *entry = &app.displays[index];
        if (!entry->from_kwin || entry->width <= 0) continue;
        for (int display = 0; display < app.sdl_display_count; display++) {
            const SDL_Rect *bounds = &app.sdl_displays[display].bounds;
            if (bounds->x != entry->x || bounds->y != entry->y ||
                bounds->w != entry->width || bounds->h != entry->height) continue;
            SDL_strlcpy(entry->model, app.sdl_displays[display].name, sizeof(entry->model));
            break;
        }
    }
}

/* Never blank: an output SDL cannot name still has its connector. */
static const char *display_title(const DisplayEntry *entry)
{
    return entry->model[0] ? entry->model : entry->name;
}

/* -------------------------------------------------------- colord backend */

/* colormgr prints "key: value" records separated by blank lines. */
static bool colormgr_field(const char *record, const char *key, char *value, size_t value_size)
{
    const char *cursor = record;
    size_t key_length = strlen(key);
    while (cursor && *cursor) {
        const char *end = strchr(cursor, '\n');
        const char *scan = cursor;
        while (*scan == ' ' || *scan == '\t') scan++;
        if (!SDL_strncmp(scan, key, key_length) && scan[key_length] == ':') {
            const char *start = scan + key_length + 1;
            while (*start == ' ' || *start == '\t') start++;
            if (!end) end = start + strlen(start);
            while (end > start && (end[-1] == '\r' || end[-1] == ' ')) end--;
            if (end <= start) return false;
            SDL_snprintf(value, value_size, "%.*s", (int)(end - start), start);
            return true;
        }
        cursor = end ? end + 1 : NULL;
    }
    return false;
}

/* No second backend on macOS. Kept so the call sites and the UI's notion of
 * "where did this display come from" do not have to change. */
static void refresh_colord_displays(void)
{
}

/* --------------------------------------------------------------- refreshing */

static void refresh_everything(void)
{
    char keep[64] = "";
    if (app.display_index >= 0 && app.display_index < app.display_count)
        SDL_strlcpy(keep, app.displays[app.display_index].name, sizeof(keep));
    app.display_count = 0;
    app.have_pkexec = tool_exists("pkexec");

    /* Backend order, and the reason for it.
     *
     * KWin through kscreen-doctor comes FIRST. On a Plasma Wayland session the
     * compositor owns the display profile and applies it itself, to SDR and HDR
     * alike, so that is the only route that reaches the screen.
     *
     * colord comes SECOND, and only when KWin reported nothing. Its display
     * enumeration is X11-oriented and registers no output under KWin, so
     * consulting it on a Plasma session would produce a permanent warning about
     * a daemon that is not the mechanism in use. It remains the right backend
     * for X11 sessions and other compositors. */
    app.have_kscreen = tool_exists("kscreen-doctor");
    if (app.have_kscreen) refresh_kwin_displays();
    app.kwin_driving = app.display_count > 0;
    if (app.kwin_driving) {
        app.have_colormgr = false;
        app.colord_display_devices = 0;
    } else {
        app.have_colormgr = tool_exists("colormgr");
        if (app.have_colormgr) refresh_colord_displays();
    }
    attach_display_models();
    rescan_profiles();
    app.display_index = 0;
    for (int index = 0; index < app.display_count; index++)
        if (keep[0] && !strcmp(app.displays[index].name, keep)) app.display_index = index;
}

/* Nothing to say when KWin is driving: colord is simply not the mechanism in
 * use there, which is not a fault and not worth a prompt. */
/* Linux raises a prompt when there is no colour backend and offers to install
 * colord. ColorSync cannot be absent, so there is nothing to prompt about. */
static PromptKind colour_system_prompt(void)
{
    return PROMPT_NONE;
}

static DisplayEntry *selected_display(void)
{
    if (app.display_index < 0 || app.display_index >= app.display_count) return NULL;
    return &app.displays[app.display_index];
}

static ProfileEntry *selected_profile(void)
{
    for (int index = 0; index < app.profile_count; index++)
        if (!strcmp(app.profiles[index].path, app.selected_profile)) return &app.profiles[index];
    return NULL;
}

/* Report whether the selected profile is the one the display is actually
 * using, which is the loader's whole reason to stay open. */
/* Verification means two separate questions on macOS, and only the second one
 * proves the display is actually calibrated:
 *
 *   1. does the ColorSync device database record our profile as the default?
 *   2. is WindowServer actually rendering with it?
 *
 * They can disagree - an assignment can be recorded and not adopted - so the
 * status reflects the second, and says so when they differ. The Linux version
 * only has the first question available to it. */
static void verify_profile(void)
{
    DisplayEntry *display = selected_display();
    char detail[768];

    if (!display) {
        set_status(STATUS_BAD, "NO DISPLAY FOUND",
                   "macOS reported no displays. Press Refresh.");
        return;
    }
    if (!app.selected_profile[0]) {
        if (display->icc_path[0]) {
            SDL_snprintf(detail, sizeof(detail),
                         "%s is currently using %s. Choose a profile below to replace it.",
                         display->model, display->icc_path);
            set_status(STATUS_OK, "PROFILE ACTIVE", detail);
        } else {
            SDL_snprintf(detail, sizeof(detail),
                         "%s has no ICC profile assigned. Choose a PGenerator+ profile "
                         "and apply it.", display->model);
            set_status(STATUS_BAD, "ATTENTION REQUIRED", detail);
        }
        return;
    }
    if (display->icc_path[0] && !strcmp(display->icc_path, app.selected_profile)) {
        ProfileEntry *entry = selected_profile();
        bool live = pgen_macos_windowserver_uses(display->name, app.selected_profile);
        if (!live) {
            /* Recorded but not adopted. Usually a display that changed mode or
             * was replugged since the assignment. */
            SDL_snprintf(detail, sizeof(detail),
                         "%s is assigned to %s, but macOS is still rendering with a "
                         "different profile. Apply it again, or unplug and reconnect "
                         "the display.", app.selected_profile, display->model);
            set_status(STATUS_BAD, "ASSIGNED BUT NOT ACTIVE", detail);
            return;
        }
        SDL_snprintf(detail, sizeof(detail),
                     "Active and verified on %s: %s\n%s. macOS uses one profile for "
                     "both SDR and HDR content on a display.",
                     display->model, app.selected_profile,
                     entry ? profile_kind_label(entry->kind) : "ICC display profile");
        set_status(STATUS_OK, "PROFILE ACTIVE", detail);
        return;
    }
    if (display->icc_path[0]) {
        SDL_snprintf(detail, sizeof(detail),
                     "%s is using a different profile: %s\nApply the selected profile "
                     "to replace it.", display->model, display->icc_path);
        set_status(STATUS_BAD, "ATTENTION REQUIRED", detail);
        return;
    }
    SDL_snprintf(detail, sizeof(detail), "Ready to apply to %s: %s", display->model,
                 app.selected_profile);
    set_status(STATUS_PENDING, "READY TO APPLY", detail);
}

/* ------------------------------------------------------------------ actions */

typedef enum {
    ACTION_REFRESH = 0,
    ACTION_APPLY,
    ACTION_CLEAR,
    ACTION_INSTALL_USER,
    ACTION_INSTALL_SYSTEM,
    ACTION_INSTALL_COLORD,
    ACTION_OPEN_SETTINGS
} LoaderAction;

static SDL_AtomicInt pending_action;

static bool path_is_in_icc_directory(const char *path);
static bool place_in_user_icc(const char *source, char *target, size_t target_size,
                              char *message, size_t message_size);

static bool copy_file(const char *source, const char *target)
{
    FILE *in = fopen(source, "rb");
    FILE *out;
    char buffer[65536];
    size_t got;
    bool ok = true;
    if (!in) return false;
    out = fopen(target, "wb");
    if (!out) {
        fclose(in);
        return false;
    }
    while ((got = fread(buffer, 1, sizeof(buffer), in)) > 0)
        if (fwrite(buffer, 1, got, out) != got) { ok = false; break; }
    if (ferror(in)) ok = false;
    fclose(in);
    if (fclose(out) != 0) ok = false;
    return ok;
}

static bool make_directory_tree(const char *path)
{
    char buffer[1024];
    size_t index;
    SDL_strlcpy(buffer, path, sizeof(buffer));
    for (index = 1; buffer[index]; index++) {
        if (buffer[index] != '/') continue;
        buffer[index] = '\0';
        if (mkdir(buffer, 0755) != 0 && errno != EEXIST) return false;
        buffer[index] = '/';
    }
    return mkdir(buffer, 0755) == 0 || errno == EEXIST;
}

/* Apply through KWin, which is the only route that reaches the compositor on a
 * Plasma Wayland session. */
/* One slot, one call. The Linux version has to choose between iccProfilePath
 * and hdrIccProfilePath and set a matching source property; macOS has neither
 * distinction, so `kind` only affects what the operator is told afterwards. */
static bool apply_with_kwin(DisplayEntry *display, const char *path,
                            ProfileKind kind, char *message, size_t message_size)
{
    (void)kind;
    return pgen_macos_assign_profile(display->name, path[0] ? path : NULL,
                                     message, message_size);
}

/* The colord route the KDE documentation describes. It only reaches a display
 * colord actually knows about. */
/* Unreachable on macOS - refresh_kwin_displays marks every display
 * from_kwin - but kept so action_apply keeps its shape against upstream. */
static bool apply_with_colord(DisplayEntry *display, const char *path,
                              char *message, size_t message_size)
{
    (void)display; (void)path;
    SDL_strlcpy(message, "ColorSync is the only display profile backend on macOS.",
                message_size);
    return false;
}

static void action_apply(void)
{
    DisplayEntry *display = selected_display();
    ProfileEntry *entry = selected_profile();
    /* rescan_profiles() rebuilds app.profiles in place after a downloaded
     * profile is copied into ~/.local/share/icc. Keep the classification now;
     * retaining an entry pointer across that rescan can make an HDR profile
     * inherit the kind of whichever file later occupies the same array slot. */
    ProfileKind kind = entry ? entry->kind
                             : classify_profile(app.selected_profile,
                                                profile_contains_mhc2(app.selected_profile));
    char message[768] = "";
    char detail[768];
    if (!display || !app.selected_profile[0]) {
        set_status(STATUS_BAD, "NOTHING TO APPLY",
                   "Select a display and an ICC profile first.");
        return;
    }
    set_status(STATUS_PENDING, "APPLYING PROFILE", "Handing the profile to the display backend.");
    /* One button does the whole job. A profile picked straight out of a
     * download folder is copied into the user ICC directory first, so it keeps
     * working after the download is cleaned up and so colord can see it. */
    if (!path_is_in_icc_directory(app.selected_profile)) {
        char placed[1200];
        if (!place_in_user_icc(app.selected_profile, placed, sizeof(placed),
                               message, sizeof(message))) {
            set_status(STATUS_BAD, "COULD NOT PLACE THE PROFILE", message);
            return;
        }
        SDL_strlcpy(app.selected_profile, placed, sizeof(app.selected_profile));
        rescan_profiles();
    }
    if (display->from_kwin && app.have_kscreen) {
        if (!apply_with_kwin(display, app.selected_profile,
                             kind,
                             message, sizeof(message))) {
            set_status(STATUS_BAD, "APPLY FAILED", message);
            return;
        }
    } else if (display->colord_id[0] && app.have_colormgr) {
        if (!apply_with_colord(display, app.selected_profile, message, sizeof(message))) {
            set_status(STATUS_BAD, "APPLY FAILED", message);
            return;
        }
    } else {
        set_status(STATUS_BAD, "NO ROUTE TO THIS DISPLAY",
                   "macOS did not report a profile slot for this display "
                   "for it, so there is nothing to apply the profile to.");
        return;
    }
    /* From here the assignment is ours, and the self-healer has something it
     * is entitled to defend. */
    SDL_strlcpy(app.applied_profile, app.selected_profile, sizeof(app.applied_profile));
    SDL_strlcpy(app.applied_display, display->name, sizeof(app.applied_display));
    refresh_everything();
    display = selected_display();
    if (display && profile_kind_is_hdr(kind) && !display->hdr) {
        SDL_snprintf(detail, sizeof(detail),
                     "Applied to %s, but HDR is switched off for this display. An HDR "
                     "profile only describes the display in HDR mode - enable HDR in "
                     "System Settings, or apply an SDR profile instead.", display->name);
        set_status(STATUS_BAD, "HDR IS NOT ENABLED", detail);
        return;
    }
    if (display && !profile_kind_is_hdr(kind) && display->hdr &&
        kind != PROFILE_KIND_UNKNOWN) {
        SDL_snprintf(detail, sizeof(detail),
                     "Applied to %s, but this display is in HDR mode and the profile "
                     "describes SDR output. Use an HDR profile, or turn HDR off.",
                     display->name);
        set_status(STATUS_BAD, "PROFILE DOES NOT MATCH HDR", detail);
        return;
    }
    verify_profile();
}

static void action_clear(void)
{
    DisplayEntry *display = selected_display();
    char message[768] = "";
    if (!display) return;
    /* Clearing withdraws the claim as well as the profile - otherwise the
     * self-healer would put back what was just deliberately removed. */
    if (app.applied_display[0] && !strcmp(app.applied_display, display->name)) {
        app.applied_profile[0] = '\0';
        app.applied_display[0] = '\0';
    }
    if (display->from_kwin && app.have_kscreen) {
        ProfileKind active_kind = display->hdr ? PROFILE_KIND_KDE_HDR : PROFILE_KIND_SDR;
        if (!apply_with_kwin(display, "", active_kind, message, sizeof(message))) {
            set_status(STATUS_BAD, "COULD NOT CLEAR", message);
            return;
        }
        refresh_everything();
        set_status(STATUS_PENDING, "DISPLAY PROFILE CLEARED",
                   "The display is back to its untagged output. The profile file is "
                   "untouched and can be applied again.");
        return;
    }
    if (display->colord_id[0] && app.have_colormgr) {
        const char *argv[] = {"colormgr", "device-make-profile-default", display->colord_id, "", NULL};
        char output[4096];
        run_capture(argv, output, sizeof(output));
        refresh_everything();
        set_status(STATUS_PENDING, "DISPLAY PROFILE CLEARED",
                   "Asked colord to drop the default profile for this device.");
        return;
    }
    set_status(STATUS_BAD, "NO ROUTE TO THIS DISPLAY",
               "There is no backend that can clear this display's profile.");
}

/* Is the profile already somewhere the colour stack looks? Apply uses this to
 * decide whether it has to place the file before assigning it. */
static bool path_is_in_icc_directory(const char *path)
{
    char directory[1024];
    const char *home = getenv("HOME");
    const char *roots[] = {"/Library/ColorSync/Profiles",
                          "/System/Library/ColorSync/Profiles",
                           "/var/lib/color/icc", NULL};
    user_icc_directory(directory, sizeof(directory));
    if (!SDL_strncmp(path, directory, strlen(directory)) && path[strlen(directory)] == '/')
        return true;
    if (home && home[0]) {
        SDL_snprintf(directory, sizeof(directory), "%s/.color/icc", home);
        if (!SDL_strncmp(path, directory, strlen(directory)) && path[strlen(directory)] == '/')
            return true;
    }
    for (int index = 0; roots[index]; index++)
        if (!SDL_strncmp(path, roots[index], strlen(roots[index])) &&
            path[strlen(roots[index])] == '/') return true;
    return false;
}

/* Copy into the per-user ICC directory. Unprivileged: ~/.local/share/icc is
 * the XDG location colord and ICC-aware applications already scan. */
static bool place_in_user_icc(const char *source, char *target, size_t target_size,
                              char *message, size_t message_size)
{
    char directory[1024];
    const char *name = strrchr(source, '/');
    name = name ? name + 1 : source;
    user_icc_directory(directory, sizeof(directory));
    if (!make_directory_tree(directory)) {
        SDL_snprintf(message, message_size, "Could not create %s: %s", directory, strerror(errno));
        return false;
    }
    SDL_snprintf(target, target_size, "%s/%s", directory, name);
    if (!strcmp(target, source)) return true;
    if (!copy_file(source, target)) {
        SDL_snprintf(message, message_size, "Could not copy the profile to %s.", target);
        return false;
    }
    return true;
}

static void action_install_user(void)
{
    char directory[1024], target[1200], detail[768];
    const char *name;
    if (!app.selected_profile[0]) {
        set_status(STATUS_BAD, "NO PROFILE SELECTED", "Choose an ICC profile first.");
        return;
    }
    name = strrchr(app.selected_profile, '/');
    name = name ? name + 1 : app.selected_profile;
    user_icc_directory(directory, sizeof(directory));
    if (!make_directory_tree(directory)) {
        SDL_snprintf(detail, sizeof(detail), "Could not create %s: %s", directory, strerror(errno));
        set_status(STATUS_BAD, "INSTALL FAILED", detail);
        return;
    }
    SDL_snprintf(target, sizeof(target), "%s/%s", directory, name);
    if (!strcmp(target, app.selected_profile)) {
        set_status(STATUS_PENDING, "ALREADY INSTALLED",
                   "This profile is already in your personal ICC directory.");
        return;
    }
    if (!copy_file(app.selected_profile, target)) {
        SDL_snprintf(detail, sizeof(detail), "Could not copy the profile to %s.", target);
        set_status(STATUS_BAD, "INSTALL FAILED", detail);
        return;
    }
    SDL_strlcpy(app.selected_profile, target, sizeof(app.selected_profile));
    rescan_profiles();
    SDL_snprintf(detail, sizeof(detail),
                 "Installed for your user account:\n%s\nNo administrator rights were needed. "
                 "Apply it to the display next.", target);
    set_status(STATUS_PENDING, "PROFILE INSTALLED", detail);
}

/* Root-only actions. pkexec asks the desktop for authorisation; sudo is never
 * invoked behind the user's back, and the exact command is always shown so the
 * step can be done by hand instead. */
/* On Linux this is the pkexec copy into /usr/share/color/icc, the one action
 * that needs root. macOS has no equivalent worth offering: the user domain is
 * enough for the display to be calibrated, and /Library/ColorSync/Profiles
 * would need an authorization prompt to benefit only other user accounts. */
static void action_install_system(void)
{
    set_status(STATUS_PENDING, "NOT NEEDED ON MACOS",
               "A profile in your own ColorSync folder already applies to the display "
               "for this account. Installing for all users is not required.");
}

/* No colord to install. */
static void action_install_colord(void)
{
    set_status(STATUS_PENDING, "NOT NEEDED ON MACOS",
               "ColorSync is part of macOS; there is nothing to install.");
}

static void action_open_settings(void)
{
    pgen_macos_open_display_settings();
    set_status(STATUS_PENDING, "SYSTEM SETTINGS",
               "Opened Displays in System Settings. The colour profile is under the "
               "display's Colour Profile control.");
}

static int SDLCALL worker_main(void *unused)
{
    (void)unused;
    switch ((LoaderAction)SDL_GetAtomicInt(&pending_action)) {
    case ACTION_APPLY: action_apply(); break;
    case ACTION_CLEAR: action_clear(); break;
    case ACTION_INSTALL_USER: action_install_user(); break;
    case ACTION_INSTALL_SYSTEM: action_install_system(); break;
    case ACTION_INSTALL_COLORD: action_install_colord(); break;
    case ACTION_OPEN_SETTINGS: action_open_settings(); break;
    case ACTION_REFRESH:
    default:
        refresh_everything();
        verify_profile();
        break;
    }
    SDL_SetAtomicInt(&app.worker_busy, 0);
    return 0;
}

/* Every action shells out to a tool that can take a second or more, so run it
 * off the event loop and keep the window drawing. */
static void start_action(LoaderAction action)
{
    if (SDL_GetAtomicInt(&app.worker_busy)) return;
    if (app.worker) {
        SDL_WaitThread(app.worker, NULL);
        app.worker = NULL;
    }
    SDL_SetAtomicInt(&pending_action, (int)action);
    SDL_SetAtomicInt(&app.worker_busy, 1);
    app.worker = SDL_CreateThread(worker_main, "PGen loader worker", NULL);
    if (!app.worker) {
        SDL_SetAtomicInt(&app.worker_busy, 0);
        worker_main(NULL);
    }
}

/* ---------------------------------------------------------------- rendering */

/* SCALING MODEL - one factor, applied exactly once.
 *
 * The window is created with SDL_WINDOW_HIGH_PIXEL_DENSITY, so its drawable is
 * the display's native pixel grid. SDL_SetRenderScale(density, density) then
 * maps a POINT coordinate space onto that grid, where density is
 * SDL_GetWindowPixelDensity() - 1.5 on a KDE desktop set to 150%.
 *
 * That render scale is the only place the desktop scale is applied. Nothing
 * below multiplies by SDL_GetWindowDisplayScale(), SDL_GetWindowPixelDensity()
 * or a content scale again, which is what would produce the classic scale^2
 * "everything is bigger than the rest of the OS" result. Every constant in
 * this file is a point, directly comparable to the point sizes a native
 * toolkit uses, and mouse coordinates arrive in the same units so they need no
 * conversion.
 *
 * Font atlases are authored at twice their design point size, so at density 2
 * they draw 1:1 and at lower densities they downscale rather than blur upward.
 */

/* Type scale, in points. UI_TEXT_PT matches the KDE default of 10pt at 96dpi
 * once the desktop scale is applied, so body text lands at the same size as a
 * native dialog's. */
#define UI_TEXT_PT 12.5f
#define UI_SMALL_PT 11.0f
#define UI_LABEL_PT 10.5f
#define UI_TITLE_PT 17.0f
#define UI_MONO_PT 11.0f

/* Spacing scale. Every gap between two controls comes from here, so nothing
 * can end up touching. */
#define UI_MARGIN 18.0f
#define UI_GAP 8.0f
#define UI_SECTION_GAP 16.0f
#define UI_PAD 12.0f
#define UI_ROW_H 30.0f
#define UI_BUTTON_H 28.0f
#define UI_BUTTON_PAD 14.0f
#define UI_RADIUS 1.0f

/* PALETTE
 *
 * Sourced from the desktop, never hardcoded, so a dark session does not get a
 * glaring light window. Order of preference:
 *
 *   1. ~/.config/kdeglobals - KDE's real palette, so the loader picks up the
 *      user's actual colour scheme and accent rather than a generic two-tone
 *      guess. Plain file parsing, no dependency.
 *   2. The XDG portal's org.freedesktop.appearance/color-scheme flag, queried
 *      by shelling out to gdbus the same way the backends shell out to
 *      kscreen-doctor. Gives light or dark on non-KDE desktops.
 *   3. A built-in light scheme.
 *
 * Everything else is derived from those few colours so the result stays
 * coherent, and the derived text colours are contrast-corrected against the
 * surface they sit on - a red or green tuned for white is unreadable on a dark
 * panel otherwise. */
typedef struct {
    SDL_Color background, surface, button_face, border;
    SDL_Color text, muted, label;
    SDL_Color accent, accent_dark, accent_text;
    SDL_Color selection, hover, strip, scrim;
    SDL_Color ok, bad;
    SDL_Color danger_face, danger_hover, danger_border;
    SDL_Color disabled_face, disabled_text;
    bool dark;
} Palette;

static Palette pal;

static SDL_Color rgb(int r, int g, int b)
{
    SDL_Color c;
    c.r = (Uint8)(r < 0 ? 0 : (r > 255 ? 255 : r));
    c.g = (Uint8)(g < 0 ? 0 : (g > 255 ? 255 : g));
    c.b = (Uint8)(b < 0 ? 0 : (b > 255 ? 255 : b));
    c.a = 255;
    return c;
}

static SDL_Color mix(SDL_Color a, SDL_Color b, float t)
{
    return rgb((int)(a.r + (b.r - a.r) * t + 0.5f),
               (int)(a.g + (b.g - a.g) * t + 0.5f),
               (int)(a.b + (b.b - a.b) * t + 0.5f));
}

static float channel_linear(Uint8 value)
{
    float v = (float)value / 255.0f;
    return v <= 0.04045f ? v / 12.92f : SDL_powf((v + 0.055f) / 1.055f, 2.4f);
}

static float luminance(SDL_Color c)
{
    return 0.2126f * channel_linear(c.r) + 0.7152f * channel_linear(c.g) +
           0.0722f * channel_linear(c.b);
}

static float contrast_ratio(SDL_Color a, SDL_Color b)
{
    float la = luminance(a) + 0.05f, lb = luminance(b) + 0.05f;
    return la > lb ? la / lb : lb / la;
}

/* Nudge a foreground toward white or black until it is legible on its
 * background. Applied to the states that are easiest to get wrong: dimmed
 * secondary text, disabled labels, and the status colours. */
static SDL_Color ensure_contrast(SDL_Color foreground, SDL_Color background, float wanted)
{
    SDL_Color target = luminance(background) < 0.5f ? rgb(255, 255, 255) : rgb(0, 0, 0);
    SDL_Color result = foreground;
    for (int step = 0; step < 20; step++) {
        if (contrast_ratio(result, background) >= wanted) break;
        result = mix(result, target, 0.1f);
    }
    return result;
}

static bool parse_kde_colour(const char *value, SDL_Color *out)
{
    int r = 0, g = 0, b = 0;
    if (!value || SDL_sscanf(value, "%d,%d,%d", &r, &g, &b) != 3) return false;
    *out = rgb(r, g, b);
    return true;
}

/* Minimal INI reader for the handful of keys the palette needs. */
static bool kdeglobals_value(const char *text, const char *group, const char *key,
                             char *value, size_t value_size)
{
    const char *cursor = strstr(text, group);
    size_t key_length = strlen(key);
    if (!cursor) return false;
    cursor = strchr(cursor, '\n');
    while (cursor) {
        const char *line = ++cursor;
        const char *end = strchr(line, '\n');
        if (*line == '[') return false;
        if (!SDL_strncmp(line, key, key_length) && line[key_length] == '=') {
            const char *start = line + key_length + 1;
            if (!end) end = start + strlen(start);
            while (end > start && (end[-1] == '\r' || end[-1] == ' ')) end--;
            if (end <= start) return false;
            SDL_snprintf(value, value_size, "%.*s", (int)(end - start), start);
            return true;
        }
        cursor = end;
    }
    return false;
}

static char *read_whole_file(const char *path, long *length_out)
{
    FILE *file = fopen(path, "rb");
    long length;
    char *text;
    if (!file) return NULL;
    if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) <= 0 ||
        length > 4 * 1024 * 1024 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    text = SDL_malloc((size_t)length + 1);
    if (!text) { fclose(file); return NULL; }
    if (fread(text, 1, (size_t)length, file) != (size_t)length) {
        fclose(file);
        SDL_free(text);
        return NULL;
    }
    fclose(file);
    text[length] = '\0';
    if (length_out) *length_out = length;
    return text;
}

static void kdeglobals_path(char *out, size_t out_size)
{
    const char *config = getenv("XDG_CONFIG_HOME");
    const char *home = getenv("HOME");
    if (config && config[0]) SDL_snprintf(out, out_size, "%s/kdeglobals", config);
    else if (home && home[0]) SDL_snprintf(out, out_size, "%s/.config/kdeglobals", home);
    else SDL_strlcpy(out, "/dev/null", out_size);
}

/* 1 = prefer dark, 2 = prefer light, 0 = no preference. */
static int portal_colour_scheme(void)
{
    static const char *const argv[] = {
        "gdbus", "call", "--session", "--dest", "org.freedesktop.portal.Desktop",
        "--object-path", "/org/freedesktop/portal/desktop",
        "--method", "org.freedesktop.portal.Settings.Read",
        "org.freedesktop.appearance", "color-scheme", NULL};
    char output[512];
    const char *found;
    if (!tool_exists("gdbus")) return 0;
    if (run_capture(argv, output, sizeof(output)) != 0) return 0;
    found = strstr(output, "uint32");
    return found ? SDL_atoi(found + 6) : 0;
}

static void derive_palette(bool dark)
{
    pal.dark = dark;
    pal.border = mix(pal.surface, pal.text, dark ? 0.22f : 0.16f);
    pal.hover = mix(pal.surface, pal.text, 0.07f);
    pal.selection = mix(pal.surface, pal.accent, dark ? 0.30f : 0.18f);
    pal.strip = mix(pal.background, pal.accent, dark ? 0.14f : 0.08f);
    pal.accent_dark = dark ? mix(pal.accent, rgb(255, 255, 255), 0.16f)
                           : mix(pal.accent, rgb(0, 0, 0), 0.18f);
    pal.accent_text = contrast_ratio(rgb(255, 255, 255), pal.accent) >=
                      contrast_ratio(rgb(0, 0, 0), pal.accent)
                          ? rgb(255, 255, 255) : rgb(20, 22, 26);
    pal.scrim = dark ? rgb(0, 0, 0) : rgb(18, 22, 30);
    pal.scrim.a = dark ? 150 : 120;
    pal.ok = ensure_contrast(dark ? rgb(94, 208, 143) : rgb(31, 157, 85), pal.strip, 4.5f);
    pal.bad = ensure_contrast(dark ? rgb(255, 130, 120) : rgb(218, 74, 65), pal.strip, 4.5f);
    pal.danger_face = mix(pal.button_face, pal.bad, dark ? 0.18f : 0.10f);
    pal.danger_hover = mix(pal.button_face, pal.bad, dark ? 0.30f : 0.18f);
    pal.danger_border = mix(pal.button_face, pal.bad, dark ? 0.50f : 0.35f);
    pal.disabled_face = mix(pal.button_face, pal.background, 0.55f);
    pal.disabled_text = ensure_contrast(mix(pal.surface, pal.text, 0.40f), pal.disabled_face, 2.6f);
    pal.muted = ensure_contrast(pal.muted, pal.surface, 4.0f);
    pal.label = ensure_contrast(mix(pal.muted, pal.background, 0.25f), pal.background, 3.4f);
}

static void load_default_palette(bool dark)
{
    if (dark) {
        pal.background = rgb(32, 35, 38);
        pal.surface = rgb(24, 27, 30);
        pal.button_face = rgb(44, 48, 53);
        pal.text = rgb(244, 246, 248);
        pal.muted = rgb(160, 168, 180);
        pal.accent = rgb(61, 174, 233);
    } else {
        pal.background = rgb(246, 248, 252);
        pal.surface = rgb(255, 255, 255);
        pal.button_face = rgb(255, 255, 255);
        pal.text = rgb(28, 34, 46);
        pal.muted = rgb(112, 122, 140);
        pal.accent = rgb(55, 96, 220);
    }
    derive_palette(dark);
}

/* Linux reads kdeglobals and falls back to the XDG portal. SDL already knows
 * the macOS appearance, so the whole parsing layer collapses to one call. */
static void load_palette(void)
{
    load_default_palette(SDL_GetSystemTheme() == SDL_SYSTEM_THEME_DARK);
}

/* Cheap enough to follow a live theme change: the periodic verify tick already
 * runs, so watch the file the palette came from and reload when it moves. */
static bool palette_source_changed(void)
{
    static SDL_SystemTheme last = SDL_SYSTEM_THEME_UNKNOWN;
    SDL_SystemTheme now = SDL_GetSystemTheme();
    if (now == last) return false;
    last = now;
    return true;
}

static void fill_rect(float x, float y, float w, float h, SDL_Color color)
{
    SDL_FRect rect = {x, y, w, h};
    SDL_SetRenderDrawColor(app.renderer, color.r, color.g, color.b, color.a);
    SDL_RenderFillRect(app.renderer, &rect);
}

static void frame_rect(float x, float y, float w, float h, SDL_Color color)
{
    SDL_FRect rect = {x, y, w, h};
    SDL_SetRenderDrawColor(app.renderer, color.r, color.g, color.b, color.a);
    SDL_RenderRect(app.renderer, &rect);
}

/* ------------------------------------------------------------------- text */

static bool build_font_textures(void)
{
    for (int face = 0; face < PGEN_FACE_COUNT; face++) {
        const PgenFace *info = &pgen_font_faces[face];
        size_t count = (size_t)info->atlas_width * (size_t)info->atlas_height;
        SDL_Surface *surface = SDL_CreateSurface(info->atlas_width, info->atlas_height,
                                                 SDL_PIXELFORMAT_RGBA32);
        uint32_t *pixels;
        if (!surface) return false;
        pixels = (uint32_t *)surface->pixels;
        /* White glyphs with the baked coverage in alpha; the draw colour comes
         * from the texture colour modulation. */
        for (size_t index = 0; index < count; index++) {
            unsigned value = 0;
            const char *hex = info->alpha_hex + index * 2;
            for (int digit = 0; digit < 2; digit++) {
                char c = hex[digit];
                value = (value << 4) |
                        (unsigned)(c >= 'a' ? c - 'a' + 10 : (c >= 'A' ? c - 'A' + 10 : c - '0'));
            }
            pixels[(index / (size_t)info->atlas_width) * (size_t)(surface->pitch / 4) +
                   (index % (size_t)info->atlas_width)] = 0x00ffffffu | ((uint32_t)value << 24);
        }
        app.font_texture[face] = SDL_CreateTextureFromSurface(app.renderer, surface);
        SDL_DestroySurface(surface);
        if (!app.font_texture[face]) return false;
        SDL_SetTextureScaleMode(app.font_texture[face], SDL_SCALEMODE_LINEAR);
        SDL_SetTextureBlendMode(app.font_texture[face], SDL_BLENDMODE_BLEND);
    }
    return true;
}

static float text_width(PgenFaceId face, float points, const char *text)
{
    const PgenFace *info = &pgen_font_faces[face];
    float scale = points / info->design_size;
    float width = 0;
    for (const unsigned char *cursor = (const unsigned char *)text; *cursor; cursor++) {
        int code = *cursor;
        if (code < PGEN_FONT_FIRST_CHAR || code > PGEN_FONT_LAST_CHAR) code = '?';
        width += info->glyphs[code - PGEN_FONT_FIRST_CHAR].advance;
    }
    return width * scale;
}

static float line_height(PgenFaceId face, float points)
{
    const PgenFace *info = &pgen_font_faces[face];
    return info->line_height * (points / info->design_size);
}

/* x,y is the top-left of the text box; the baseline is derived from the face. */
static float draw_text(float x, float y, PgenFaceId face, float points, SDL_Color color,
                       const char *text)
{
    const PgenFace *info = &pgen_font_faces[face];
    float scale = points / info->design_size;
    float baseline = y + info->ascent * scale;
    float pen = x;
    SDL_SetTextureColorMod(app.font_texture[face], color.r, color.g, color.b);
    SDL_SetTextureAlphaMod(app.font_texture[face], color.a);
    for (const unsigned char *cursor = (const unsigned char *)text; *cursor; cursor++) {
        int code = *cursor;
        const PgenGlyph *glyph;
        if (code < PGEN_FONT_FIRST_CHAR || code > PGEN_FONT_LAST_CHAR) code = '?';
        glyph = &info->glyphs[code - PGEN_FONT_FIRST_CHAR];
        if (glyph->width > 0 && glyph->height > 0) {
            SDL_FRect source = {(float)glyph->x, 0.0f, (float)glyph->width, (float)glyph->height};
            SDL_FRect target = {pen + (float)glyph->bearing_x * scale,
                                baseline - (float)glyph->bearing_y * scale,
                                (float)glyph->width * scale, (float)glyph->height * scale};
            SDL_RenderTexture(app.renderer, app.font_texture[face], &source, &target);
        }
        pen += glyph->advance * scale;
    }
    return pen - x;
}

/* Shorten to fit, keeping the tail of a path because the file name matters
 * more than the directory it sits in. */
static void draw_text_clipped(float x, float y, PgenFaceId face, float points, SDL_Color color,
                              const char *text, float max_width)
{
    char buffer[1024];
    size_t length = strlen(text);
    if (max_width <= 0) return;
    if (text_width(face, points, text) <= max_width) {
        draw_text(x, y, face, points, color, text);
        return;
    }
    if (strchr(text, '/')) {
        for (size_t drop = 1; drop < length; drop++) {
            SDL_snprintf(buffer, sizeof(buffer), "...%s", text + drop);
            if (text_width(face, points, buffer) <= max_width) {
                draw_text(x, y, face, points, color, buffer);
                return;
            }
        }
    } else {
        for (size_t keep = length; keep > 0; keep--) {
            SDL_snprintf(buffer, sizeof(buffer), "%.*s...", (int)(keep - 1), text);
            if (text_width(face, points, buffer) <= max_width) {
                draw_text(x, y, face, points, color, buffer);
                return;
            }
        }
    }
}

/* Word wrap on the available width and on explicit newlines. Returns the
 * height used, so the caller can size the block it sits in. */
static float draw_paragraph(float x, float y, PgenFaceId face, float points, SDL_Color color,
                            const char *text, float max_width, int max_lines, bool measure_only)
{
    char line[512];
    const char *cursor = text;
    float step = line_height(face, points);
    int drawn = 0;
    while (*cursor && drawn < max_lines) {
        size_t length = 0, best = 0;
        while (cursor[length] && cursor[length] != '\n') {
            size_t candidate = length + 1;
            if (candidate >= sizeof(line)) break;
            SDL_snprintf(line, sizeof(line), "%.*s", (int)candidate, cursor);
            if (text_width(face, points, line) > max_width && best > 0) break;
            if (text_width(face, points, line) > max_width && best == 0) { length = candidate; break; }
            if (cursor[length] == ' ') best = length;
            length = candidate;
        }
        if (cursor[length] && cursor[length] != '\n' && best > 0) length = best;
        SDL_snprintf(line, sizeof(line), "%.*s", (int)length, cursor);
        if (!measure_only) draw_text(x, y + (float)drawn * step, face, points, color, line);
        drawn++;
        cursor += length;
        while (*cursor == ' ') cursor++;
        if (*cursor == '\n') cursor++;
    }
    return (float)drawn * step;
}

/* ---------------------------------------------------------------- controls */

typedef enum { BUTTON_NORMAL = 0, BUTTON_PRIMARY, BUTTON_DANGER } ButtonKind;

static float button_width(const char *label)
{
    return text_width(PGEN_FACE_REGULAR, UI_TEXT_PT, label) + UI_BUTTON_PAD * 2.0f;
}

/* While the prompt is up, only its own controls take input. */
static bool input_blocked(void)
{
    return app.prompt != PROMPT_NONE && !app.in_modal;
}

static bool button(float x, float y, float w, const char *label, ButtonKind kind, bool enabled)
{
    float h = UI_BUTTON_H;
    bool hovered = enabled && !input_blocked() &&
                   app.mouse_x >= x && app.mouse_x <= x + w &&
                   app.mouse_y >= y && app.mouse_y <= y + h;
    SDL_Color face, border, label_color;
    if (!enabled) {
        face = pal.disabled_face;
        border = pal.border;
        label_color = pal.disabled_text;
    } else if (kind == BUTTON_PRIMARY) {
        face = hovered ? pal.accent_dark : pal.accent;
        border = face;
        label_color = pal.accent_text;
    } else if (kind == BUTTON_DANGER) {
        face = hovered ? pal.danger_hover : pal.danger_face;
        border = pal.danger_border;
        label_color = pal.bad;
    } else {
        face = hovered ? mix(pal.button_face, pal.text, 0.08f) : pal.button_face;
        border = pal.border;
        label_color = pal.text;
    }
    fill_rect(x, y, w, h, face);
    frame_rect(x, y, w, h, border);
    draw_text(x + (w - text_width(PGEN_FACE_REGULAR, UI_TEXT_PT, label)) * 0.5f,
              y + (h - line_height(PGEN_FACE_REGULAR, UI_TEXT_PT)) * 0.5f,
              PGEN_FACE_REGULAR, UI_TEXT_PT, label_color, label);
    return hovered && app.mouse_clicked;
}

/* A row of buttons that wraps to the next line instead of running past the
 * right edge when the window is narrow. */
typedef struct {
    float origin_x, x, y, limit_x;
    float row_height;
} ButtonFlow;

static void flow_begin(ButtonFlow *flow, float x, float y, float limit_x)
{
    flow->origin_x = flow->x = x;
    flow->y = y;
    flow->limit_x = limit_x;
    flow->row_height = 0;
}

static bool flow_button(ButtonFlow *flow, const char *label, ButtonKind kind, bool enabled)
{
    float w = button_width(label);
    bool pressed;
    if (flow->x > flow->origin_x && flow->x + w > flow->limit_x) {
        flow->x = flow->origin_x;
        flow->y += UI_BUTTON_H + UI_GAP;
    }
    pressed = button(flow->x, flow->y, w, label, kind, enabled);
    flow->x += w + UI_GAP;
    flow->row_height = flow->y + UI_BUTTON_H;
    return pressed;
}

static float flow_bottom(const ButtonFlow *flow)
{
    return flow->row_height;
}

/* Card background plus its uppercase section label, matching the Windows
 * loader's language of a small semibold label above a bordered white panel. */
static float section_label(float x, float y, const char *label)
{
    draw_text(x, y, PGEN_FACE_BOLD, UI_LABEL_PT, pal.label, label);
    return line_height(PGEN_FACE_BOLD, UI_LABEL_PT) + 5.0f;
}

static bool row_hit(float x, float y, float w, float h)
{
    if (input_blocked()) return false;
    return app.mouse_x >= x && app.mouse_x <= x + w && app.mouse_y >= y && app.mouse_y <= y + h;
}

static const char *profile_kind_tag(ProfileKind kind)
{
    switch (kind) {
    case PROFILE_KIND_KDE_HDR: return "HDR";
    case PROFILE_KIND_WINDOWS_HDR: return "HDR + MHC2";
    case PROFILE_KIND_WINDOWS_SDR: return "SDR + MHC2";
    case PROFILE_KIND_SDR: return "SDR";
    default: return "ICC";
    }
}

/* SDL runs this from the event pump once the desktop portal's file chooser
 * closes, so it is safe to touch the UI state directly. */
static void dialog_callback(void *userdata, const char *const *files, int filter)
{
    (void)userdata; (void)filter;
    app.dialog_open = false;
    if (!files || !files[0]) return;
    SDL_strlcpy(app.selected_profile, files[0], sizeof(app.selected_profile));
    rescan_profiles();
    verify_profile();
}

static void draw_ui(void)
{
    DisplayEntry *display = selected_display();
    ProfileEntry *profile = selected_profile();
    char line[1024];
    const float left = UI_MARGIN;
    const float width = app.window_w - UI_MARGIN * 2.0f;
    const float right = left + width;
    float y = UI_MARGIN - app.scroll_y;
    bool busy = SDL_GetAtomicInt(&app.worker_busy) != 0;

    fill_rect(0, 0, app.window_w, app.window_h, pal.background);
    fill_rect(0, 0, app.window_w, 3.0f, pal.accent);
    if (width < 120.0f) return;

    /* --- header ------------------------------------------------------- */
    /* y already starts at UI_MARGIN, and content_height adds the same margin
     * below the last row, so the window is inset equally on all four sides
     * from one constant. Do not add per-section insets here. */
    draw_text(left, y, PGEN_FACE_TITLE, UI_TITLE_PT, pal.text, APP_NAME);
    y += line_height(PGEN_FACE_TITLE, UI_TITLE_PT) + 2.0f;
    draw_text_clipped(left, y, PGEN_FACE_REGULAR, UI_SMALL_PT, pal.muted,
                      "Install a PGenerator+ ICC profile and keep it applied to the display, "
                      "in SDR and HDR.", width);
    y += line_height(PGEN_FACE_REGULAR, UI_SMALL_PT) + 1.0f;
    /* On a KWin session colord is not the mechanism in use, so it is not
     * mentioned at all - naming a daemon that plays no part here is noise. */
    if (app.kwin_driving)
        SDL_strlcpy(line, "macOS uses a single ColorSync profile per display, for both SDR and HDR content.", sizeof(line));
    else if (app.have_colormgr)
        SDL_snprintf(line, sizeof(line), "Profiles are applied by ColorSync  -  %d display(s)",
                     app.colord_display_devices);
    else
        SDL_strlcpy(line, "No displays were reported. Press Refresh.", sizeof(line));
    draw_text_clipped(left, y, PGEN_FACE_REGULAR, UI_SMALL_PT, pal.label, line, width);
    y += line_height(PGEN_FACE_REGULAR, UI_SMALL_PT) + UI_SECTION_GAP;

    /* --- display ------------------------------------------------------ */
    y += section_label(left, y, "DISPLAY");
    {
        int visible = app.display_count < DISPLAY_ROWS ? app.display_count : DISPLAY_ROWS;
        float rows = (float)(visible > 0 ? visible : 1);
        float card_h = rows * UI_ROW_H + UI_PAD;
        fill_rect(left, y, width, card_h, pal.surface);
        frame_rect(left, y, width, card_h, pal.border);
        for (int row = 0; row < visible; row++) {
            int index = app.display_scroll + row;
            float row_y = y + UI_PAD * 0.5f + (float)row * UI_ROW_H;
            DisplayEntry *entry;
            bool hovered;
            if (index >= app.display_count) break;
            entry = &app.displays[index];
            hovered = row_hit(left + 1.0f, row_y, width - 2.0f, UI_ROW_H);
            if (index == app.display_index)
                fill_rect(left + 1.0f, row_y, width - 2.0f, UI_ROW_H, pal.selection);
            else if (hovered)
                fill_rect(left + 1.0f, row_y, width - 2.0f, UI_ROW_H, pal.hover);
            if (hovered && app.mouse_clicked) {
                app.display_index = index;
                verify_profile();
            }
            {
                /* The monitor's own name leads, exactly as the Patch Companion
                 * labels it; the connector and backend are the detail line. */
                char detail[256];
                float profile_w;
                SDL_snprintf(detail, sizeof(detail), "%s  -  %s  -  %s", entry->name,
                             entry->hdr ? "HDR on" : "HDR off",
                             entry->from_kwin ? "ColorSync" : "unknown");
                profile_w = text_width(PGEN_FACE_REGULAR, UI_SMALL_PT, detail);
                draw_text_clipped(left + UI_PAD, row_y + 2.0f, PGEN_FACE_BOLD, UI_TEXT_PT,
                                  pal.text, display_title(entry),
                                  width - UI_PAD * 2.0f - profile_w - UI_GAP * 2.0f);
                draw_text(right - UI_PAD - profile_w, row_y + 3.0f, PGEN_FACE_REGULAR,
                          UI_SMALL_PT, pal.muted, detail);
                draw_text_clipped(left + UI_PAD, row_y + 2.0f + line_height(PGEN_FACE_BOLD, UI_TEXT_PT),
                                  PGEN_FACE_MONO, UI_MONO_PT, pal.muted,
                                  entry->icc_path[0] ? entry->icc_path : "no ICC profile applied",
                                  width - UI_PAD * 2.0f);
            }
        }
        if (app.display_count == 0)
            draw_text(left + UI_PAD, y + UI_PAD, PGEN_FACE_REGULAR, UI_TEXT_PT, pal.bad,
                      "No display reported. Press Refresh.");
        y += card_h + UI_SECTION_GAP;
    }

    /* --- selected profile --------------------------------------------- */
    y += section_label(left, y, "ICC PROFILE");
    {
        float browse_w = button_width("Browse");
        float field_w = width - browse_w - UI_GAP;
        if (field_w < 80.0f) field_w = width;
        fill_rect(left, y, field_w, UI_BUTTON_H, pal.surface);
        frame_rect(left, y, field_w, UI_BUTTON_H, pal.border);
        if (app.selected_profile[0])
            draw_text_clipped(left + UI_PAD * 0.75f,
                              y + (UI_BUTTON_H - line_height(PGEN_FACE_MONO, UI_MONO_PT)) * 0.5f,
                              PGEN_FACE_MONO, UI_MONO_PT, pal.text, app.selected_profile,
                              field_w - UI_PAD * 1.5f);
        else
            draw_text(left + UI_PAD * 0.75f,
                      y + (UI_BUTTON_H - line_height(PGEN_FACE_REGULAR, UI_TEXT_PT)) * 0.5f,
                      PGEN_FACE_REGULAR, UI_TEXT_PT, pal.muted, "No profile selected");
        if (field_w < width) {
            if (button(right - browse_w, y, browse_w, "Browse", BUTTON_NORMAL,
                       !app.dialog_open && !busy)) {
                static const SDL_DialogFileFilter filters[] = {
                    {"Color profiles", "icc;icm"}, {"All files", "*"}
                };
                app.dialog_open = true;
                SDL_ShowOpenFileDialog(dialog_callback, NULL, app.window, filters, 2, NULL, false);
            }
        }
        y += UI_BUTTON_H + 5.0f;
        if (profile) {
            SDL_snprintf(line, sizeof(line), "%s%s", profile_kind_label(profile->kind),
                         profile->has_mhc2 ? "  -  carries an MHC2 calibration stage" : "");
            draw_text_clipped(left, y, PGEN_FACE_REGULAR, UI_SMALL_PT, pal.muted, line, width);
            y += line_height(PGEN_FACE_REGULAR, UI_SMALL_PT);
        }
        y += UI_SECTION_GAP;
    }

    /* --- profiles found ------------------------------------------------ */
    y += section_label(left, y, "PROFILES ON THIS COMPUTER");
    {
        int visible = app.profile_count < PROFILE_ROWS ? app.profile_count : PROFILE_ROWS;
        float row_h = UI_ROW_H - 6.0f;
        float rows = (float)(visible > 0 ? visible : 1);
        float card_h = rows * row_h + UI_PAD;
        fill_rect(left, y, width, card_h, pal.surface);
        frame_rect(left, y, width, card_h, pal.border);
        for (int row = 0; row < visible; row++) {
            int index = app.profile_scroll + row;
            float row_y = y + UI_PAD * 0.5f + (float)row * row_h;
            ProfileEntry *entry;
            bool hovered;
            float tag_w;
            const char *tag;
            if (index >= app.profile_count) break;
            entry = &app.profiles[index];
            tag = profile_kind_tag(entry->kind);
            tag_w = text_width(PGEN_FACE_REGULAR, UI_SMALL_PT, tag);
            hovered = row_hit(left + 1.0f, row_y, width - 2.0f, row_h);
            if (!strcmp(entry->path, app.selected_profile))
                fill_rect(left + 1.0f, row_y, width - 2.0f, row_h, pal.selection);
            else if (hovered)
                fill_rect(left + 1.0f, row_y, width - 2.0f, row_h, pal.hover);
            if (hovered && app.mouse_clicked) {
                SDL_strlcpy(app.selected_profile, entry->path, sizeof(app.selected_profile));
                app.profile_index = index;
                verify_profile();
            }
            /* The right column is a short type tag, never a second copy of the
             * file name. */
            draw_text_clipped(left + UI_PAD, row_y + 2.0f, PGEN_FACE_REGULAR, UI_TEXT_PT,
                              pal.text, entry->name,
                              width - UI_PAD * 2.0f - tag_w - UI_GAP * 2.0f);
            draw_text(right - UI_PAD - tag_w, row_y + 3.0f, PGEN_FACE_REGULAR, UI_SMALL_PT,
                      pal.muted, tag);
        }
        if (app.profile_count == 0)
            draw_text(left + UI_PAD, y + UI_PAD, PGEN_FACE_REGULAR, UI_TEXT_PT, pal.muted,
                      "No .icc or .icm files found. Use Browse.");
        y += card_h;
        if (app.profile_count > PROFILE_ROWS) {
            SDL_snprintf(line, sizeof(line), "Showing %d-%d of %d. Scroll over the list for more.",
                         app.profile_scroll + 1,
                         SDL_min(app.profile_scroll + PROFILE_ROWS, app.profile_count),
                         app.profile_count);
            y += 4.0f;
            draw_text_clipped(left, y, PGEN_FACE_REGULAR, UI_SMALL_PT, pal.muted, line, width);
            y += line_height(PGEN_FACE_REGULAR, UI_SMALL_PT);
        }
        y += UI_SECTION_GAP;
    }

    /* --- status strip -------------------------------------------------- */
    {
        char heading[64], detail[768];
        StatusLevel level;
        SDL_Color dot;
        float text_x = left + UI_PAD + 10.0f + UI_GAP;
        float text_w = width - (text_x - left) - UI_PAD;
        float detail_h;
        SDL_LockMutex(app.lock);
        level = app.status_level;
        SDL_strlcpy(heading, app.status_heading, sizeof(heading));
        SDL_strlcpy(detail, app.status_detail, sizeof(detail));
        SDL_UnlockMutex(app.lock);
        dot = level == STATUS_OK ? pal.ok : (level == STATUS_PENDING ? pal.accent : pal.bad);
        detail_h = draw_paragraph(0, 0, PGEN_FACE_REGULAR, UI_SMALL_PT, pal.text, detail,
                                  text_w, 4, true);
        {
            float strip_h = UI_PAD + line_height(PGEN_FACE_BOLD, UI_LABEL_PT) + 3.0f +
                            detail_h + UI_PAD;
            /* A tinted strip with an accent edge, deliberately lighter than the
             * white panels above so it reads as status, not another field. */
            fill_rect(left, y, width, strip_h, pal.strip);
            fill_rect(left, y, 3.0f, strip_h, dot);
            fill_rect(left + UI_PAD, y + UI_PAD + 2.0f, 9.0f, 9.0f, dot);
            draw_text(text_x, y + UI_PAD, PGEN_FACE_BOLD, UI_LABEL_PT, dot, heading);
            draw_paragraph(text_x, y + UI_PAD + line_height(PGEN_FACE_BOLD, UI_LABEL_PT) + 3.0f,
                           PGEN_FACE_REGULAR, UI_SMALL_PT, pal.text, detail, text_w, 4, false);
            y += strip_h + UI_SECTION_GAP;
        }
    }

    /* --- actions ------------------------------------------------------- */
    {
        bool have_profile = app.selected_profile[0] != '\0';
        bool have_display = display != NULL;
        ButtonFlow flow;
        /* Setup and install actions first, grouped together. */
        /* Apply below does the copying itself, so there is no user-scope
         * install button left to press: it would change nothing visible. What
         * remains here is genuinely optional. */
        y += section_label(left, y, "ADVANCED");
        flow_begin(&flow, left, y, right);
        if (flow_button(&flow, "Refresh", BUTTON_NORMAL, !busy)) start_action(ACTION_REFRESH);
        if (flow_button(&flow, "Copy to system folder (all users)", BUTTON_NORMAL,
                        have_profile && !busy))
            start_action(ACTION_INSTALL_SYSTEM);
        if (flow_button(&flow, "Display settings", BUTTON_NORMAL, !busy))
            start_action(ACTION_OPEN_SETTINGS);
        y = flow_bottom(&flow) + UI_SECTION_GAP;

        /* A rule separates the destructive action and the primary one from the
         * setup strip, so Clear is never a neighbour of Install. */
        fill_rect(left, y, width, 1.0f, pal.border);
        y += UI_SECTION_GAP;
        {
            const char *apply_label = busy ? "Working..." : "Apply to display";
            float apply_w = button_width(apply_label);
            float clear_w = button_width("Clear profile");
            bool stacked = clear_w + apply_w + UI_GAP * 2.0f > width;
            if (button(left, y, clear_w, "Clear profile", BUTTON_DANGER, have_display && !busy))
                start_action(ACTION_CLEAR);
            if (stacked) y += UI_BUTTON_H + UI_GAP;
            if (button(right - apply_w, y, apply_w, apply_label, BUTTON_PRIMARY,
                       have_profile && have_display && !busy))
                start_action(ACTION_APPLY);
            y += UI_BUTTON_H;
        }
        y += UI_GAP;
        {
            float link_h = line_height(PGEN_FACE_REGULAR, UI_SMALL_PT);
            /* Only the colord fallback has anything to come back to; on a KWin
             * session there is no colour-system decision left to make. */
            if (!app.kwin_driving) {
                const char *link = "Colour system status";
                float link_w = text_width(PGEN_FACE_REGULAR, UI_SMALL_PT, link);
                bool hovered = row_hit(left, y, link_w, link_h);
                draw_text(left, y, PGEN_FACE_REGULAR, UI_SMALL_PT,
                          hovered ? pal.accent : pal.label, link);
                fill_rect(left, y + link_h - 1.0f, link_w, 1.0f,
                          hovered ? pal.accent : pal.border);
                if (hovered && app.mouse_clicked) {
                    PromptKind kind = colour_system_prompt();
                    if (kind != PROMPT_NONE) app.prompt = kind;
                }
            }
            SDL_snprintf(line, sizeof(line), "v%s", APP_VERSION);
            draw_text(right - text_width(PGEN_FACE_REGULAR, UI_SMALL_PT, line), y,
                      PGEN_FACE_REGULAR, UI_SMALL_PT, pal.label, line);
            y += link_h;
        }
    }

    /* Content that does not fit scrolls rather than being clipped away. The
     * trailing UI_MARGIN is the bottom inset: it makes the fit-to-content pass
     * leave that much space under the last row, and it keeps the same gap
     * reachable at the end of the scroll range when the window is short. */
    app.content_height = y + app.scroll_y + UI_MARGIN;
    if (app.content_height > app.window_h) {
        float track = app.window_h - 8.0f;
        float thumb = track * (app.window_h / app.content_height);
        float travel = track - thumb;
        float maximum = app.content_height - app.window_h;
        float offset = maximum > 0 ? (app.scroll_y / maximum) * travel : 0;
        fill_rect(app.window_w - 6.0f, 4.0f + offset, 3.0f, thumb, pal.border);
    }
}

/* ------------------------------------------------------------------ prompt */

static void prompt_text(PromptKind kind, const char **heading, const char **body,
                        const char **accept)
{
    switch (kind) {
    case PROMPT_COLORD_MISSING:
        *heading = "No colour management was found";
        *body = "This session has neither KDE's kscreen-doctor nor colord, so "
                "there is nothing that can apply a display profile. Install "
                "colord and colord-kde?\nThis needs administrator rights and "
                "runs: apt install colord colord-kde";
        *accept = "Install colord";
        break;
    case PROMPT_NO_BACKEND:
        *heading = "No display could be reached";
        *body = "colord is installed but reports no display device, and this "
                "session has no KWin to fall back on, so a profile cannot be "
                "applied yet.\nOn KDE, kscreen-doctor ships with Plasma and is "
                "used instead. On X11, colord needs its session helper running "
                "(colord-kde on KDE, gnome-settings-daemon on GNOME) before it "
                "registers a display.";
        *accept = NULL;
        break;
    default:
        *heading = "";
        *body = "";
        *accept = NULL;
        break;
    }
}

static void draw_prompt(void)
{
    const char *heading, *body, *accept;
    float card_w, card_x, card_y, card_h, text_w, body_h;
    float button_y;
    if (app.prompt == PROMPT_NONE) return;
    prompt_text(app.prompt, &heading, &body, &accept);
    card_w = app.window_w - UI_MARGIN * 2.0f;
    if (card_w > 460.0f) card_w = 460.0f;
    text_w = card_w - UI_PAD * 2.0f;
    body_h = draw_paragraph(0, 0, PGEN_FACE_REGULAR, UI_TEXT_PT, pal.text, body, text_w, 12, true);
    card_h = UI_PAD + line_height(PGEN_FACE_BOLD, UI_TEXT_PT) + UI_GAP + body_h +
             UI_SECTION_GAP + UI_BUTTON_H + UI_PAD;
    card_x = (app.window_w - card_w) * 0.5f;
    card_y = (app.window_h - card_h) * 0.5f;
    if (card_y < UI_MARGIN) card_y = UI_MARGIN;

    /* Dim the page behind so the prompt reads as modal. */
    SDL_SetRenderDrawBlendMode(app.renderer, SDL_BLENDMODE_BLEND);
    fill_rect(0, 0, app.window_w, app.window_h, pal.scrim);
    fill_rect(card_x, card_y, card_w, card_h, pal.surface);
    frame_rect(card_x, card_y, card_w, card_h, pal.border);
    fill_rect(card_x, card_y, card_w, 3.0f, pal.accent);

    draw_text_clipped(card_x + UI_PAD, card_y + UI_PAD, PGEN_FACE_BOLD, UI_TEXT_PT,
                      pal.text, heading, text_w);
    draw_paragraph(card_x + UI_PAD,
                   card_y + UI_PAD + line_height(PGEN_FACE_BOLD, UI_TEXT_PT) + UI_GAP,
                   PGEN_FACE_REGULAR, UI_TEXT_PT, pal.text, body, text_w, 12, false);
    button_y = card_y + card_h - UI_PAD - UI_BUTTON_H;

    app.in_modal = true;
    if (accept) {
        float accept_w = button_width(accept);
        float dismiss_w = button_width("Not now");
        if (button(card_x + card_w - UI_PAD - accept_w, button_y, accept_w, accept,
                   BUTTON_PRIMARY, true)) {
            app.prompt = PROMPT_NONE;
            app.colord_prompt_done = true;
            start_action(ACTION_INSTALL_COLORD);
        }
        if (button(card_x + card_w - UI_PAD - accept_w - UI_GAP - dismiss_w, button_y,
                   dismiss_w, "Not now", BUTTON_NORMAL, true)) {
            app.prompt = PROMPT_NONE;
            app.colord_prompt_done = true;
        }
    } else {
        float close_w = button_width("Got it");
        if (button(card_x + card_w - UI_PAD - close_w, button_y, close_w, "Got it",
                   BUTTON_PRIMARY, true)) {
            app.prompt = PROMPT_NONE;
            app.colord_prompt_done = true;
        }
    }
    app.in_modal = false;
}

/* -------------------------------------------------------------- SDL callbacks */

static void update_metrics(void)
{
    int point_w = 0, point_h = 0;
    app.density = SDL_GetWindowPixelDensity(app.window);
    if (!(app.density > 0.0f)) app.density = 1.0f;
    SDL_GetWindowSize(app.window, &point_w, &point_h);
    app.window_w = (float)point_w;
    app.window_h = (float)point_h;
    /* The one and only scale application: point space -> native pixels. */
    SDL_SetRenderScale(app.renderer, app.density, app.density);
}

static void create_tray(void);

SDL_AppResult SDL_AppInit(void **appstate, int argc, char *argv[])
{
    SDL_zero(app);
    if (!SDL_Init(SDL_INIT_VIDEO)) return SDL_APP_FAILURE;
    app.lock = SDL_CreateMutex();
    if (!app.lock) return SDL_APP_FAILURE;
    app.window = SDL_CreateWindow(APP_NAME, WINDOW_DEFAULT_W, WINDOW_DEFAULT_H,
                                  SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
    if (!app.window) return SDL_APP_FAILURE;
    SDL_SetWindowMinimumSize(app.window, WINDOW_MIN_W, WINDOW_MIN_H);
    {
        SDL_Surface *icon = SDL_CreateSurfaceFrom(PGEN_COMPANION_ICON_WIDTH,
                                                  PGEN_COMPANION_ICON_HEIGHT,
                                                  SDL_PIXELFORMAT_RGBA32,
                                                  (void *)pgen_companion_icon_rgba,
                                                  PGEN_COMPANION_ICON_WIDTH * 4);
        if (icon) {
            SDL_SetWindowIcon(app.window, icon);
            SDL_DestroySurface(icon);
        }
    }
    app.renderer = SDL_CreateRenderer(app.window, NULL);
    if (!app.renderer) return SDL_APP_FAILURE;
    SDL_SetRenderVSync(app.renderer, 1);
    SDL_SetRenderDrawBlendMode(app.renderer, SDL_BLENDMODE_BLEND);
    load_palette();
    if (!build_font_textures()) return SDL_APP_FAILURE;
    update_metrics();

    /* A profile path on the command line preselects it, so a freshly
     * downloaded profile can be handed straight to the loader. --apply also
     * applies it at once and then leaves the window open on the result. */
    {
        bool apply_now = false;
        char requested_display[192] = "";
        for (int index = 1; index < argc; index++) {
            const char *argument = argv[index];
            if (!argument || !argument[0]) continue;
            if (!strcmp(argument, "--apply")) { apply_now = true; continue; }
            if (!strcmp(argument, "--apply-silent") ||
                !strcmp(argument, "--apply-from-companion")) {
                apply_now = true;
                app.silent_apply = true;
                continue;
            }
            /* Preferred over --display=: a UUID is stable across reboots and
             * unambiguous when two identical panels are attached, which a
             * display name is not. --display= stays as the fallback and for
             * the human-readable status text. */
            if (!strncmp(argument, "--display-uuid=", 15)) {
                SDL_strlcpy(requested_display, argument + 15, sizeof(requested_display));
                continue;
            }
            if (!strncmp(argument, "--display=", 10)) {
                if (!requested_display[0])
                    SDL_strlcpy(requested_display, argument + 10, sizeof(requested_display));
                continue;
            }
            if (!strncmp(argument, "--result=", 9)) {
                SDL_strlcpy(app.result_path, argument + 9, sizeof(app.result_path));
                continue;
            }
            if (argument[0] == '-') continue;
            SDL_strlcpy(app.selected_profile, argument, sizeof(app.selected_profile));
        }
        set_status(STATUS_PENDING, "STARTING", "Looking for displays and profiles.");
        snapshot_sdl_displays();
        refresh_everything();
        if (requested_display[0]) {
            for (int index = 0; index < app.display_count; index++) {
                if (!strcmp(app.displays[index].name, requested_display) ||
                    !strcmp(app.displays[index].model, requested_display) ||
                    !strcmp(display_title(&app.displays[index]), requested_display)) {
                    app.display_index = index;
                    break;
                }
            }
        }
        if (!app.selected_profile[0] && app.profile_count > 0)
            SDL_strlcpy(app.selected_profile, app.profiles[0].path, sizeof(app.selected_profile));
        verify_profile();
        if (apply_now && app.selected_profile[0]) {
            app.silent_started = true;
            if (app.silent_apply) SDL_HideWindow(app.window);
            start_action(ACTION_APPLY);
        }
    }
    /* Checked once here, not per frame, and never raised again once answered. */
    if (app.silent_apply) app.colord_prompt_done = true;
    if (!app.colord_prompt_done) app.prompt = colour_system_prompt();
    app.auto_reapply = !app.silent_apply;
    /* A one-shot companion install has no business planting a menu-bar item. */
    if (!app.silent_apply) create_tray();
    app.next_verify_ms = SDL_GetTicks() + VERIFY_INTERVAL_MS;
    *appstate = &app;
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event)
{
    (void)appstate;
    switch (event->type) {
    case SDL_EVENT_QUIT:
        return SDL_APP_SUCCESS;
    case SDL_EVENT_WINDOW_RESIZED:
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    case SDL_EVENT_WINDOW_DISPLAY_CHANGED:
        update_metrics();
        break;
    case SDL_EVENT_DISPLAY_ADDED:
    case SDL_EVENT_DISPLAY_REMOVED:
    case SDL_EVENT_DISPLAY_MOVED:
    case SDL_EVENT_DISPLAY_ORIENTATION:
        snapshot_sdl_displays();
        /* These are exactly the events after which macOS drops a display's
         * profile, so check now rather than waiting out the 5s tick. */
        app.next_verify_ms = SDL_GetTicks();
        break;
    case SDL_EVENT_KEY_DOWN:
        if (event->key.key == SDLK_ESCAPE) {
            if (app.prompt != PROMPT_NONE) {
                app.prompt = PROMPT_NONE;
                app.colord_prompt_done = true;
                break;
            }
            return SDL_APP_SUCCESS;
        }
        if (event->key.key == SDLK_F5) start_action(ACTION_REFRESH);
        /* Keyboard scrolling, so a short or tiled window can still reach the
         * last row without a mouse wheel. */
        {
            float maximum = app.content_height - app.window_h;
            float page = app.window_h - UI_MARGIN * 2.0f;
            float move = 0.0f;
            bool absolute = false;
            if (event->key.key == SDLK_DOWN) move = 40.0f;
            else if (event->key.key == SDLK_UP) move = -40.0f;
            else if (event->key.key == SDLK_PAGEDOWN) move = page;
            else if (event->key.key == SDLK_PAGEUP) move = -page;
            else if (event->key.key == SDLK_END) { app.scroll_y = maximum; absolute = true; }
            else if (event->key.key == SDLK_HOME) { app.scroll_y = 0.0f; absolute = true; }
            if (move != 0.0f || absolute) {
                if (!absolute) app.scroll_y += move;
                if (maximum < 0.0f) maximum = 0.0f;
                if (app.scroll_y > maximum) app.scroll_y = maximum;
                if (app.scroll_y < 0.0f) app.scroll_y = 0.0f;
            }
        }
        break;
    case SDL_EVENT_MOUSE_MOTION:
        app.mouse_x = event->motion.x;
        app.mouse_y = event->motion.y;
        break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
        if (event->button.button == SDL_BUTTON_LEFT) {
            app.mouse_x = event->button.x;
            app.mouse_y = event->button.y;
            app.mouse_down = true;
        }
        break;
    case SDL_EVENT_MOUSE_BUTTON_UP:
        if (event->button.button == SDL_BUTTON_LEFT && app.mouse_down) {
            app.mouse_down = false;
            app.mouse_clicked = true;
        }
        break;
    case SDL_EVENT_MOUSE_WHEEL: {
        /* Over a list the wheel pages that list; anywhere else it scrolls the
         * window, which is what keeps a short window usable. */
        int limit;
        bool over_list = false;
        if (app.profile_count > PROFILE_ROWS || app.display_count > DISPLAY_ROWS) {
            /* Lists sit in the upper half; the exact bands are recomputed each
             * frame, so approximate by the selected card regions. */
            over_list = false;
        }
        if (!over_list) {
            float maximum = app.content_height - app.window_h;
            app.scroll_y -= event->wheel.y * 40.0f;
            if (maximum < 0) maximum = 0;
            if (app.scroll_y > maximum) app.scroll_y = maximum;
            if (app.scroll_y < 0) app.scroll_y = 0;
            if (maximum <= 0 && app.profile_count > PROFILE_ROWS) {
                limit = app.profile_count - PROFILE_ROWS;
                app.profile_scroll -= (int)event->wheel.y;
                if (app.profile_scroll > limit) app.profile_scroll = limit;
                if (app.profile_scroll < 0) app.profile_scroll = 0;
            }
        }
        break;
    }
    default:
        break;
    }
    return SDL_APP_CONTINUE;
}

/* The Companion polls this file rather than watching us, so it is the whole
 * of the contract: "ok" if the profile is genuinely the display's active
 * profile, "error: <reason>" otherwise. The Companion checks only the first
 * two characters, so the reason is free to be as long as it needs to be.
 *
 * Verified against WindowServer, not against the ColorSync device database:
 * an assignment can be recorded without being adopted, and reporting that as
 * success is exactly the kind of quiet wrongness this tool exists to avoid. */
static void write_companion_result(void)
{
    DisplayEntry *display;
    FILE *file;
    bool applied;

    if (!app.result_path[0] || app.result_written) return;
    app.result_written = true;

    display = selected_display();
    applied = display && app.selected_profile[0] &&
              pgen_macos_windowserver_uses(display->name, app.selected_profile);

    file = fopen(app.result_path, "wb");
    if (!file) return;
    if (applied) {
        fputs("ok", file);
    } else {
        fprintf(file, "error: %s",
                app.status_detail[0] ? app.status_detail
                                     : "macOS did not adopt the profile for this display");
    }
    fclose(file);
}

/* Reassociate a profile macOS has dropped, but only once it is clear that it
 * really has been dropped and only at a rate that cannot become a loop.
 *
 * The check is against WindowServer rather than the ColorSync device database,
 * because the database keeps reporting the assignment it recorded even after
 * the compositor has stopped honouring it - which is precisely the failure
 * being healed. */
static void maybe_self_heal(void)
{
    DisplayEntry *display = NULL;
    uint64_t now = SDL_GetTicks();
    char message[512] = "";

    if (!app.auto_reapply || app.silent_apply) return;
    /* Only an assignment this loader made. Keying this to the list selection
     * instead made the startup preselection - the first profile found in a
     * scan of the system directories - look like a dropped assignment, and the
     * healer would push it onto the display seconds after launch, calibration
     * nobody requested. */
    if (!app.applied_profile[0] || !app.applied_display[0]) return;
    if (app.reapply_failures >= 3) return;

    /* The display it was applied to, not whichever one the list is showing. */
    for (int index = 0; index < app.display_count; index++) {
        if (!strcmp(app.displays[index].name, app.applied_display)) {
            display = &app.displays[index];
            break;
        }
    }
    if (!display) return;

    if (pgen_macos_windowserver_uses(display->name, app.applied_profile)) {
        app.mismatch_count = 0;
        app.reapply_attempted = false;
        app.reapply_failures = 0;
        return;
    }

    /* One mismatch is not evidence: a display in the middle of a mode change
     * reports whatever it likes for a moment. */
    if (++app.mismatch_count < 2) return;
    if (app.reapply_attempted && now - app.last_reapply_ms < 60000) return;

    app.reapply_attempted = true;
    app.last_reapply_ms = now;

    /* Reassociate only. Never reinstall from the timer - the file is already
     * where it belongs, and reinstalling would be a write nobody asked for. */
    if (pgen_macos_assign_profile(display->name, app.applied_profile,
                                  message, sizeof(message))) {
        SDL_Log("macOS: reapplied %s to %s after %d consecutive mismatches",
                app.applied_profile, display->model, app.mismatch_count);
        app.mismatch_count = 0;
    } else {
        app.reapply_failures++;
        SDL_Log("macOS: could not reapply %s to %s (attempt %d of 3): %s",
                app.applied_profile, display->model, app.reapply_failures,
                message[0] ? message : "no detail reported");
        if (app.reapply_failures >= 3)
            set_status(STATUS_BAD, "REAPPLY GAVE UP",
                       "macOS keeps dropping this profile and three attempts to "
                       "reapply it failed. Apply it by hand, or check whether the "
                       "display changed mode.");
    }
}

/* Green when the selected profile is the one WindowServer is using, red
 * otherwise - the same two-state signal the Windows tray gives. Drawn rather
 * than shipped as an asset, because two flat squares are not worth a file. */
static SDL_Surface *tray_icon_surface(bool healthy)
{
    SDL_Surface *surface = SDL_CreateSurface(22, 22, SDL_PIXELFORMAT_RGBA32);
    if (!surface) return NULL;
    SDL_FillSurfaceRect(surface, NULL,
                        SDL_MapSurfaceRGBA(surface, 0, 0, 0, 0));
    SDL_Rect body = {3, 3, 16, 16};
    if (healthy) SDL_FillSurfaceRect(surface, &body, SDL_MapSurfaceRGBA(surface, 46, 160, 67, 255));
    else         SDL_FillSurfaceRect(surface, &body, SDL_MapSurfaceRGBA(surface, 218, 54, 51, 255));
    return surface;
}

static void SDLCALL tray_show_window(void *userdata, SDL_TrayEntry *entry)
{
    (void)userdata; (void)entry;
    SDL_ShowWindow(app.window);
    SDL_RaiseWindow(app.window);
}

static void SDLCALL tray_reapply_now(void *userdata, SDL_TrayEntry *entry)
{
    (void)userdata; (void)entry;
    start_action(ACTION_APPLY);
}

static void SDLCALL tray_verify_now(void *userdata, SDL_TrayEntry *entry)
{
    (void)userdata; (void)entry;
    app.next_verify_ms = SDL_GetTicks();
}

static void SDLCALL tray_toggle_auto(void *userdata, SDL_TrayEntry *entry)
{
    (void)userdata;
    app.auto_reapply = SDL_GetTrayEntryChecked(entry);
}

static void SDLCALL tray_open_settings(void *userdata, SDL_TrayEntry *entry)
{
    (void)userdata; (void)entry;
    pgen_macos_open_display_settings();
}

static void SDLCALL tray_quit(void *userdata, SDL_TrayEntry *entry)
{
    (void)userdata; (void)entry;
    SDL_Event quit = {0};
    quit.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&quit);
}

static void create_tray(void)
{
    SDL_Surface *icon = tray_icon_surface(false);
    SDL_TrayMenu *menu;

    app.tray = SDL_CreateTray(icon, APP_NAME);
    if (icon) SDL_DestroySurface(icon);
    if (!app.tray) {
        /* Not fatal - the window still works - but silence here would look
         * like the menu-bar item was never meant to exist. */
        SDL_Log("macOS: could not create the menu-bar item: %s", SDL_GetError());
        return;
    }
    SDL_Log("macOS: menu-bar item created");

    menu = SDL_CreateTrayMenu(app.tray);
    if (!menu) return;

    app.tray_status = SDL_InsertTrayEntryAt(menu, -1, "Checking...", SDL_TRAYENTRY_DISABLED);
    SDL_InsertTrayEntryAt(menu, -1, NULL, 0);   /* separator */
    SDL_SetTrayEntryCallback(SDL_InsertTrayEntryAt(menu, -1, "Open Profile Loader", 0),
                             tray_show_window, NULL);
    SDL_SetTrayEntryCallback(SDL_InsertTrayEntryAt(menu, -1, "Reapply now", 0),
                             tray_reapply_now, NULL);
    SDL_SetTrayEntryCallback(SDL_InsertTrayEntryAt(menu, -1, "Verify now", 0),
                             tray_verify_now, NULL);
    app.tray_auto = SDL_InsertTrayEntryAt(menu, -1, "Automatically reapply",
                                          SDL_TRAYENTRY_CHECKBOX);
    if (app.tray_auto) {
        SDL_SetTrayEntryChecked(app.tray_auto, app.auto_reapply);
        SDL_SetTrayEntryCallback(app.tray_auto, tray_toggle_auto, NULL);
    }
    SDL_InsertTrayEntryAt(menu, -1, NULL, 0);
    SDL_SetTrayEntryCallback(SDL_InsertTrayEntryAt(menu, -1, "Display settings...", 0),
                             tray_open_settings, NULL);
    SDL_InsertTrayEntryAt(menu, -1, NULL, 0);
    SDL_SetTrayEntryCallback(SDL_InsertTrayEntryAt(menu, -1, "Quit", 0),
                             tray_quit, NULL);
}

/* Called after each verify, so the menu bar carries the answer without the
 * window having to be open. */
static void update_tray(void)
{
    static StatusLevel last = (StatusLevel)-1;
    if (!app.tray) return;
    if (app.tray_status) {
        char label[192];
        SDL_snprintf(label, sizeof(label), "%s - %s", app.status_heading,
                     app.status_detail[0] ? app.status_detail : "no detail");
        char *newline = strchr(label, '\n');
        if (newline) *newline = '\0';
        SDL_SetTrayEntryLabel(app.tray_status, label);
    }
    if (app.status_level != last) {
        SDL_Surface *icon = tray_icon_surface(app.status_level == STATUS_OK);
        if (icon) { SDL_SetTrayIcon(app.tray, icon); SDL_DestroySurface(icon); }
        last = app.status_level;
    }
}

SDL_AppResult SDL_AppIterate(void *appstate)
{
    (void)appstate;
    if (app.silent_apply && app.silent_started &&
        !SDL_GetAtomicInt(&app.worker_busy)) {
        write_companion_result();
        return SDL_APP_SUCCESS;
    }
    SDL_SetRenderDrawColor(app.renderer, pal.background.r, pal.background.g,
                           pal.background.b, 255);
    SDL_RenderClear(app.renderer);
    draw_ui();
    draw_prompt();
    SDL_RenderPresent(app.renderer);
    /* The first frame is what finally measures the content, so fit the window
     * to it once rather than shipping a guessed default height that clips as
     * soon as a list or a status message grows. The user's own resizing is
     * never touched afterwards. */
    if (!app.auto_sized && app.content_height > 0.0f) {
        SDL_Rect usable;
        float wanted = app.content_height;
        app.auto_sized = true;
        if (SDL_GetDisplayUsableBounds(SDL_GetDisplayForWindow(app.window), &usable)) {
            float limit = (float)usable.h - 60.0f;
            if (wanted > limit) wanted = limit;
        }
        if (wanted < WINDOW_MIN_H) wanted = WINDOW_MIN_H;
        if (SDL_fabsf(wanted - app.window_h) > 1.0f) {
            SDL_SetWindowSize(app.window, (int)app.window_w, (int)(wanted + 0.5f));
            update_metrics();
        }
    }
    app.mouse_clicked = false;
    /* Keep reporting whether the profile is still the active one, the same
     * continuous verification the Windows loader performs. */
    if (!SDL_GetAtomicInt(&app.worker_busy) && SDL_GetTicks() >= app.next_verify_ms) {
        app.next_verify_ms = SDL_GetTicks() + VERIFY_INTERVAL_MS;
        if (palette_source_changed()) load_palette();
        snapshot_sdl_displays();
        maybe_self_heal();
        update_tray();
        start_action(ACTION_REFRESH);
    }
    return SDL_APP_CONTINUE;
}

void SDL_AppQuit(void *appstate, SDL_AppResult result)
{
    (void)appstate; (void)result;
    if (app.tray) SDL_DestroyTray(app.tray);
    if (app.worker) SDL_WaitThread(app.worker, NULL);
    for (int face = 0; face < PGEN_FACE_COUNT; face++)
        if (app.font_texture[face]) SDL_DestroyTexture(app.font_texture[face]);
    if (app.lock) SDL_DestroyMutex(app.lock);
}
