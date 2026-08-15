/* ColorSync round-trip probe.
 *
 * Not shipped. This exists to settle, before anything is built on top of it,
 * exactly what ColorSyncDeviceSetCustomProfiles wants and whether an
 * assignment made through it is actually adopted by WindowServer.
 *
 * The header documents profileInfo as a flat dictionary whose keys are
 * ProfileIDs - or the literal kColorSyncDeviceDefaultProfileID - and whose
 * values are CFURLRefs, with kCFNull to fall back to the factory profile.
 * That is a different shape from the nested one used when *registering* a
 * device, and getting it wrong is the single most likely way to waste a day
 * on the Profile Loader.
 *
 *   clang -fobjc-arc -framework Foundation -framework AppKit \
 *         -framework CoreGraphics -framework ColorSync \
 *         -o pgen-colorsync-probe pgen-colorsync-probe.m
 *
 *   ./pgen-colorsync-probe list                  read-only: every display
 *   ./pgen-colorsync-probe assign <id> <p.icc>   assign, verify, report
 *   ./pgen-colorsync-probe restore <id>          back to the factory profile
 *
 * `assign` prints the prior profile URL first so it can always be put back by
 * hand, and `restore` is the documented kCFNull path.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>

static NSString *display_name(CGDirectDisplayID display)
{
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue == display) return screen.localizedName;
    }
    return @"(no NSScreen)";
}

/* The profile the OS is currently applying, by URL. Custom assignments win
 * over factory ones, which is the same precedence the Displays pane shows. */
static NSURL *current_profile_url(CGDirectDisplayID display, NSString **origin)
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

        id defaultID = profiles[(__bridge NSString *)kColorSyncDeviceDefaultProfileID];
        id entry = defaultID ? profiles[defaultID] : nil;
        if (!entry && profiles.count >= 1) {
            /* "Presence of this key is not required if there is only one
             * profile" - fall back to whatever single entry is present. */
            for (id key in profiles) {
                if ([key isEqual:(__bridge NSString *)kColorSyncDeviceDefaultProfileID]) continue;
                entry = profiles[key];
                break;
            }
        }
        NSURL *url = nil;
        if ([entry isKindOfClass:NSDictionary.class])
            url = entry[(__bridge NSString *)kColorSyncDeviceProfileURL];
        else if ([entry isKindOfClass:NSURL.class])
            url = entry;
        if (url) {
            if (origin) *origin = bucket;
            return url;
        }
    }
    return nil;
}

/* WindowServer's own view, which is the one that actually matters: the device
 * database can hold an assignment the compositor has not adopted.
 *
 * CGColorSpaceCopyName returns nothing useful for a display colour space - it
 * is unnamed for both of this machine's displays - so identity has to come
 * from the ICC payload itself. Size plus a cheap checksum is enough to tell
 * "WindowServer is using the profile we just assigned" from "it isn't", which
 * is the only question being asked. */
static NSString *windowserver_profile_digest(CGDirectDisplayID display)
{
    CGColorSpaceRef space = CGDisplayCopyColorSpace(display);
    if (!space) return @"(no colour space)";
    CFDataRef icc = CGColorSpaceCopyICCData(space);
    CGColorSpaceRelease(space);
    if (!icc) return @"(no ICC payload)";

    const uint8_t *bytes = CFDataGetBytePtr(icc);
    CFIndex length = CFDataGetLength(icc);
    uint32_t sum = 2166136261u;                 /* FNV-1a, plenty for identity */
    for (CFIndex index = 0; index < length; index++) {
        sum ^= bytes[index];
        sum *= 16777619u;
    }
    NSString *result = [NSString stringWithFormat:@"%ld bytes, fnv1a %08x",
                                                  (long)length, sum];
    CFRelease(icc);
    return result;
}

/* The same digest for a profile on disk, so the two can be compared directly. */
static NSString *file_profile_digest(NSURL *url)
{
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) return @"(unreadable)";
    const uint8_t *bytes = data.bytes;
    uint32_t sum = 2166136261u;
    for (NSUInteger index = 0; index < data.length; index++) {
        sum ^= bytes[index];
        sum *= 16777619u;
    }
    return [NSString stringWithFormat:@"%lu bytes, fnv1a %08x",
                                      (unsigned long)data.length, sum];
}

static void report(CGDirectDisplayID display)
{
    NSString *origin = nil;
    NSURL *url = current_profile_url(display, &origin);
    NSString *bucket = [origin hasSuffix:@"CustomProfiles"] ? @"custom" : @"factory";

    printf("  display 0x%08x  %s\n", display, display_name(display).UTF8String);
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (uuid) {
        NSString *text = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
        printf("    uuid          %s\n", text.UTF8String);
        CFRelease(uuid);
    }
    printf("    profile       %s%s\n",
           url ? url.path.UTF8String : "(none registered)",
           url ? [NSString stringWithFormat:@"  [%@]", bucket].UTF8String : "");
    printf("    on disk       %s\n", file_profile_digest(url).UTF8String);
    printf("    WindowServer  %s\n", windowserver_profile_digest(display).UTF8String);

    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue != display) continue;
        printf("    EDR headroom  %.3f now, %.3f potential\n",
               screen.maximumExtendedDynamicRangeColorComponentValue,
               screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
        printf("    bounds        %.0fx%.0f at (%.0f,%.0f)\n",
               screen.frame.size.width, screen.frame.size.height,
               screen.frame.origin.x, screen.frame.origin.y);
    }
    printf("\n");
}

static int list_displays(void)
{
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) {
        fprintf(stderr, "CGGetOnlineDisplayList failed\n");
        return 1;
    }
    printf("\n%u display(s)\n\n", count);
    for (uint32_t index = 0; index < count; index++) report(displays[index]);
    return 0;
}

static int set_profile(CGDirectDisplayID display, NSURL *url)
{
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) {
        fprintf(stderr, "no UUID for display 0x%08x\n", display);
        return 1;
    }
    /* The flat shape the header documents for SetCustomProfiles: ProfileID ->
     * CFURLRef. kCFNull in place of the URL resets to the factory profile. */
    NSDictionary *info = @{
        (__bridge NSString *)kColorSyncDeviceDefaultProfileID:
            url ? (id)url : (id)[NSNull null],
    };
    bool ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid,
                                               (__bridge CFDictionaryRef)info);
    CFRelease(uuid);
    printf("  ColorSyncDeviceSetCustomProfiles -> %s\n", ok ? "true" : "false");
    if (!ok) return 1;

    /* WindowServer picks the change up asynchronously. */
    [NSThread sleepForTimeInterval:1.0];
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *command = argc > 1 ? @(argv[1]) : @"list";

        if ([command isEqualToString:@"list"]) return list_displays();

        if (argc < 3) {
            fprintf(stderr, "usage: %s assign <displayID> <profile.icc>\n"
                            "       %s restore <displayID>\n", argv[0], argv[0]);
            return 2;
        }
        CGDirectDisplayID display = (CGDirectDisplayID)strtoul(argv[2], NULL, 0);

        if ([command isEqualToString:@"restore"]) {
            printf("\nbefore:\n"); report(display);
            int result = set_profile(display, nil);
            printf("after:\n"); report(display);
            return result;
        }

        if ([command isEqualToString:@"assign"]) {
            if (argc < 4) { fprintf(stderr, "need a profile path\n"); return 2; }
            NSURL *url = [NSURL fileURLWithPath:@(argv[3])];
            CFErrorRef error = NULL;
            ColorSyncProfileRef profile =
                ColorSyncProfileCreateWithURL((__bridge CFURLRef)url, &error);
            if (!profile) {
                fprintf(stderr, "not a readable ICC profile: %s\n",
                        [(__bridge NSError *)error localizedDescription].UTF8String);
                return 1;
            }
            CFRelease(profile);

            printf("\nbefore:\n"); report(display);
            int result = set_profile(display, url);
            printf("after:\n"); report(display);
            printf("  restore with: %s restore 0x%08x\n\n", argv[0], display);
            return result;
        }

        fprintf(stderr, "unknown command: %s\n", command.UTF8String);
        return 2;
    }
}
