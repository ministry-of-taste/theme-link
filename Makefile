PREFIX ?= $(HOME)/.local
DESTDIR ?=

.PHONY: check lint test install

check: lint test

lint:
	bash -n theme-link tests/integration.sh
	shellcheck theme-link tests/integration.sh

test:
	bash tests/integration.sh

install:
	install -Dm755 theme-link "$(DESTDIR)$(PREFIX)/bin/theme-link"
