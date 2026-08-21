APP := bin/ClipB.app

# Command Line Tools ship Testing.framework outside SwiftPM's default search
# path; with full Xcode these dirs don't exist and the flags stay empty.
DEV := $(shell xcode-select -p)
FW := $(DEV)/Library/Developer/Frameworks
LIB := $(DEV)/Library/Developer/usr/lib
ifneq ($(wildcard $(FW)),)
TESTFLAGS := -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(LIB)
endif

all: open

build:
	swift build -c release

bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp appInfo/Info.plist "$(APP)/Contents/Info.plist"
	cp .build/release/clipb "$(APP)/Contents/MacOS/clipb"
	# Ad-hoc signature keeps the Accessibility grant stable across rebuilds.
	codesign --force --sign - "$(APP)"

open: bundle
	-killall clipb 2>/dev/null
	open "$(APP)"

test:
	swift test $(TESTFLAGS)

clean:
	rm -rf .build bin

.PHONY: all build bundle open test clean
