APP := bin/release/ClipB.app

# Command Line Tools ship Testing.framework outside SwiftPM's default search
# path; with full Xcode these dirs don't exist and the flags stay empty.
DEV := $(shell xcode-select -p)
FW := $(DEV)/Library/Developer/Frameworks
LIB := $(DEV)/Library/Developer/usr/lib
ifneq ($(wildcard $(FW)),)
TESTFLAGS := -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(LIB)
endif

# Plain ad-hoc signing pins the designated requirement to the build's cdhash,
# so every rebuild silently invalidates the Accessibility grant. Pinning it to
# the bundle identifier keeps the grant valid across rebuilds.
SIGN := codesign --force --sign - -r='designated => identifier "com.productmind.clipb"'

# whisper.framework (voice copy, SPEC §2.13) is loaded from
# @executable_path/../Frameworks; nested code is signed before the app.
embed_frameworks = mkdir -p "$(2)/Contents/Frameworks" && ditto "$(1)/whisper.framework" "$(2)/Contents/Frameworks/whisper.framework" && codesign --force --sign - "$(2)/Contents/Frameworks/whisper.framework"

all: dev

build:
	swift build -c release

bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp appInfo/Info.plist "$(APP)/Contents/Info.plist"
	cp .build/release/clipb "$(APP)/Contents/MacOS/clipb"
	$(call embed_frameworks,.build/release,$(APP))
	$(SIGN) "$(APP)"

# `open` right after `killall` can fail with -600 while the old instance is
# still exiting, so retry briefly; -g keeps the relaunch from activating
# ClipB over whatever is in front.
open_app = for i in 1 2 3 4 5; do open -g "$(1)" 2>/dev/null && exit 0; sleep 0.3; done; echo "clipb: could not relaunch $(1)" >&2; exit 1

release: bundle
	-killall clipb 2>/dev/null
	$(call open_app,$(APP))

# Default target. Development-only build whose history survives restarts
# (~/.clipb-dev/history.json). Separate scratch path and app so it can't leak
# into `bundle`.
DEV_APP := bin/ClipB.app

dev:
	swift build -c release --scratch-path .build-dev -Xswiftc -DDEV_PERSIST
	rm -rf "$(DEV_APP)"
	mkdir -p "$(DEV_APP)/Contents/MacOS"
	cp appInfo/Info.plist "$(DEV_APP)/Contents/Info.plist"
	cp .build-dev/release/clipb "$(DEV_APP)/Contents/MacOS/clipb"
	$(call embed_frameworks,.build-dev/release,$(DEV_APP))
	$(SIGN) "$(DEV_APP)"
	-killall clipb 2>/dev/null
	$(call open_app,$(DEV_APP))

test:
	swift test $(TESTFLAGS) -Xswiftc -DDEV_PERSIST

clean:
	rm -rf .build .build-dev .build-dist bin

# Puts `clipb copy` on PATH (~/.local/bin must be on PATH). The symlink points
# at the dev app that `make` builds, so rebuilds are picked up automatically.
install-cli:
	mkdir -p "$(HOME)/.local/bin"
	ln -sf "$(CURDIR)/$(DEV_APP)/Contents/MacOS/clipb" "$(HOME)/.local/bin/clipb"

# Downloadable build: arm64, Developer ID signed + hardened runtime, DMG,
# notarized and stapled. Options and one-time setup: scripts/dist.sh header.
dist:
	DIST_IDENTITY="$(DIST_IDENTITY)" DIST_MODEL="$(DIST_MODEL)" NOTARY_PROFILE="$(NOTARY_PROFILE)" scripts/dist.sh

# Recovery when System Settings shows ClipB as allowed but paste only beeps:
# clears the stale grant, then relaunch and accept the prompt once.
reset-accessibility:
	tccutil reset Accessibility com.productmind.clipb

.PHONY: all build bundle release dev test clean install-cli reset-accessibility dist
