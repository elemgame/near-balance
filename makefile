.PHONY: qa
qa: lint test

.PHONY: lint
lint:
	bash -n near-balance.sh
	shellcheck near-balance.sh tests/helpers/*

.PHONY: test
test:
	bats tests

.PHONY: toolchain
toolchain:
	sudo apt-get update && sudo apt-get install -y shellcheck bats jq
