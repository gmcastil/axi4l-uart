REPO_DIR        := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST))))/../..)
VRF_DIR         := $(REPO_DIR)/extern/vrf
SVUNIT_INSTALL  := $(VRF_DIR)/extern/svunit

.PHONY: test clean

test:
	REPO_DIR=$(REPO_DIR) \
	SVUNIT_INSTALL=$(SVUNIT_INSTALL) \
	PATH=$(SVUNIT_INSTALL)/bin:$(PATH) \
	    runSVUnit --sim questa \
	    -m baud_rate_gen_vhdl.f \
	    -t baud_rate_gen_unit_test.sv \
	    -o baud_rate_gen

clean:
	rm -rf baud_rate_gen
