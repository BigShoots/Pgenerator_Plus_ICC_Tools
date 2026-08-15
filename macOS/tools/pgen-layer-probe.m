/* CAMetalLayer colour-management probe - experiment "Spike A".
 *
 * Not shipped. Opens the same kind of SDL3 window the Patch Companion opens,
 * fills it with one flat colour, and reports what the underlying CAMetalLayer
 * is actually tagged with.
 *
 * SDL's Metal renderer only assigns layer.colorspace for the scRGB path
 * (SDL_render_metal.m, the SDL_COLORSPACE_SRGB_LINEAR branch). For an ordinary
 * SDR window it leaves the property alone, and what WindowServer then does
 * with our pixels is the thing this probe settles.
 *
 * Run it with a deliberately permuted display profile assigned (see
 * make-permuted-profile.py) and ask one question: does the red patch look red?
 *
 *   red patch renders green -> our pixels are converted into the display
 *                              profile. Retagging the layer with the display's
 *                              own space is necessary and sufficient, and the
 *                              clut/matrix correction modes mean on macOS what
 *                              they mean on Windows.
 *   red patch stays red     -> our pixels go to the panel as device values.
 *                              `system` mode is then "device values plus
 *                              vcgt", and clut/matrix would double-correct.
 *
 * With --passthrough the probe retags the layer with CGDisplayCopyColorSpace
 * before drawing, which is the fix the Companion would apply. Running both
 * ways back to back is the whole experiment.
 *
 *   clang -fobjc-arc -arch arm64 $(pkg-config --cflags sdl3) \
 *         -framework Cocoa -framework QuartzCore -framework CoreGraphics \
 *         -framework ColorSync $(pkg-config --libs sdl3) \
 *         -o pgen-layer-probe pgen-layer-probe.m
 *
 *   ./pgen-layer-probe --display 1 --color 255,0,0
 *   ./pgen-layer-probe --display 1 --color 255,0,0 --passthrough
 */

#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#include <SDL3/SDL.h>

static NSString *describe_colorspace(CGColorSpaceRef space)
{
    if (!space) return @"nil  (CAMetalLayer default - not explicitly tagged)";
    CFStringRef name = CGColorSpaceCopyName(space);
    NSString *label = name ? CFBridgingRelease(name) : nil;

    CFDataRef icc = CGColorSpaceCopyICCData(space);
    NSString *digest = @"(no ICC payload)";
    if (icc) {
        const uint8_t *bytes = CFDataGetBytePtr(icc);
        CFIndex length = CFDataGetLength(icc);
        uint32_t sum = 2166136261u;
        for (CFIndex i = 0; i < length; i++) { sum ^= bytes[i]; sum *= 16777619u; }
        digest = [NSString stringWithFormat:@"%ld bytes, fnv1a %08x", (long)length, sum];
        CFRelease(icc);
    }
    return [NSString stringWithFormat:@"%@  [%@]", label ?: @"(unnamed)", digest];
}

/* SDL exposes no CGDirectDisplayID property, so go through the window's
 * NSScreen - authoritative, because it is the screen the patch is actually on. */
static CGDirectDisplayID display_id_for_window(SDL_Window *window)
{
    NSWindow *nswindow = (__bridge NSWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    NSNumber *number = nswindow.screen.deviceDescription[@"NSScreenNumber"];
    return (CGDirectDisplayID)number.unsignedIntValue;
}

static CAMetalLayer *metal_layer_for_window(SDL_Window *window)
{
    NSWindow *nswindow = (__bridge NSWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    /* SDL's Metal renderer installs its own view whose layer is the
     * CAMetalLayer; walk down to it rather than creating a second view. */
    NSView *view = nswindow.contentView;
    if ([view.layer isKindOfClass:CAMetalLayer.class]) return (CAMetalLayer *)view.layer;
    for (NSView *child in view.subviews)
        if ([child.layer isKindOfClass:CAMetalLayer.class]) return (CAMetalLayer *)child.layer;
    return nil;
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        int wanted_display = 0;
        int r = 255, g = 0, b = 0;
        bool passthrough = false;

        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--display") && i + 1 < argc)
                wanted_display = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--color") && i + 1 < argc)
                sscanf(argv[++i], "%d,%d,%d", &r, &g, &b);
            else if (!strcmp(argv[i], "--passthrough"))
                passthrough = true;
        }

        if (!SDL_Init(SDL_INIT_VIDEO)) {
            fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
            return 1;
        }
        SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES, "0");

        int count = 0;
        SDL_DisplayID *displays = SDL_GetDisplays(&count);
        if (!displays || count == 0) { fprintf(stderr, "no displays\n"); return 1; }

        printf("\nSDL sees %d display(s):\n", count);
        for (int i = 0; i < count; i++)
            printf("  [%d] %s\n", i, SDL_GetDisplayName(displays[i]));
        if (wanted_display >= count) wanted_display = 0;
        SDL_DisplayID target = displays[wanted_display];
        printf("using [%d] %s\n\n", wanted_display, SDL_GetDisplayName(target));

        SDL_Rect bounds;
        SDL_GetDisplayUsableBounds(target, &bounds);

        SDL_Window *window = SDL_CreateWindow("PGen layer probe",
                                              bounds.w / 2, bounds.h / 2,
                                              SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (!window) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return 1; }
        SDL_SetWindowPosition(window,
                              bounds.x + bounds.w / 4, bounds.y + bounds.h / 4);

        SDL_Renderer *renderer = SDL_CreateRenderer(window, NULL);
        if (!renderer) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return 1; }
        printf("renderer      %s\n", SDL_GetRendererName(renderer));

        CGDirectDisplayID display = display_id_for_window(window);
        CAMetalLayer *layer = metal_layer_for_window(window);
        printf("display id    0x%08x\n", display);
        printf("layer         %s\n", layer ? "found" : "NOT FOUND");

        if (layer) {
            printf("layer format  %lu\n", (unsigned long)layer.pixelFormat);
            printf("colorspace    %s\n",
                   describe_colorspace(layer.colorspace).UTF8String);

            if (passthrough) {
                CGColorSpaceRef space = CGDisplayCopyColorSpace(display);
                layer.colorspace = space;
                printf("\nretagged with the display's own colour space:\n");
                printf("colorspace    %s\n",
                       describe_colorspace(layer.colorspace).UTF8String);
                CGColorSpaceRelease(space);
            }
        }

        printf("\ndisplay profile now assigned to 0x%08x:\n", display);
        {
            CGColorSpaceRef space = CGDisplayCopyColorSpace(display);
            printf("              %s\n", describe_colorspace(space).UTF8String);
            CGColorSpaceRelease(space);
        }

        printf("\nfilling the window with RGB(%d,%d,%d)%s\n",
               r, g, b, passthrough ? "  [passthrough]" : "  [SDL default]");
        printf("press Escape or close the window to quit\n\n");

        bool running = true;
        while (running) {
            SDL_Event event;
            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_EVENT_QUIT) running = false;
                if (event.type == SDL_EVENT_KEY_DOWN &&
                    event.key.key == SDLK_ESCAPE) running = false;
            }
            SDL_SetRenderDrawColor(renderer, (Uint8)r, (Uint8)g, (Uint8)b, 255);
            SDL_RenderClear(renderer);
            SDL_RenderPresent(renderer);
            SDL_Delay(16);
        }

        SDL_free(displays);
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 0;
    }
}
