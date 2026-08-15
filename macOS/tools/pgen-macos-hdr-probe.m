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
        double hold_nits = -1.0;
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
            else if (!strcmp(argv[index], "--display") && index + 1 < argc)
                display_index = atoi(argv[++index]);
            else if (!strcmp(argv[index], "--hold") && index + 1 < argc)
                hold_nits = atof(argv[++index]);
            else if (!strcmp(argv[index], "--no-metadata")) use_metadata = false;
            else if (!strcmp(argv[index], "--metadata-max") && index + 1 < argc)
                metadata_max = atof(argv[++index]);
            else if (!strcmp(argv[index], "--dwell") && index + 1 < argc)
                dwell = atof(argv[++index]);
            else if (!strcmp(argv[index], "--primaries")) primaries_mode = true;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSScreen *screen = nil;
        CGDirectDisplayID display = display_at_index(display_index, &screen);

        printf("\ndisplay      [%d] %s (0x%08x)\n", display_index,
               screen.localizedName.UTF8String, display);
        printf("EDR headroom %.3f now, %.3f potential\n",
               screen.maximumExtendedDynamicRangeColorComponentValue,
               screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
        if (screen.maximumPotentialExtendedDynamicRangeColorComponentValue <= 1.0)
            printf("WARNING: this display reports no EDR headroom. Enable HDR for it,\n"
                   "         or pick another display - results here mean nothing.\n");

        NSWindow *window =
            [[NSWindow alloc] initWithContentRect:screen.frame
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO
                                           screen:screen];
        window.level = NSScreenSaverWindowLevel;
        window.backgroundColor = NSColor.blackColor;

        ProbeView *view = [[ProbeView alloc] initWithFrame:screen.frame];
        view.wantsLayer = YES;

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
        layer.framebufferOnly = NO;
        layer.frame = view.bounds;
        layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
        layer.wantsExtendedDynamicRangeContent = YES;

        /* CAMetalLayer: "If non-nil, content may be tone mapped to match the
         * current display characteristics. If nil, samples will be rendered
         * without tone mapping." Both are worth measuring - if they differ,
         * that difference IS the tone mapper. */
        if (use_metadata) {
            layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:(float)metadata_min
                                                               maxLuminance:(float)metadata_max
                                                         opticalOutputScale:100];
            printf("EDR metadata max %.0f nits, min %.4f nits\n",
                   metadata_max, metadata_min);
        } else {
            layer.EDRMetadata = nil;
            printf("EDR metadata omitted (no tone mapping, per CAMetalLayer)\n");
        }

        view.layer = layer;
        view.metal = layer;
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        id<MTLCommandQueue> queue = [layer.device newCommandQueue];

        /* One flat colour per drawable. clearColor components map straight onto
         * the 10-bit format, so code/1023 lands on the code exactly. */
        void (^present)(double, double, double) =
            ^(double r, double g, double b) {
                @autoreleasepool {
                    id<CAMetalDrawable> drawable = [layer nextDrawable];
                    if (!drawable) return;
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
            while ([until timeIntervalSinceNow] > 0) {
                NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                    untilDate:until
                                                       inMode:NSDefaultRunLoopMode
                                                      dequeue:YES];
                if (event) [NSApp sendEvent:event];
            }
        };

        printf("\n");
        if (hold_nits >= 0.0) {
            double actual = 0.0;
            unsigned code = code_for_nits(hold_nits, &actual);
            double value = (double)code / 1023.0;
            printf("holding  code %4u  = %8.3f nits  (asked for %.3f)\n",
                   code, actual, hold_nits);
            printf("measure now, then press Return to exit.\n");
            for (int frame = 0; frame < 3; frame++) { present(value, value, value); pump(0.2); }
            getchar();
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
