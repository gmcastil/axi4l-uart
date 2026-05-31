SHELL			:= /bin/bash
NPROC			:= $(shell nproc)

# Top level directories that all subsystems inherit
REPO_DIR		:= $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
EXTERN_DIR		:= $(REPO_DIR)/extern
SCRIPTS_DIR		:= $(REPO_DIR)/scripts
SVUNIT_INSTALL		:= $(EXTERN_DIR)/svunit

PRINTF			:= builtin printf
GREP			:= grep

PROJ_FILES		:= $(shell git ls-files | grep -v '^extern/')

VENV			:= $(REPO_DIR)/.venv
VENV_STAMP		:= $(REPO_DIR)/.venv_installed_stamp
PYTHON			:= $(VENV)/bin/python3
PYTEST			:= $(VENV)/bin/pytest

TEST_DIRS		:= $(wildcard $(REPO_DIR)/tests/*)
TEST_ARGS		:=

include mk/functions.mk

.PHONY: help init ctags check-ascii clean test test-clean unit-test integration-test

help:
	@$(PRINTF) '%s\n' "Top-level targets:"
	$(call print_help_entry, "init", "Initialize repo")
	$(call print_help_entry, "test", "Run all SVUnit unit test suites")
	$(call print_help_entry, "integration-test", "Run all integration tests via pytest")
	$(call print_help_entry, "ctags", "Regenerate ctags for SystemVerilog sources")
	$(call print_help_entry, "file-list", "Regenerate verible.filelist for the LSP")
	$(call print_help_entry, "check-ascii", "Check source tree for non-ASCII characters")
	$(call print_help_entry, "clean", "Remove build artifacts and venv")
	$(call print_help_entry, "test-clean", "Remove unit test build artifacts only")

init: ctags file-list $(VENV_STAMP) install-hooks

ctags:
	ctags -R --languages=SystemVerilog \
	$(REPO_DIR)/vrf_pkg $(REPO_DIR)/tests $(SVUNIT_INSTALL)/svunit_base

install-hooks:
	ln -sf $(REPO_DIR)/scripts/hooks/post-commit $(REPO_DIR)/.git/hooks/post-commit
	ln -sf $(REPO_DIR)/scripts/hooks/post-commit $(REPO_DIR)/.git/hooks/post-checkout
	ln -sf $(REPO_DIR)/scripts/hooks/post-commit $(REPO_DIR)/.git/hooks/post-merge

# Check the source codd and documentation for non-ASCII characters
check-ascii:
	@$(PRINTF) '%s\n' "Checking for non-ASCII characters..."
	@LC_ALL=C $(GREP) -I --color='always' -Pn "[^\x00-\x7F]" $(PROJ_FILES) || $(PRINTF) 'OK\n'

# Installs the components needed to run integration tests via pytest
$(VENV_STAMP): requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install -r requirements.txt
	touch $(VENV_STAMP)

test: unit-test integration-test

unit-test:
	@for dir in $(TEST_DIRS); do $(MAKE) -C $$dir test || exit 1; done
	@$(SCRIPTS_DIR)/summarize_tests $(REPO_DIR)/tests

integration-test: $(VENV_STAMP)
	@$(PYTHON) -m pytest $(TEST_ARGS)

clean: test-clean
	rm -f $(REPO_DIR)/tags
	rm -f $(REPO_DIR)/verible.filelist
	rm -rf $(VENV)
	rm -f $(VENV_STAMP)

test-clean:
	@for dir in $(TEST_DIRS); do $(MAKE) -C $$dir clean || exit 1; done

