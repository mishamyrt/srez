.DEFAULT_GOAL := build
.PHONY: help build test app app-test clean

help:
	@echo "Srez"
	@echo "  make build       build .build/Srez.app for this Mac (default)"
	@echo "  make test        run app and engine tests"
	@echo "  make clean       remove build artifacts"

build:
	bash scripts/build-app.sh

test:
	xcodebuild test -scheme Srez \
	  -destination 'platform=macOS,arch=arm64' \
	  -derivedDataPath .build/app-derived -configuration Release ENABLE_TESTABILITY=YES \
	  -only-testing:SrezTests -only-testing:GigaAMKitTests

app: build

app-test: test

clean:
	rm -rf .build .xcode-derived
