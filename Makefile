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

all: dev

build:
	swift build -c release

bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp appInfo/Info.plist "$(APP)/Contents/Info.plist"
	cp .build/release/clipb "$(APP)/Contents/MacOS/clipb"
	$(SIGN) "$(APP)"

release: bundle
	-killall clipb 2>/dev/null
	open "$(APP)"

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
	$(SIGN) "$(DEV_APP)"
	-killall clipb 2>/dev/null
	open "$(DEV_APP)"

test:
	swift test $(TESTFLAGS) -Xswiftc -DDEV_PERSIST

clean:
	rm -rf .build .build-dev bin

# Puts `clipb copy` on PATH (~/.local/bin must be on PATH). The symlink points
# at the dev app that `make` builds, so rebuilds are picked up automatically.
install-cli:
	mkdir -p "$(HOME)/.local/bin"
	ln -sf "$(CURDIR)/$(DEV_APP)/Contents/MacOS/clipb" "$(HOME)/.local/bin/clipb"

# Recovery when System Settings shows ClipB as allowed but paste only beeps:
# clears the stale grant, then relaunch and accept the prompt once.
reset-accessibility:
	tccutil reset Accessibility com.productmind.clipb

.PHONY: all build bundle release dev test clean install-cli reset-accessibility
