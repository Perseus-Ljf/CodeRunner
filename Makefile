NVIM ?= nvim
JULIA ?= julia

.PHONY: test test-deps test-integration test-julia

test:
	$(NVIM) --headless -u NONE -i NONE -c "lua dofile('tests/run.lua')" -c "cquit 1"
	$(NVIM) --headless -u NONE -i NONE -c "lua dofile('tests/workspace.lua')" -c "cquit 1"

test-deps:
	sh tests/install_parsers.sh

test-integration:
	$(NVIM) --headless -u NONE -i NONE -c "lua dofile('tests/integration.lua')" -c "cquit 1"

test-julia:
	$(JULIA) --startup-file=no --history-file=no tests/workspace.jl
