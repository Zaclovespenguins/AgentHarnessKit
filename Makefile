.PHONY: acceptance build test test-ci lint format format-check check dev-check check-local clean bootstrap

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

# Same checks as `check`, calling swiftformat and swiftlint from PATH (no mint).
check-local:
	swiftformat --lint .
	swiftlint --strict
	swift test --parallel -Xswiftc -warnings-as-errors

clean:
	swift package clean

acceptance:
	python3 scripts/phase8_acceptance.py
