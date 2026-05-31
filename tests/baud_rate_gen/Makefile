REPO_DIR        := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST))))/../..)
SCRIPTS_DIR	:= $(REPO_DIR)/scripts

.PHONY: test
test:
	REPO_DIR=$(REPO_DIR) $(SCRIPTS_DIR)/run_svunit --sim questa \
		-m $(CURDIR)/baud_rate_gen_vhdl.f -t baud_rate_gen_unit_test.sv -o baud_rate_gen

.PHONY: clean
clean:
	rm -rf baud_rate_gen
