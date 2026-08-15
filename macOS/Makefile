# PGenerator+ ICC Tools - macOS (Apple Silicon)
#
# Upstream builds both tools with documented one-line compiler invocations and
# carries no build system, so this stays a plain Makefile confined to macOS/.
# Nothing outside this directory is generated or required.
#
#   make            build both binaries and both .app bundles
#   make companion  just the Patch Companion
#   make loader     just the Profile Loader
#   make run        build and launch the Companion against the mock server
#   make dist       zip the bundles for release
#   make clean
#
# Every path here is relative and every recipe runs from macOS/. That is not
# style: the checkout lives under "Mobile Documents", and make cannot represent
# a target whose path contains a space. Absolute paths break the build on this
# machine, so keep them out.
#
# SDL3 comes from Homebrew for the development loop. Release builds should link
# it statically (see README) so the bundle carries no dylib and needs no rpath.

# Build outputs live OUTSIDE the checkout, and that is not a preference.
# This repo sits in iCloud Drive, which stamps com.apple.FinderInfo and
# com.apple.fileprovider attributes on everything it manages. codesign rejects
# those as "resource fork, Finder information, or similar detritus", and
# `xattr -c` cannot remove them - the file provider puts them straight back.
# A bundle built in place therefore cannot be signed at all.
#
# $(HOME)/.cache has no spaces in it, which the relative-path rule above still
# requires.
OUT        := $(HOME)/.cache/pgen-icc-tools-macos
BUILD      := $(OUT)/build
DIST       := $(OUT)/dist

CC         := clang
ARCH       := -arch arm64
DEPLOY     := -mmacosx-version-min=12.0

SDL_PREFIX := $(shell brew --prefix sdl3 2>/dev/null)
SDL_CFLAGS := -I$(SDL_PREFIX)/include
SDL_LIBS   := -L$(SDL_PREFIX)/lib -lSDL3

# -I../Linux is not a mistake: pgen-ui-font.h lives under Linux/ but the
# Windows Companion already compiles against it, so it is shared in practice.
INCLUDES   := -I../Common -I../Linux -I.
WARNINGS   := -Wall -Wextra -Wno-unused-function

CFLAGS     := -O2 -std=gnu11 $(ARCH) $(DEPLOY) $(WARNINGS) $(INCLUDES) $(SDL_CFLAGS)
OBJCFLAGS  := $(CFLAGS) -fobjc-arc

FRAMEWORKS := -framework Cocoa -framework QuartzCore -framework Metal \
              -framework CoreGraphics -framework ColorSync \
              -framework ApplicationServices
LDFLAGS    := $(ARCH) $(DEPLOY) $(SDL_LIBS) $(FRAMEWORKS) -lm

COMPANION_NAME := PGeneratorPlusPatchCompanion
LOADER_NAME    := PGenProfileLoader

COMPANION_BIN  := $(BUILD)/$(COMPANION_NAME)
LOADER_BIN     := $(BUILD)/$(LOADER_NAME)
COMPANION_APP  := $(DIST)/$(COMPANION_NAME).app
LOADER_APP     := $(DIST)/$(LOADER_NAME).app

COMPANION_SRC  := ../Common/pgen-icc-companion.c
BACKEND_SRC    := pgen-macos-color.m
LOADER_SRC     := pgen-profile-loader-macos.c

# Read APP_VERSION out of the shared source so the bundle cannot drift from
# what the Companion reports to the WebUI. Matched without a literal '#',
# which make would treat as the start of a comment even inside $(shell).
VERSION := $(shell grep -m1 'define APP_VERSION' $(COMPANION_SRC) | cut -d'"' -f2)

.PHONY: all companion loader bundles dist run clean check-sdl icon

all: bundles

check-sdl:
	@test -n "$(SDL_PREFIX)" || { echo "SDL3 not found. Run: brew install sdl3"; exit 1; }

# ---------------------------------------------------------------- binaries

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/pgen-icc-companion.o: $(COMPANION_SRC) pgen-macos-color.h | $(BUILD)
	$(CC) $(CFLAGS) -c $(COMPANION_SRC) -o $@

$(BUILD)/pgen-macos-color.o: $(BACKEND_SRC) pgen-macos-color.h | $(BUILD)
	$(CC) $(OBJCFLAGS) -c $(BACKEND_SRC) -o $@

$(COMPANION_BIN): $(BUILD)/pgen-icc-companion.o $(BUILD)/pgen-macos-color.o
	$(CC) $^ -o $@ $(LDFLAGS)

companion: check-sdl $(COMPANION_BIN)

$(BUILD)/pgen-profile-loader-macos.o: $(LOADER_SRC) pgen-macos-color.h | $(BUILD)
	$(CC) $(CFLAGS) -c $(LOADER_SRC) -o $@

$(LOADER_BIN): $(BUILD)/pgen-profile-loader-macos.o $(BUILD)/pgen-macos-color.o
	$(CC) $^ -o $@ $(LDFLAGS)

loader: check-sdl $(LOADER_BIN)

# ---------------------------------------------------------------- bundles

icon: | $(BUILD)
	@sh make-icns.sh ../favicon.ico $(BUILD)/AppIcon.icns 2>/dev/null || \
	  echo "  (icon generation skipped)"

# Assembled by hand rather than by xcodebuild, which Command Line Tools does
# not provide. SDL_GetBasePath() returns Contents/Resources on macOS, so the
# Companion's "conf and tools beside the executable" logic resolves there with
# no code change - that is where PGenPatchCompanion.conf belongs.
define bundle
	@rm -rf $(2)
	@mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	@cp $(1) "$(2)/Contents/MacOS/"
	@sed -e 's|@EXECUTABLE@|$(notdir $(1))|g' \
	     -e 's|@VERSION@|$(VERSION)|g' \
	     -e 's|@IDENTIFIER@|$(4)|g' \
	     -e 's|@NAME@|$(3)|g' Info.plist.in > "$(2)/Contents/Info.plist"
	@if [ -f $(BUILD)/AppIcon.icns ]; then \
	   cp $(BUILD)/AppIcon.icns "$(2)/Contents/Resources/"; fi
	@# The checkout lives in iCloud Drive, which stamps extended attributes on
	@# every file it touches. codesign rejects those outright as "resource
	@# fork, Finder information, or similar detritus", so clear them first.
	@xattr -cr "$(2)"
	@codesign --force --sign - --identifier $(4) "$(2)" 2>/dev/null || \
	   echo "  (ad-hoc signing failed for $(3))"
	@echo "  $(2)"
endef

bundles: companion loader icon
	@mkdir -p $(DIST)
	@echo "bundling:"
	$(call bundle,$(COMPANION_BIN),$(COMPANION_APP),PGenerator+ Patch Companion,com.pgeneratorplus.patchcompanion)
	@$(MAKE) --no-print-directory bundle-loader
	@# The Companion finds the Loader with companion_tool_path(), which looks
	@# beside the executable - and SDL_GetBasePath() is Contents/Resources on
	@# macOS. Put a copy there so Install & Apply works wherever the user drags
	@# the app, and ship the standalone .app too so the Loader can be opened on
	@# its own and registered as a login item.
	@cp $(LOADER_BIN) "$(COMPANION_APP)/Contents/Resources/"
	@# Adding a resource invalidates the seal, and --force alone will not
	@# rebuild it over a stale _CodeSignature - the bundle then fails
	@# --verify --deep. Drop the old signature first, and do not swallow the
	@# error: an unsigned bundle is a release problem, not a warning.
	@rm -rf "$(COMPANION_APP)/Contents/_CodeSignature"
	@xattr -cr "$(COMPANION_APP)"
	@codesign --force --sign - --identifier com.pgeneratorplus.patchcompanion \
	  "$(COMPANION_APP)"
	@codesign --verify --deep --strict "$(COMPANION_APP)"
	@echo "  (Profile Loader nested in the Companion for Install & Apply)"
	@echo ""
	@echo "built in $(DIST)"

.PHONY: bundle-loader
bundle-loader:
	$(call bundle,$(LOADER_BIN),$(LOADER_APP),PGenerator+ Profile Loader,com.pgeneratorplus.profileloader)

dist: bundles
	@cd $(DIST) && ditto -c -k --keepParent --sequesterRsrc . \
	  ../PGeneratorPlus-ICC-Tools-macOS-arm64.zip
	@echo "wrote $(OUT)/PGeneratorPlus-ICC-Tools-macOS-arm64.zip"

# ---------------------------------------------------------------- dev loop

# Launch against the mock server rather than a real unit, so the whole client
# can be exercised with no PGenerator+ on the network.
run: bundles
	@echo "start the mock first:  python3 mock-pgen-server.py"
	"$(COMPANION_APP)/Contents/MacOS/$(COMPANION_NAME)" --server=http://127.0.0.1:8080

clean:
	rm -rf $(OUT)
