# Makefile: test, lint, and package. needs only make, bash, git, and tar, and works with the
# make 3.81 that macos ships.
#
#   make test       run tests/run.sh
#   make lint       bash -n on every shell file, then shellcheck when it is installed
#   make package    a tarball of the files git tracks, in dist/ (or DIST=path)
#   make runtime    macos only: build the runtime's fetch helper, dist/runtime/sirven-fetch, for
#                   Apple Silicon and Intel. needs the Xcode command line tools
#   make keep-awake        macos only: build the keep-awake program behind sirven awake
#   make test-keep-awake   macos only: its unit tests, and a short real power assertion

SHELL := /bin/sh
PACKAGE := $(shell sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' project.json | head -n 1 | tr '[:upper:]' '[:lower:]')
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unversioned)
DIST ?= dist
SHELL_FILES := install.sh uninstall.sh bin/sirven $(wildcard lib/*.sh) $(wildcard lib/attestation/*.sh) tests/run.sh tests/golden/run.sh $(wildcard tests/lib/*.sh) $(wildcard tests/unit/*.sh)

.PHONY: help test lint package runtime keep-awake test-keep-awake

help:
	@echo "make test      run every test: tests/run.sh"
	@echo "make lint      bash -n on every shell file, then shellcheck if it is installed"
	@echo "make package   $(DIST)/$(PACKAGE)-$(VERSION).tar.gz from the files git tracks"
	@echo "make runtime   macos: build dist/runtime/sirven-fetch, the runtime's fetch helper"
	@echo "make keep-awake        build the keep-awake program behind sirven awake (macos)"
	@echo "make test-keep-awake   run its tests (macos)"

test:
	bash tests/run.sh

lint:
	@for file in $(SHELL_FILES); do bash -n "$$file" || exit 1; done
	@echo "lint: bash -n found no syntax errors in $(words $(SHELL_FILES)) files"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x $(SHELL_FILES) && echo "lint: shellcheck passed"; \
	else \
	  echo "lint: shellcheck not found, so it was skipped. install it to run it: brew install shellcheck, or apt install shellcheck"; \
	fi

# only files git tracks go in, so nothing ignored (video/node_modules, .env files, local
# settings) or left untracked can ship by accident. .git itself is never listed. the demo's
# recorded runs (demo/*/recordings) stay in git as evidence but are not shipped: they are
# transcripts of one rehearsal, not part of the product.
package:
	@set -e; \
	name="$(PACKAGE)-$(VERSION)"; \
	stage="$$(mktemp -d "$${TMPDIR:-/tmp}/$(PACKAGE)-package.XXXXXX")"; \
	trap 'rm -rf "$$stage"' EXIT; \
	mkdir -p "$$stage/$$name" "$(DIST)"; \
	git ls-files --cached | grep -v -e '^\.git/' -e '^video/node_modules/' -e '^demo/[^/]*/recordings/' \
	  | while IFS= read -r file; do if [ -f "$$file" ]; then printf '%s\n' "$$file"; fi; done > "$$stage/files"; \
	tar -cf - -T "$$stage/files" | (cd "$$stage/$$name" && tar -xf -); \
	tar -czf "$(DIST)/$$name.tar.gz" -C "$$stage" "$$name"; \
	echo "package: $(DIST)/$$name.tar.gz, $$(grep -c . "$$stage/files") files"

# one binary for both kinds of Mac. the module cache goes in a scratch folder, so the build
# writes nothing outside dist/.
RUNTIME_HELPER := dist/runtime/sirven-fetch
RUNTIME_MACOS_MINIMUM := 12.0

runtime:
	@set -e; \
	[ "$$(uname -s)" = Darwin ] || { echo "make runtime: the fetch helper is macos only; elsewhere the runtime uses its python fetcher"; exit 0; }; \
	scratch="$$(mktemp -d "$${TMPDIR:-/tmp}/sirven-runtime-build.XXXXXX")"; \
	trap 'rm -rf "$$scratch"' EXIT; \
	mkdir -p "$$(dirname $(RUNTIME_HELPER))"; \
	for arch in arm64 x86_64; do \
	  xcrun swiftc -O -module-cache-path "$$scratch/cache" -target "$$arch-apple-macos$(RUNTIME_MACOS_MINIMUM)" \
	    lib/sirven_runtime/fetch_helper.swift -o "$$scratch/sirven-fetch-$$arch"; \
	done; \
	lipo -create "$$scratch/sirven-fetch-arm64" "$$scratch/sirven-fetch-x86_64" -output $(RUNTIME_HELPER); \
	echo "runtime: built $(RUNTIME_HELPER) for $$(lipo -archs $(RUNTIME_HELPER))"
keep-awake:
	swift build --package-path macos/keep-awake -c release

test-keep-awake:
	swift test --package-path macos/keep-awake
