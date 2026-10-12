# Makefile: test, lint, and package. needs only make, bash, git, and tar, and works with the
# make 3.81 that macos ships.
#
#   make test       run tests/run.sh
#   make lint       bash -n on every shell file, then shellcheck when it is installed
#   make package    a tarball of the files git tracks, in dist/ (or DIST=path)
#   make menu-bar       the macos menu bar app, macos/menu-bar/build/Sirven.app (needs swift)
#   make test-menu-bar  the menu bar app's swift tests (needs swift)

SHELL := /bin/sh
PACKAGE := $(shell sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' project.json | head -n 1 | tr '[:upper:]' '[:lower:]')
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unversioned)
DIST ?= dist
SHELL_FILES := install.sh uninstall.sh bin/sirven $(wildcard lib/*.sh) tests/run.sh tests/golden/run.sh $(wildcard tests/lib/*.sh) $(wildcard tests/unit/*.sh) macos/menu-bar/build-app.sh

.PHONY: help test lint package menu-bar test-menu-bar

help:
	@echo "make test      run every test: tests/run.sh"
	@echo "make lint      bash -n on every shell file, then shellcheck if it is installed"
	@echo "make package   $(DIST)/$(PACKAGE)-$(VERSION).tar.gz from the files git tracks"
	@echo "make menu-bar  macos/menu-bar/build/Sirven.app, the menu bar app (macos, needs swift)"
	@echo "make test-menu-bar  the menu bar app's swift tests (macos, needs swift)"

test:
	bash tests/run.sh

# the menu bar app is macos only, so make test leaves it out and stays green on linux.
menu-bar:
	bash macos/menu-bar/build-app.sh

test-menu-bar:
	swift test --package-path macos/menu-bar

lint:
	@for file in $(SHELL_FILES); do bash -n "$$file" || exit 1; done
	@echo "lint: bash -n found no syntax errors in $(words $(SHELL_FILES)) files"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x $(SHELL_FILES) && echo "lint: shellcheck passed"; \
	else \
	  echo "lint: shellcheck not found, so it was skipped. install it to run it: brew install shellcheck, or apt install shellcheck"; \
	fi

# only files git tracks go in, so nothing ignored (video/node_modules, .env files, local
# settings) or left untracked can ship by accident. .git itself is never listed.
package:
	@set -e; \
	name="$(PACKAGE)-$(VERSION)"; \
	stage="$$(mktemp -d "$${TMPDIR:-/tmp}/$(PACKAGE)-package.XXXXXX")"; \
	trap 'rm -rf "$$stage"' EXIT; \
	mkdir -p "$$stage/$$name" "$(DIST)"; \
	git ls-files --cached | grep -v -e '^\.git/' -e '^video/node_modules/' \
	  | while IFS= read -r file; do if [ -f "$$file" ]; then printf '%s\n' "$$file"; fi; done > "$$stage/files"; \
	tar -cf - -T "$$stage/files" | (cd "$$stage/$$name" && tar -xf -); \
	tar -czf "$(DIST)/$$name.tar.gz" -C "$$stage" "$$name"; \
	echo "package: $(DIST)/$$name.tar.gz, $$(grep -c . "$$stage/files") files"
