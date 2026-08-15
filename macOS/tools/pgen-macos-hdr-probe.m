/* HDR PQ passthrough probe - experiment "Spike B".
 *
 * Not shipped. This is the experiment that decides whether a macOS HDR path is
 * worth building at all.
 *
 * SDL3's Metal renderer accepts only SDL_COLORSPACE_SRGB and
 * SDL_COLORSPACE_SRGB_LINEAR and fails renderer creation for anything else, so
 * PQ cannot come through the Patch Companion's shared rendering path. An HDR
 * build would need a bespoke CAMetalLayer, exactly the way Windows uses a
 * bespoke DXGI swapchain. That is 400-600 lines of new code, and it is only
 * worth writing if macOS actually puts our PQ codes on the wire unchanged.
 *
 * So: build the probe, not the feature.
 *
 * The layer is configured the way an HDR Companion would configure it -
 * MTLPixelFormatBGR10A2Unorm, kCGColorSpaceITUR_2100_PQ,
 * wantsExtendedDynamicRangeContent - and filled with one constant 10-bit
 * triple at a time. CAMetalLayer documents that with EDRMetadata nil, "samples
 * will be rendered without tone mapping", which is the passthrough we want;
 * whether that survives WindowServer's compositing is the open question, and
 * only a meter can answer it.
 *
 *   clang -fobjc-arc -arch arm64 -framework Cocoa -framework Metal \
 *         -framework QuartzCore -framework CoreGraphics \
 *         -o pgen-macos-hdr-probe pgen-macos-hdr-probe.m
 *
 * ---------------------------------------------------------------------------
 * The three conditions, and why the second one is decisive
 *
 *   A  baseline, SDR brightness slider at 50%
 *   B  identical, slider at 100%
 *   C  identical, --metadata-max 600
 *
 * PASS - macOS passes PQ through - needs ALL of:
 *   1. measured cd/m2 tracks the PQ target within +/-5% or +/-0.5 nits,
 *      whichever is greater, from 1 nit up to the display's measured peak
 *   2. the response is monotonic across every step
 *   3. A and B differ by less than 2%.  This is the test that cannot be
 *      faked: if WindowServer is tone-mapping, the map is a function of the
 *      current EDR headroom, and headroom moves with the brightness slider.
 *      A tone-mapper cannot pass this.
 *   4. A and C differ by less than 2% below 600 nits
 *   5. the BT.2020 primaries measure at BT.2020 chromaticity, not P3
 *
 * FAIL if: a smooth compressive curve appears (the classic signature - a
 * 100-nit target reading about 75, a 1000-nit target reading about 450), or
 * A and B differ, or the primaries land on P3.
 *
 * AMBIGUOUS - passthrough holds on the built-in XDR panel in a pinned
 * reference mode but not on an external HDR display, or vice versa. Treat that
 * as FAIL for shipping, but write it down: it may later justify supporting HDR
 * only in a specific reference mode, with a hard check for it.
 *
 * On FAIL the Companion keeps refusing HDR runs, which is what it does today
 * and what the Linux build does when it cannot get a native HDR surface.
 * Silently profiling a tone-mapped conversion is the one outcome that must not
 * happen.
 *
 * ---------------------------------------------------------------------------
 * Running it
 *
 *   ./pgen-macos-hdr-probe --list
 *   ./pgen-macos-hdr-probe --display 0                 walk the default steps
 *   ./pgen-macos-hdr-probe --display 0 --hold 100      hold 100 nits, measure
 *   ./pgen-macos-hdr-probe --display 0 --no-metadata   condition with EDR
 *                                                      metadata omitted
 *   ./pgen-macos-hdr-probe --display 0 --metadata-max 600     condition C
 *   ./pgen-macos-hdr-probe --display 0 --primaries     BT.2020 R, G, B
 *
 * Enable HDR for the display first. Each step prints the code and the nits it
 * is asking for; measure with `spotread -e -x` and compare.
 */

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* SMPTE ST 2084. Y is absolute luminance normalised to 10000 cd/m2. */
static double pq_from_nits(double nits)
{
    const double m1 = 2610.0 / 16384.0;
    const double m2 = 2523.0 / 4096.0 * 128.0;
    const double c1 = 3424.0 / 4096.0;
    const double c2 = 2413.0 / 4096.0 * 32.0;
    const double c3 = 2392.0 / 4096.0 * 32.0;
    double y = nits / 10000.0;
    if (y < 0.0) y = 0.0;
    double ym = pow(y, m1);
    return pow((c1 + c2 * ym) / (1.0 + c3 * ym), m2);
}

static double nits_from_pq(double signal)
{
    const double m1 = 2610.0 / 16384.0;
    const double m2 = 2523.0 / 4096.0 * 128.0;
    const double c1 = 3424.0 / 4096.0;
    const double c2 = 2413.0 / 4096.0 * 32.0;
    const double c3 = 2392.0 / 4096.0 * 32.0;
    double em = pow(signal, 1.0 / m2);
    double numerator = em - c1;
    if (numerator < 0.0) numerator = 0.0;
    return 10000.0 * pow(numerator / (c2 - c3 * em), 1.0 / m1);
}

/* Round-trip a luminance to the 10-bit code that carries it, and report what
 * that code actually means - the quantisation is part of the experiment, not
 * an inconvenience to hide. */
static unsigned code_for_nits(double nits, double *actual_nits)
{
    double signal = pq_from_nits(nits);
    unsigned code = (unsigned)lround(signal * 1023.0);
    if (code > 1023) code = 1023;
    if (actual_nits) *actual_nits = nits_from_pq((double)code / 1023.0);
    return code;
}

@interface ProbeView : NSView
@property(nonatomic) CAMetalLayer *metal;
@end

@implementation ProbeView
- (BOOL)wantsUpdateLayer { return YES; }
@end

static CGDirectDisplayID display_at_index(int wanted, NSScreen **screen_out)
{
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (wanted < 0 || wanted >= (int)screens.count) wanted = 0;
    NSScreen *screen = screens[wanted];
    if (screen_out) *screen_out = screen;
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    return (CGDirectDisplayID)number.unsignedIntValue;
}

/* Selecting by CGDirectDisplayID instead, which is what `list` prints.
 * NSScreen.screens and CGGetOnlineDisplayList are independently ordered, so an
 * index taken from one and applied to the other can silently pick the wrong
 * panel - and a patch shown on the wrong display looks exactly like a patch
 * the meter cannot see. Returns 0 when the id is not attached. */
static CGDirectDisplayID display_by_id(CGDirectDisplayID wanted, NSScreen **screen_out)
{
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue != wanted) continue;
        if (screen_out) *screen_out = screen;
        return wanted;
    }
    return 0;
}

static void list_displays(void)
{
    printf("\ndisplays:\n");
    NSUInteger index = 0;
    for (NSScreen *screen in NSScreen.screens) {
        printf("  [%lu] %-28s  EDR headroom %.2f now, %.2f potential%s\n",
               (unsigned long)index++,
               screen.localizedName.UTF8String,
               screen.maximumExtendedDynamicRangeColorComponentValue,
               screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
               screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
                   ? "" : "   (no EDR - not an HDR target)");
    }
    printf("\n");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        int display_index = 0;
        CGDirectDisplayID wanted_id = 0;
        double hold_nits = -1.0;
        int sdr_rgb[3] = {-1, -1, -1};
        /* 0 = split screen for a visual read, 1 = our Metal layer alone,
         * 2 = the sRGB control alone. The solo modes exist so a meter can
         * measure each configuration at the same physical spot, which turns a
         * judgement about colour into a chromaticity comparison. */
        int sdr_layout = 0;
        bool use_metadata = true;
        bool primaries_mode = false;
        double metadata_max = 1000.0, metadata_min = 0.005;
        double dwell = 0.0;                 /* 0 = wait for Return */

        /* Ten points across four decades, chosen at round luminances so the
         * pass/fail arithmetic is doable by eye at the meter. */
        double steps[] = {0.1, 1, 5, 10, 50, 100, 203, 400, 600, 1000};
        int step_count = 10;

        for (int index = 1; index < argc; index++) {
            if (!strcmp(argv[index], "--list")) { list_displays(); return 0; }
            else if (!strcmp(argv[index], "--display") && index + 1 < argc) {
                const char *value = argv[++index];
                char *end = NULL;
                long parsed = strtol(value, &end, 10);
                if (!end || *end || parsed < 0) {
                    fprintf(stderr, "\n'%s' is not a display index. Run --list.\n\n",
                            value);
                    return 2;
                }
                display_index = (int)parsed;
            }
            else if (!strcmp(argv[index], "--display-id") && index + 1 < argc) {
                const char *value = argv[++index];
                char *end = NULL;
                unsigned long parsed = strtoul(value, &end, 0);
                if (!end || *end || parsed == 0) {
                    fprintf(stderr, "\n'%s' is not a display id. Run --list.\n\n", value);
                    return 2;
                }
                wanted_id = (CGDirectDisplayID)parsed;
            }
            else if (!strcmp(argv[index], "--hold") && index + 1 < argc)
                hold_nits = atof(argv[++index]);
            else if (!strcmp(argv[index], "--no-metadata")) use_metadata = false;
            else if (!strcmp(argv[index], "--metadata-max") && index + 1 < argc)
                metadata_max = atof(argv[++index]);
            else if (!strcmp(argv[index], "--dwell") && index + 1 < argc)
                dwell = atof(argv[++index]);
            else if (!strcmp(argv[index], "--primaries")) primaries_mode = true;
            else if (!strcmp(argv[index], "--sdr") && index + 1 < argc)
                sscanf(argv[++index], "%d,%d,%d",
                       &sdr_rgb[0], &sdr_rgb[1], &sdr_rgb[2]);
            else if (!strcmp(argv[index], "--sdr-ours") && index + 1 < argc) {
                sdr_layout = 1;
                sscanf(argv[++index], "%d,%d,%d",
                       &sdr_rgb[0], &sdr_rgb[1], &sdr_rgb[2]);
            }
            else if (!strcmp(argv[index], "--sdr-control") && index + 1 < argc) {
                sdr_layout = 2;
                sscanf(argv[++index], "%d,%d,%d",
                       &sdr_rgb[0], &sdr_rgb[1], &sdr_rgb[2]);
            }
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSScreen *screen = nil;
        CGDirectDisplayID display;
        if (wanted_id) {
            display = display_by_id(wanted_id, &screen);
            if (!display) {
                fprintf(stderr, "\nDisplay 0x%08x is not attached. Run --list.\n\n",
                        wanted_id);
                return 2;
            }
        } else {
            display = display_at_index(display_index, &screen);
        }

        printf("\nprobe build  %s %s\n", __DATE__, __TIME__);
        printf("layer host   %s\n",
               sdr_rgb[0] >= 0 && sdr_layout == 1
                   ? "view's own layer (as SDL does)"
                   : sdr_layout == 2 ? "sRGB control layer"
                   : sdr_layout == 0 && sdr_rgb[0] >= 0 ? "sublayer (split view)"
                   : "view's own layer");
        printf("display      [%d] %s (0x%08x)\n", display_index,
               screen.localizedName.UTF8String, display);
        printf("EDR headroom %.3f now, %.3f potential\n",
               screen.maximumExtendedDynamicRangeColorComponentValue,
               screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
        if (screen.maximumPotentialExtendedDynamicRangeColorComponentValue <= 1.0)
            printf("WARNING: this display reports no EDR headroom. Enable HDR for it,\n"
                   "         or pick another display - results here mean nothing.\n");

        /* initWithContentRect:...screen: interprets the rect RELATIVE to that
         * screen's origin. Passing screen.frame - which is already in global
         * coordinates - together with screen: adds the origin twice, so the
         * window lands at double the intended offset and misses the display
         * entirely. It is invisible on the main display, whose origin is (0,0),
         * because doubling zero is still zero.
         *
         * Create it with no screen, then place it with global coordinates,
         * which is unambiguous. */
        NSWindow *window =
            [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0,
                                                             screen.frame.size.width,
                                                             screen.frame.size.height)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO
                                           screen:nil];
        [window setFrame:screen.frame display:NO];
        window.level = NSScreenSaverWindowLevel;
        window.backgroundColor = NSColor.blackColor;
        /* A window level alone is not enough when the probe is launched from a
         * background shell job: the app never becomes active, and the window
         * can end up behind whatever was already on screen or stranded on the
         * Space that was current when it opened. A patch the meter cannot see
         * is indistinguishable from a patch that was never drawn, so make the
         * window impossible to lose. */
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorIgnoresCycle;
        window.hidesOnDeactivate = NO;

        ProbeView *view = [[ProbeView alloc] initWithFrame:screen.frame];

        bool sdr_mode = sdr_rgb[0] >= 0;

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.framebufferOnly = NO;
        layer.frame = view.bounds;

        if (sdr_mode) {
            /* Exactly how SDL configures its layer for an ordinary SDR window:
             * 8-bit BGRA and colorspace left nil. CAMetalLayer documents nil as
             * "no colormatching occurs", and this mode is here to confirm that
             * behaviourally rather than take the header's word for it.
             *
             * Assign a permuted display profile first (see
             * make-permuted-profile.py). If a red fill still looks red, nothing
             * is converting our pixels and the Companion's whole SDR premise
             * holds. If it looks green, the premise is wrong and the port needs
             * rethinking before anything else. */
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.colorspace = NULL;
            layer.wantsExtendedDynamicRangeContent = NO;
        } else {
            layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
            layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            layer.wantsExtendedDynamicRangeContent = YES;
        }

        /* CAMetalLayer: "If non-nil, content may be tone mapped to match the
         * current display characteristics. If nil, samples will be rendered
         * without tone mapping." Both are worth measuring - if they differ,
         * that difference IS the tone mapper. */
        if (sdr_mode) {
            layer.EDRMetadata = nil;
            printf("SDR mode: 8-bit BGRA, layer colorspace nil (SDL's configuration)\n");
        } else if (use_metadata) {
            layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:(float)metadata_min
                                                               maxLuminance:(float)metadata_max
                                                         opticalOutputScale:100];
            printf("EDR metadata max %.0f nits, min %.4f nits\n",
                   metadata_max, metadata_min);
        } else {
            layer.EDRMetadata = nil;
            printf("EDR metadata omitted (no tone mapping, per CAMetalLayer)\n");
        }

        if (sdr_mode) {
            /* A positive control, and the reason this test can be trusted.
             *
             * The right half is an ordinary CoreAnimation layer with an
             * sRGB-tagged background colour, which WindowServer definitely
             * colour-manages. The left half is our Metal layer with a nil
             * colorspace. Under a deliberately permuted display profile the
             * two halves answer the question between them:
             *
             *   halves DIFFER   our layer is not colour-managed - the premise
             *                   holds, and the control proves the profile was
             *                   genuinely in the path
             *   both WRONG      our layer is colour-managed too - the premise
             *                   is wrong
             *   both RIGHT      nothing is being colour-managed, so the
             *                   profile never took. The test is invalid, not
             *                   passing - re-check the assignment
             *
             * Without the control, "both right" and "halves differ" look
             * identical from the left half alone. */
            if (sdr_layout == 1) {
                /* Match SDL exactly: SDL_Metal_CreateView returns a view whose
                 * layerClass IS CAMetalLayer, so the Metal layer is the view's
                 * OWN layer and gets its own surface.
                 *
                 * Hosting it as a SUBLAYER instead - which this did - puts its
                 * content through the window's colour-managed backing store on
                 * the way to the screen, so it is no longer measuring what the
                 * Companion actually does. That showed up as a partial shift
                 * toward the parent layer's colour, with luminance rising
                 * because a second colour was being added. */
                layer.frame = view.bounds;
                layer.opaque = YES;
                view.layer = layer;
            } else {
                CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGFloat components[4] = {sdr_rgb[0] / 255.0, sdr_rgb[1] / 255.0,
                                         sdr_rgb[2] / 255.0, 1.0};
                CGColorRef control = CGColorCreate(srgb, components);
                view.layer = [CALayer layer];
                view.layer.backgroundColor = control;
                CGColorRelease(control);
                CGColorSpaceRelease(srgb);

                if (sdr_layout == 0) {
                    /* The split view keeps the sublayer arrangement, so it is
                     * the less faithful of the two. Use --sdr-ours for anything
                     * being measured. */
                    CGRect half = view.bounds;
                    half.size.width /= 2.0;
                    layer.frame = half;
                    layer.opaque = YES;
                    [view.layer addSublayer:layer];
                }
                /* sdr_layout == 2 leaves the control layer alone, full screen. */
            }
        } else {
            view.layer = layer;
        }
        view.metal = layer;
        view.wantsLayer = YES;          /* after the layer, not before */
        window.contentView = view;

        {
            CGFloat scale = screen.backingScaleFactor;
            view.layer.contentsScale = scale;
            layer.contentsScale = scale;
            layer.drawableSize = CGSizeMake(layer.frame.size.width * scale,
                                            layer.frame.size.height * scale);
            printf("window       %.0fx%.0f at (%.0f,%.0f)\n",
                   window.frame.size.width, window.frame.size.height,
                   window.frame.origin.x, window.frame.origin.y);
            printf("metal layer  %.0fx%.0f, drawable %.0fx%.0f, scale %.1f\n",
                   layer.frame.size.width, layer.frame.size.height,
                   layer.drawableSize.width, layer.drawableSize.height, scale);
            if (layer.drawableSize.width < 1 || layer.drawableSize.height < 1)
                printf("WARNING: the Metal layer has no drawable size; nothing "
                       "can be presented\n");
        }

        [window makeKeyAndOrderFront:nil];
        /* orderFrontRegardless is the one that works for a process the user
         * never launched from the Dock. */
        [window orderFrontRegardless];
        if (@available(macOS 14.0, *)) [NSApp activate];
        else [NSApp activateIgnoringOtherApps:YES];

        id<MTLCommandQueue> queue = [layer.device newCommandQueue];

        /* Run this only after the first frames are up: the window server does
         * not list a window as on screen until it has been composited, so
         * asking during setup always reports a false absence. */
        void (^report_on_screen)(void) = ^{

            /* Ask the window server where this window actually ended up, rather
         * than where AppKit was asked to put it. "The window exists" and "the
         * window is visible on the display I meant" are different claims, and
         * only the second one matters when a meter is pointed at a panel. */
        {
            CGRect target = CGDisplayBounds(display);
            CGWindowID number = (CGWindowID)window.windowNumber;
            CFArrayRef list = CGWindowListCopyWindowInfo(
                kCGWindowListOptionIncludingWindow, number);
            bool found = false;
            for (NSDictionary *entry in (__bridge NSArray *)list) {
                CGRect where;
                if (!CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)entry[(id)kCGWindowBounds], &where))
                    continue;
                found = true;
                printf("on screen    %.0fx%.0f at (%.0f,%.0f), level %s, alpha %s\n",
                       where.size.width, where.size.height,
                       where.origin.x, where.origin.y,
                       [entry[(id)kCGWindowLayer] stringValue].UTF8String,
                       [entry[(id)kCGWindowAlpha] stringValue].UTF8String);
                printf("display is   %.0fx%.0f at (%.0f,%.0f)\n",
                       target.size.width, target.size.height,
                       target.origin.x, target.origin.y);
                if (fabs(where.origin.x - target.origin.x) > 4 ||
                    fabs(where.origin.y - target.origin.y) > 4)
                    printf("WARNING: the window is NOT over the display it was "
                           "asked for. Nothing will appear there.\n");
                if ([entry[(id)kCGWindowAlpha] doubleValue] < 0.99)
                    printf("WARNING: the window is transparent.\n");
            }
            if (list) CFRelease(list);
            if (!found)
                printf("WARNING: the window server does not list this window as "
                       "on screen at all.\n");
            fflush(stdout);
        }
            };

        /* One flat colour per drawable. clearColor components map straight onto
         * the 10-bit format, so code/1023 lands on the code exactly. */
        void (^present)(double, double, double) =
            ^(double r, double g, double b) {
                @autoreleasepool {
                    id<CAMetalDrawable> drawable = [layer nextDrawable];
                    if (!drawable) {
                        fprintf(stderr, "nextDrawable returned nil - nothing was "
                                        "presented. The patch is not on screen.\n");
                        return;
                    }
                    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                    pass.colorAttachments[0].texture = drawable.texture;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);
                    id<MTLCommandBuffer> buffer = [queue commandBuffer];
                    id<MTLRenderCommandEncoder> encoder =
                        [buffer renderCommandEncoderWithDescriptor:pass];
                    [encoder endEncoding];
                    [buffer presentDrawable:drawable];
                    [buffer commit];
                    [buffer waitUntilCompleted];
                }
            };

        void (^pump)(double) = ^(double seconds) {
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
            [window orderFrontRegardless];
            while ([until timeIntervalSinceNow] > 0) {
                NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                    untilDate:until
                                                       inMode:NSDefaultRunLoopMode
                                                      dequeue:YES];
                if (event) [NSApp sendEvent:event];
            }
        };

        printf("\n");
        if (sdr_mode) {
            double r = sdr_rgb[0] / 255.0, g = sdr_rgb[1] / 255.0, b = sdr_rgb[2] / 255.0;
            if (sdr_layout == 0) {
                printf("LEFT  half: our Metal layer, colorspace nil (SDL's configuration)\n");
                printf("RIGHT half: an ordinary sRGB-tagged layer, which macOS does manage\n");
            } else if (sdr_layout == 1) {
                printf("full screen: our Metal layer, colorspace nil\n");
            } else {
                printf("full screen: sRGB-tagged control layer\n");
            }
            printf("filled with RGB(%d,%d,%d)\n", sdr_rgb[0], sdr_rgb[1], sdr_rgb[2]);
            if (sdr_rgb[0] == sdr_rgb[1] && sdr_rgb[1] == sdr_rgb[2] && sdr_rgb[0] > 0)
                printf("  (neutral: invariant under a colorant swap, so any "
                       "change here is NOT the swap)\n");
            if (sdr_layout == 0) {
                printf("\nWith a permuted profile assigned to THIS display:\n");
                printf("  halves differ     -> PASS, our pixels are not converted\n");
                printf("  both look wrong   -> FAIL, our layer is colour-managed too\n");
                printf("  both look right   -> INVALID, the profile is not in the path\n");
            }
            for (int frame = 0; frame < 3; frame++) { present(r, g, b); pump(0.2); }
            report_on_screen();
            if (dwell > 0.0) {
                printf("holding for %.0fs\n", dwell);
                fflush(stdout);
                pump(dwell);
            } else {
                printf("\nPress Return to exit.\n");
                getchar();
            }
            return 0;
        }
        if (hold_nits >= 0.0) {
            double actual = 0.0;
            unsigned code = code_for_nits(hold_nits, &actual);
            double value = (double)code / 1023.0;
            printf("holding  code %4u  = %8.3f nits  (asked for %.3f)\n",
                   code, actual, hold_nits);
            for (int frame = 0; frame < 3; frame++) { present(value, value, value); pump(0.2); }
            report_on_screen();
            /* Potential headroom says the panel COULD present extended range.
             * Only the live value says it is doing so now, and that is the
             * closest macOS gets to Windows' DXGI "the output is in HDR10 PQ".
             * A reading taken at headroom 1.0 is an SDR reading. */
            printf("EDR headroom while presenting: %.3f (potential %.3f)\n",
                   screen.maximumExtendedDynamicRangeColorComponentValue,
                   screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
            if (screen.maximumExtendedDynamicRangeColorComponentValue <= 1.0)
                printf("WARNING: headroom is still 1.0 - this display is NOT "
                       "presenting extended range, so this is an SDR reading. "
                       "Enable HDR for the display.\n");
            fflush(stdout);
            if (dwell > 0.0) {
                printf("holding for %.0fs\n", dwell);
                fflush(stdout);
                pump(dwell);
            } else {
                /* getchar() returns EOF instantly when stdin is not a
                 * terminal, which is how a backgrounded run used to flash the
                 * window and vanish. Require a tty, or a dwell. */
                if (isatty(fileno(stdin))) {
                    printf("measure now, then press Return to exit.\n");
                    getchar();
                } else {
                    printf("no terminal on stdin and no --dwell given; holding "
                           "30s so there is something to measure.\n");
                    fflush(stdout);
                    pump(30.0);
                }
            }
        } else if (primaries_mode) {
            double actual = 0.0;
            unsigned code = code_for_nits(100.0, &actual);
            double value = (double)code / 1023.0;
            const char *names[] = {"red", "green", "blue"};
            for (int channel = 0; channel < 3; channel++) {
                printf("%-6s at code %u (%.1f nits) - measure, then Return\n",
                       names[channel], code, actual);
                present(channel == 0 ? value : 0.0,
                        channel == 1 ? value : 0.0,
                        channel == 2 ? value : 0.0);
                pump(0.3);
                if (dwell > 0.0) pump(dwell); else getchar();
            }
        } else {
            printf("  %-6s  %-6s  %-10s\n", "target", "code", "actual");
            for (int index = 0; index < step_count; index++) {
                double actual = 0.0;
                unsigned code = code_for_nits(steps[index], &actual);
                double value = (double)code / 1023.0;
                printf("  %6.1f  %6u  %8.3f nits", steps[index], code, actual);
                fflush(stdout);
                present(value, value, value);
                pump(0.3);
                if (dwell > 0.0) { pump(dwell); printf("\n"); }
                else { printf("   [measure, Return for next] "); getchar(); }
            }
            /* Near-black and clipping, where tone mapping shows first and last. */
            unsigned extra[] = {0, 16, 32, 940, 1023};
            for (int index = 0; index < 5; index++) {
                double value = (double)extra[index] / 1023.0;
                printf("  %6s  %6u  %8.3f nits", "-", extra[index],
                       nits_from_pq(value));
                fflush(stdout);
                present(value, value, value);
                pump(0.3);
                if (dwell > 0.0) { pump(dwell); printf("\n"); }
                else { printf("   [measure, Return for next] "); getchar(); }
            }
        }

        printf("\ndone. Compare A (slider 50%%) against B (slider 100%%):\n"
               "a difference above 2%% means WindowServer is tone-mapping and\n"
               "macOS HDR profiling is not viable.\n\n");
        return 0;
    }
}
