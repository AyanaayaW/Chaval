APP = $(HOME)/Applications/Chaval.app
# A stable identity keeps the Accessibility grant across rebuilds; falls back to ad-hoc signing.
SIGN = $(shell security find-identity -p codesigning | grep -q "Pier Local Signing" && echo "Pier Local Signing" || echo -)

app:
	swift build -c release
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Chaval $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	codesign --force --sign "$(SIGN)" $(APP)

run: app
	open -n $(APP)

.PHONY: app run test

test:
	swift build && .build/debug/Chaval --selftest
