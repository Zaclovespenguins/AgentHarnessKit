.PHONY: build test test-ci lint format format-check check dev-check clean bootstrap

bootstrap:
	brew install mint
	mint bootstrap

build:
	swift build

test:
	swift test

test-ci:
	swift test --parallel -Xswiftc -warnings-as-errors

lint:
	mint run swiftlint --strict

format:
	mint run swiftformat .

format-check:
	mint run swiftformat --lint .

dev-check: format lint test

check: format-check lint test-ci

clean:
	swift package clean
