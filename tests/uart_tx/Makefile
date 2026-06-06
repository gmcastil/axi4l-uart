REPO_DIR        := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST))))/../..)
SCRIPTS_DIR	:= $(REPO_DIR)/scripts

.PHONY: test
test:
	REPO_DIR=$(REPO_DIR) $(SCRIPTS_DIR)/run_svunit --sim questa \
		-m $(CURDIR)/uart_tx_vhdl.f -t uart_tx_unit_test.sv -o uart_tx

.PHONY: clean
clean:
	rm -rf uart_tx