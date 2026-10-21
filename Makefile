NVIM ?= nvim

.PHONY: test test-deps test-integration

test:
	$(NVIM) --headless -u NONE -i NONE -c "lua dofile('tests/run.lua')" -c "cquit 1"

test-deps:
	sh tests/install_parsers.sh

test-integration:
	$(NVIM) --headless -u NONE -i NONE -c "lua dofile('tests/integration.lua')" -c "cquit 1"
