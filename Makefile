APP := bin/release/ClipB.app

# Command Line Tools ship Testing.framework outside SwiftPM's default search
# path; with full Xcode these dirs don't exist and the flags stay empty.
DEV := $(shell xcode-select -p)
FW := $(DEV)/Library/Developer/Frameworks
LIB := $(DEV)/Library/Developer/usr/lib
ifneq ($(wildcard $(FW)),)
TESTFLAGS := -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(LIB)
endif

all: dev

build:
	swift build -c release

bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp appInfo/Info.plist "$(APP)/Contents/Info.plist"
	cp .build/release/clipb "$(APP)/Contents/MacOS/clipb"
	# Ad-hoc signature keeps the Accessibility grant stable across rebuilds.
	codesign --force --sign - "$(APP)"

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
	codesign --force --sign - "$(DEV_APP)"
	-killall clipb 2>/dev/null
	open "$(DEV_APP)"

test:
	swift test $(TESTFLAGS) -Xswiftc -DDEV_PERSIST

clean:
	rm -rf .build .build-dev bin

.PHONY: all build bundle release dev test clean
