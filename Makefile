.DEFAULT_GOAL := build
.PHONY: help build test app app-test clean publish test-release App/Info.plist

VERSION := 1.1.0
VERSION_BUNDLE := 2
export VERSION VERSION_BUNDLE

App/Info.plist: App/Info.plist.tpl
	@bash -c '[[ "$$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ && "$$VERSION_BUNDLE" =~ ^[1-9][0-9]*$$ ]]' || { echo "Expected VERSION=X.Y.Z and a positive VERSION_BUNDLE." >&2; exit 1; }
	@sed -e "s/{%APP_VERSION%}/$$VERSION/g" -e "s/{%APP_BUILD%}/$$VERSION_BUNDLE/g" "$<" > "$@"
	@plutil -lint "$@" > /dev/null

build: App/Info.plist
	bash scripts/build-app.sh

publish:
	bash scripts/publish.sh

test-release:
	bash scripts/test-release.sh

test:
	xcodebuild test -scheme Srez \
	  -destination 'platform=macOS,arch=arm64' \
	  -derivedDataPath .build/app-derived -configuration Release ENABLE_TESTABILITY=YES \
	  -only-testing:SrezTests -only-testing:GigaAMTests

app: build

app-test: test

clean:
	rm -rf .build .xcode-derived

.PHONY: lint
lint: ## lint and fix the code
	@swiftlint lint --config .swiftlint.yaml --quiet

.PHONY: fmt
fmt: ## format the code
	@swiftformat Sources/
