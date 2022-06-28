KONG_VERSION ?= 2.8.1

all: lint test

.PHONY: lint
lint:
	KONG_VERSION="$(KONG_VERSION)" pongo lint

.PHONY: test
test:
	KONG_VERSION="$(KONG_VERSION)" pongo run

.PHONY: release
release: lint test
	@./scripts/release.sh
