# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


# Tests Makefile
# requires GNU make; avoid spaces in directory names!

SHELL := /bin/bash

# get the absolute path of the test directory (must not contain spaces!)
TEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# select the simulator to use; either verilator (default) or vivado
SIMULATOR ?= verilator

# simulation abort cycles (default 20M, can override with make SIM_ABORT_CYCLES=xxx)
SIM_ABORT_CYCLES ?= 20000000

# test directories
TEST_DIRS := lsu alu mul sld elem csr kernel misc fp

# test targets
TEST_SRC_EXCLUDES := %_support.S %_support.c
TEST_SRCS := $(shell find $(TEST_DIRS) \( -name '*.S' -o -name '*.c' \))
TEST_SRCS := $(filter-out $(TEST_SRC_EXCLUDES),$(TEST_SRCS))
TESTS_ALL := $(TEST_DIRS) $(addsuffix /, $(TEST_DIRS))
TESTS_ALL := $(TESTS_ALL) $(basename $(TEST_SRCS))
TESTS_DEFAULT := $(TEST_DIRS)


.PHONY: all $(TESTS_ALL)
all: $(TESTS_DEFAULT)


# TODO find ways to check that:
# - all parameters are initialized
lint: lint-verible lint-verilator

# Verible Linting Rules
# change rule parameters
LINT_VERIBLE := typedef-structs-unions=allow_anonymous_nested:true
LINT_VERIBLE := $(LINT_VERIBLE),parameter-name-style=localparam_style:ALL_CAPS
LINT_VERIBLE := $(LINT_VERIBLE),line-length=length:200
# enable rules
LINT_VERIBLE := $(LINT_VERIBLE),proper-parameter-declaration
LINT_VERIBLE := $(LINT_VERIBLE),signal-name-style
# disable rules
LINT_VERIBLE := $(LINT_VERIBLE),-generate-label,-struct-union-name-style
LINT_VERIBLE := $(LINT_VERIBLE),-explicit-parameter-storage-type
LINT_VERIBLE := $(LINT_VERIBLE),-undersized-binary-literal
LINT_VERIBLE := $(LINT_VERIBLE),-interface-name-style
lint-verible:
	verible-verilog-lint --rules="$(LINT_VERIBLE)"                            \
	    `ls $(TEST_DIR)/../rtl/*.sv | grep -v vproc_pkg.sv`

LINT_CORE_INC  := -I$(TEST_DIR)/../rtl/
LINT_CORE_INC  += -I$(TEST_DIR)/../vendor/lowrisc_ip/dv/sv/dv_utils/
LINT_CORE_INC  += -I$(TEST_DIR)/../vendor/lowrisc_ip/ip/prim/rtl/
LINT_CORE_INC  += -I$(TEST_DIR)/../vendor/lowrisc_ip/ip/prim_generic/rtl/
LINT_FP_INC    := -I$(TEST_DIR)/../rtl/cvfpu/src/common_cells/include/
LINT_FP_INC    += -I$(TEST_DIR)/../rtl/cvfpu/src/
LINT_FP_INC    += -I$(TEST_DIR)/../rtl/cvfpu/src/common_cells/src/
LINT_FP_INC    += -I$(TEST_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/
LINT_CORE_SRCS := ibex_pkg.sv prim_pkg.sv prim_assert.sv prim_ram_1p_pkg.sv
LINT_CORE_SRCS += $(TEST_DIR)/../syn/rtl/prim_clock_gating.v ibex_register_file_ff.sv
LINT_FP_SRCS   := $(wildcard $(TEST_DIR)/../rtl/cvfpu/src/*.sv)
LINT_FP_SRCS   += $(wildcard $(TEST_DIR)/../rtl/cvfpu/src/common_cells/src/*.sv)
LINT_FP_SRCS   += $(wildcard $(TEST_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/*.sv)
LINT_FP_SRCS   += $(wildcard $(TEST_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/*.v)
LINT_FP_SRCS   += $(wildcard $(TEST_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/*.v)
LINT_FP_SRCS   += $(wildcard $(TEST_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/*.v)
LINT_FP_SRCS   := $(sort $(LINT_FP_SRCS))

lint-verilator:
	config_file=`mktemp -d | awk '{print $$1"/vproc_config.sv"}'`;            \
	make -f $(TEST_DIR)/../config.mk "VPROC_CONFIG_PKG=$${config_file}";      \
	verilator -Wall -Wno-PINCONNECTEMPTY -Wno-UNUSED -Wno-UNDRIVEN            \
	    -Wno-UNSIGNED -Wno-DECLFILENAME -Wno-USERFATAL -Wno-SYNCASYNCNET      \
	    -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-LATCH             \
	    -Wno-GENUNNAMED -Wno-IMPORTSTAR -Wno-ASCRANGE -Wno-fatal             \
	    -DMAIN_CORE_IBEX $(LINT_CORE_INC) $(LINT_FP_INC)                      \
	    $(LINT_FP_SRCS) $(LINT_CORE_SRCS) vproc_pkg.sv $${config_file}        \
	    vproc_top.sv vproc_core.sv vproc_vregpack.sv vproc_vregunpack.sv      \
	    --top-module vproc_top --lint-only


.SECONDEXPANSION:
$(TESTS_ALL): %: $$(addsuffix .vmem,$$(basename $$(filter-out $$(TEST_SRC_EXCLUDES),$$(if $$(wildcard %),$$(wildcard %/*.S %/*.c),$$(wildcard %.S %.c)))))
	@if [ -d $@ ]; then                                                       \
	    cd $@;                                                                \
	else                                                                      \
	    cd $(dir $@);                                                         \
	fi;                                                                       \
	rm -f progs.txt;                                                          \
	test_vmems=($(abspath $^));                                               \
	for memi in "$${test_vmems[@]}"; do                                       \
	    elf="$${memi%.*}.elf";                                                \
	    vref_start=`readelf -s $$elf | grep vref_start |                      \
	                sed 's/^.*\([A-Fa-f0-9]\{8\}\).*$$/\1/'`;                 \
	    vref_end=`readelf -s $$elf | grep vref_end |                          \
	              sed 's/^.*\([A-Fa-f0-9]\{8\}\).*$$/\1/'`;                   \
	    vdata_start=`readelf -s $$elf | grep vdata_start |                    \
	                 sed 's/^.*\([A-Fa-f0-9]\{8\}\).*$$/\1/'`;                \
	    vdata_end=`readelf -s $$elf | grep vdata_end |                        \
	               sed 's/^.*\([A-Fa-f0-9]\{8\}\).*$$/\1/'`;                  \
	    memref="$${memi%.*}.ref.vmem $$vref_start $$vref_end";                \
	    memo="$${memi%.*}.dump.vmem $$vdata_start $$vdata_end";               \
	    echo "$$memi $$memref $$memo " >> progs.txt;                          \
	done;                                                                     \
	retval=0;                                                                 \
	while IFS= read -ra line; do                                              \
	    if [ -z "$$line" ] || [ "$${line:0:1}" = "#" ]; then                  \
	        continue;                                                         \
	    fi;                                                                   \
	    printf "\033[0;34m[CONF]\033[0;0m $@ $$line\n";                       \
	    sim_dir=`mktemp -d`;                                                  \
	    echo "[INFO] Writing temporary files to $${sim_dir}";                 \
	    set -o pipefail;                                                      \
	    make -f $(TEST_DIR)/../sim/Makefile $(SIMULATOR) PROJ_DIR=$$sim_dir   \
	        $$line PROG_PATHS=progs.txt SIM_ABORT_CYCLES=$(SIM_ABORT_CYCLES) ENABLE_SVA=1   \
	        ENABLE_PERF_COUNTERS=1                                                \
	        TRACE_SIGS="`cat $(TEST_DIR)/trace-sigs.conf`" 2>&1 | tee sim.log; \
	    if [ $$? -ne 0 ]; then                                                \
	        printf "\033[0;31m[FAIL]\033[0;0m $@ simulation error; ";         \
	        if [ -z "$(FULL_LOG)" ] || [ "$(FULL_LOG)" = "0" ]; then          \
	            printf "last 10 lines of log file $@/sim.log:\n";             \
	            tail -n 10 sim.log;                                           \
	            echo "";                                                      \
	            echo "[INFO] View full log with:"                             \
	                 "$$ less $(abspath $@/sim.log)";                         \
	        else                                                              \
	            printf "content of log file $@/sim.log:\n";                   \
	            cat sim.log;                                                  \
	        fi;                                                               \
	        exit 1;                                                           \
	    fi;                                                                   \
	    pend_vreg_wr_col=`head -n 1 sim_trace.csv | sed 's/;/\n/g' |          \
	                      grep -n pend_vreg_wr_map_o |                        \
	                      awk -F ':' '{print $$1}' | head -n 1`;              \
	    if [ -n "$$pend_vreg_wr_col" ]; then                                  \
	        pending=`tail -n 1 sim_trace.csv |                                \
	                 awk -F ';' -v idx="$$pend_vreg_wr_col" '{print $$idx}'`; \
	        if [ -n "$$pending" ] && ((16#$$pending != 0)); then              \
	            printf "\033[0;33m[WARN]\033[0;0m $@ ";                       \
	            printf "uncleared pending vreg write(s) (0x$${pending})\n";   \
	        fi;                                                               \
	    else                                                                  \
	        printf "\033[0;33m[WARN]\033[0;0m $@ ";                           \
	        printf "pending vreg writes are not among traced signals\n";      \
	    fi;                                                                   \
	    rst_col=`head -n 1 sim_trace.csv | sed 's/;/\n/g' | grep -n rst_ni |  \
	             awk -F ':' '{print $$1}' | head -n 1`;                       \
	    t_start=();                                                           \
	    t_end=();                                                             \
	    expected=0;                                                           \
	    while IFS= read -r t_reset; do                                        \
	        if [ $$expected -ne 0 ] && [ $$expected -ne $$t_reset ]; then     \
	            t_start+=($$expected);                                        \
	            t_end+=($$t_reset);                                           \
	        fi;                                                               \
	        expected=$$(($$t_reset + 1));                                     \
	    done < <(awk -F ';' -v idx="$$rst_col" '{print $$idx}' sim_trace.csv |\
	             grep -n 0 | awk -F ':' '{print $$1}');                       \
	    t_start+=($$expected);                                                \
	    t_end+=(`wc -l sim_trace.csv | awk '{print $$1}'`);                   \
	    idx=0;                                                                \
	    for memi in "$${test_vmems[@]}"; do                                   \
	        prog_cycles=$$(($${t_end[$$idx]} - $${t_start[$$idx]}));          \
	        perf_info=`printf '%9s cycles (%9s - %9s)' $$prog_cycles          \
	                   $${t_start[$$idx]} $${t_end[$$idx]}`;                  \
	        prog_name="$$(basename $${memi%.*})";                             \
	        memref="$${memi%.*}.ref.vmem";                                    \
	        memo="$${memi%.*}.dump.vmem";                                     \
	        memdiff=`diff -u $$memref $$memo`;                                \
	        if [ $$? -ne 0 ]; then                                            \
	            printf '\033[0;31m[FAIL]\033[0;0m %-30s %s\n' $@/$$prog_name  \
	                "$$perf_info";                                            \
	            echo "incorrect memory content; diff:";                       \
	            echo "$$memdiff";                                             \
	            retval=1;                                                     \
	        else                                                              \
	            printf '\033[0;32m[PASS]\033[0;0m %-30s %s\n' $@/$$prog_name  \
	                "$$perf_info";                                            \
	        fi;                                                               \
	        idx=$$(($$idx + 1));                                              \
	    done;                                                                 \
	    if [ "$(SIMULATOR)" = "vivado" ]; then                                \
	        xpr_path="$${sim_dir}/vproc_sim/vproc_sim.xpr";                   \
	        echo "[INFO] View waveform with: $$ vivado $${xpr_path}";         \
	    elif [ "$(SIMULATOR)" = "questa" ]; then                              \
	        wlf_path="$${sim_dir}/vsim.wlf";                                  \
	        echo "[INFO] View waveform with: $$ vsim -view $${wlf_path}";     \
	    fi;                                                                   \
	done < test_configs.conf;                                                 \
	exit $$retval


%.vmem: %.S $(TEST_DIR)/spill_cache.S
	@cd $(dir $@);                                                            \
	prog=$(abspath $(<:%.S=%));                                               \
	obj="$(abspath $(patsubst %.S,%.o,$(patsubst %.c,%.o,$^)))";              \
	log="$${prog}_build.log";                                                 \
	cfg_file="$$(basename $$prog).conf";                                      \
	if [ ! -f "$$cfg_file" ]; then                                            \
	    cfg_file="test_configs.conf";                                         \
	fi;                                                                       \
	cfg_args=$$(awk 'NF && $$1 !~ /^#/' "$$cfg_file" 2>/dev/null |            \
	           head -n 1);                                                    \
	override_args="";                                                         \
	if [ -n "$(COMPILER)" ]; then                                             \
	    override_args="$$override_args COMPILER=$(COMPILER)";                 \
	fi;                                                                       \
	if [ -n "$(RISCV_ZVE32F)" ]; then                                         \
	    override_args="$$override_args RISCV_ZVE32F=$(RISCV_ZVE32F)";         \
	fi;                                                                       \
	if [ -n "$(RISCV_ZVFH)" ]; then                                           \
	    override_args="$$override_args RISCV_ZVFH=$(RISCV_ZVFH)";             \
	fi;                                                                       \
	eval "env $$cfg_args $$override_args                                      \
	    make -f $(TEST_DIR)/../sw/Makefile PROG=$$prog OBJ='$$obj'"           \
	    >$$log 2>&1;                                                          \
	if [ $$? -ne 0 ]; then                                                    \
	    printf "\033[0;31m[FAIL]\033[0;0m $@ build error; log file $$log:\n"; \
	    cat $$log;                                                            \
	    exit 1;                                                               \
	fi

%.vmem: %.c $(TEST_DIR)/spill_cache.S
	@cd $(dir $@);                                                            \
	prog=$(abspath $(<:%.c=%));                                               \
	obj="$(abspath $(patsubst %.S,%.o,$(patsubst %.c,%.o,$^)))";              \
	log="$${prog}_build.log";                                                 \
	cfg_file="$$(basename $$prog).conf";                                      \
	if [ ! -f "$$cfg_file" ]; then                                            \
	    cfg_file="test_configs.conf";                                         \
	fi;                                                                       \
	cfg_args=$$(awk 'NF && $$1 !~ /^#/' "$$cfg_file" 2>/dev/null |            \
	           head -n 1);                                                    \
	override_args="";                                                         \
	if [ -n "$(COMPILER)" ]; then                                             \
	    override_args="$$override_args COMPILER=$(COMPILER)";                 \
	fi;                                                                       \
	if [ -n "$(RISCV_ZVE32F)" ]; then                                         \
	    override_args="$$override_args RISCV_ZVE32F=$(RISCV_ZVE32F)";         \
	fi;                                                                       \
	if [ -n "$(RISCV_ZVFH)" ]; then                                           \
	    override_args="$$override_args RISCV_ZVFH=$(RISCV_ZVFH)";             \
	fi;                                                                       \
	eval "env $$cfg_args $$override_args                                      \
	    make -f $(TEST_DIR)/../sw/Makefile PROG=$$prog OBJ='$$obj'"           \
	    >$$log 2>&1;                                                          \
	if [ $$? -ne 0 ]; then                                                    \
	    printf "\033[0;31m[FAIL]\033[0;0m $@ build error; log file $$log:\n"; \
	    cat $$log;                                                            \
	    exit 1;                                                               \
	fi

kernel/mnist_infer_fp32.vmem: kernel/mnist_fp32_vfma_support.S
kernel/mnist_infer_fp32_fc3zero.vmem: kernel/mnist_fp32_vfma_support.S
kernel/mnist_infer_fp32_norelu.vmem: kernel/mnist_fp32_vfma_support.S
kernel/mnist_fp32_vfma_helper_debug.vmem: kernel/mnist_fp32_vfma_support.S
kernel/mnist_fp32_vfma_helper_aligned_debug.vmem: kernel/mnist_fp32_vfma_support.S


clean:
	rm -f  $(addsuffix /*.o,$(TEST_DIRS))
	rm -f  $(addsuffix /*.elf,$(TEST_DIRS))
	rm -f  $(addsuffix /*.bin,$(TEST_DIRS))
	rm -f  $(addsuffix /*.vmem,$(TEST_DIRS))
	rm -f  $(addsuffix /*.txt,$(TEST_DIRS))
	rm -f  $(addsuffix /*.csv,$(TEST_DIRS))
	rm -f  $(addsuffix /*.log,$(TEST_DIRS))
	rm -f  $(addsuffix /*.vcd,$(TEST_DIRS))
	rm -rf $(addsuffix /obj_dir/,$(TEST_DIRS))
