# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


# Simulations Makefile
# requires GNU make; avoid spaces in directory names!

SHELL := /bin/bash

# get the absolute path of the simulation directory (must not contain spaces!)
SIM_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Vivado TCL script
VIVADO_TCL := $(addprefix $(SIM_DIR),sim_vivado.tcl)

# Questa TCL script and variable
QUESTA_TCL := $(addprefix $(SIM_DIR),sim_questa.tcl)
VSIM       ?= vsim

# project directory
PROJ_DIR_TMP := $(shell mktemp -d)
PROJ_DIR     ?= $(PROJ_DIR_TMP)

# select the core to use as main processor (defaults to Ibex)
CORE     ?= ibex
CORE_DIR := $(SIM_DIR)/../$(CORE)/
OLD_VICUNA ?= 1

# memory initialization files
PROG_PATHS ?= progs.txt

# trace file
TRACE_FILE ?= sim_trace.csv
TRACE_SIGS ?= '*'

# select memory width (bits), size (bytes), and latency (cycles, 1 is minimum)
MEM_W       ?= 32
MEM_SZ      ?= 262144
MEM_LATENCY ?= 1
WRITEBACK_STAGE ?= 0

# set configuration of instruction and data caches (both disabled by default)
ICACHE_SZ     ?= 0
ICACHE_LINE_W ?= 128
DCACHE_SZ     ?= 0
DCACHE_LINE_W ?= $(shell echo $$(( $(VMEM_W) * 2 )))

all: verilator

# vector coprocessor configuration file generation (defines VMEM_W and VREG_W)
VPROC_CONFIG_PKG := $(PROJ_DIR)/vproc_config.sv
include $(SIM_DIR)/../config.mk

# Track RTL changes so verilator rebuilds when sources update
RTL_SRCS := $(wildcard $(SIM_DIR)/../rtl/*.sv) \
            $(SIM_DIR)/../syn/rtl/prim_clock_gating.v

verilator-version-check:
	@version=`verilator --version | awk '{print $$2}'`;                       \
	if [ `printf '4.210\n%s\n' "$$version" | sort -V | head -n1` != "4.210" ];\
	then                                                                      \
	    echo "ERROR: Verilator version 4.210 or newer is required."           \
	         "You are currently using Verilator $${version}." >&2;            \
	    exit 1;                                                               \
	fi

verilator: verilator-version-check $(PROJ_DIR)/obj_dir/Vvproc_top.mk
	cd $(PROJ_DIR)/obj_dir && echo "include $(SIM_DIR)/verilated_pch_fix.mk" >> Vvproc_top.mk; \
	make -C $(PROJ_DIR)/obj_dir -f Vvproc_top.mk -j$$(nproc) Vvproc_top;                  \
	$(PROJ_DIR)/obj_dir/Vvproc_top $(abspath $(PROG_PATHS)) $(MEM_W)          \
	    $(MEM_SZ) $(MEM_LATENCY) $$(($(VREG_W) * 2)) $(abspath $(TRACE_FILE)) \
	    $(abspath $(TRACE_VCD)) $(abspath $(TRACE_FST))

$(PROJ_DIR)/obj_dir/Vvproc_top.mk: verilator-version-check $(VPROC_CONFIG_PKG) $(RTL_SRCS)
	cp $(SIM_DIR)/verilator_main.cpp $(PROJ_DIR)/
	cd $(PROJ_DIR);                                                           \
	options="";                                                               \
	cflags="";                                                                \
	if [ -n "$(TRACE_VCD)" ]; then                                            \
	    options="--trace";                                                    \
	    cflags="-CFLAGS -DTRACE_VCD";                                         \
	elif [ -n "$(TRACE_FST)" ]; then                                          \
	    options="--trace-fst";                                                \
	    cflags="-CFLAGS -DTRACE_FST";                                         \
	fi;                                                                       \
	if [ -n "$(SIM_ABORT_CYCLES)" ]; then                                     \
	    cflags="$${cflags} -CFLAGS -DABORT_CYCLES=$(SIM_ABORT_CYCLES)";       \
	fi;                                                                       \
	cflags="$${cflags} -CFLAGS -I/usr/local/include/vltstd";                  \
	if [ -n "$(ENABLE_SVA)" ] && [ "$(ENABLE_SVA)" != "0" ]; then             \
	    options="$$options --assert -DVPROC_SVA";                             \
	fi;                                                                       \
	if [ -n "$(ENABLE_PERF_COUNTERS)" ] && [ "$(ENABLE_PERF_COUNTERS)" != "0" ]; then \
	    options="$$options -DVPROC_PERF_COUNTERS";                            \
	fi;                                                                       \
	if [ -n "$(OLD_VICUNA)" ] && [ "$(OLD_VICUNA)" != "0" ]; then           \
	    options="$$options -DOLD_VICUNA";                                    \
	fi;                                                                       \
	core="";                                                                  \
	inc="";                                                                   \
	src="";                                                                   \
	fp_defs="";                                                               \
	if [ -n "$(RISCV_ZVE32F)" ] && [ "$(RISCV_ZVE32F)" != "0" ]; then        \
	    fp_defs="$$fp_defs -DRISCV_ZVE32F";                                  \
	fi;                                                                       \
	if [ -n "$(RISCV_ZVFH)" ] && [ "$(RISCV_ZVFH)" != "0" ]; then            \
	    fp_defs="$$fp_defs -DRISCV_ZVFH";                                    \
	fi;                                                                       \
	fp_src="$(SIM_DIR)/../rtl/cvfpu/src/fpnew_pkg.sv $(SIM_DIR)/../rtl/cvfpu/src/common_cells/src/cf_math_pkg.sv"; \
	fp_inc="-I$(SIM_DIR)/../rtl/cvfpu/src/common_cells/include/";             \
	fp_src="$$fp_src $(SIM_DIR)/../rtl/cvfpu/src/common_cells/src/lzc.sv $(SIM_DIR)/../rtl/cvfpu/src/common_cells/src/rr_arb_tree.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_top.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_opgroup_block.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_opgroup_fmt_slice.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_opgroup_multifmt_slice.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_fma_multi.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_fma.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_noncomp.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_divsqrt_multi.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_divsqrt_th_32.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_divsqrt_th_64_multi.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_cast_multi.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_rounding.sv $(SIM_DIR)/../rtl/cvfpu/src/fpnew_classifier.sv $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v $(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v";                                             \
	fp_src="$$fp_src $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/iteration_div_sqrt_mvp.sv $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv $(SIM_DIR)/../rtl/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv"; \
	fp_inc="$$fp_inc -I$(SIM_DIR)/../rtl/cvfpu/src/ -I$(SIM_DIR)/../rtl/cvfpu/src/common_cells/src/ -I$(SIM_DIR)/../rtl/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/"; \
	if echo "$(CORE_DIR)" | grep -q "ibex"; then                              \
	    core="-DMAIN_CORE_IBEX";                                              \
    inc="-I$(SIM_DIR)/../rtl/";                                           \
    inc="$$inc -I$(SIM_DIR)/../vendor/lowrisc_ip/dv/sv/dv_utils/";         \
    inc="$$inc -I$(SIM_DIR)/../vendor/lowrisc_ip/ip/prim/rtl/";            \
    inc="$$inc -I$(SIM_DIR)/../vendor/lowrisc_ip/ip/prim_generic/rtl/";    \
	    src="ibex_pkg.sv prim_pkg.sv prim_assert.sv prim_ram_1p_pkg.sv $(SIM_DIR)/../syn/rtl/prim_clock_gating.v"; \
	    src="$$src ibex_register_file_ff.sv";                                 \
	else                                                                      \
	    echo "ERROR: Only Ibex is supported as main core.";                   \
	    exit 1;                                                               \
	fi;                                                                       \
	verilator --unroll-count 256 -Wno-WIDTH -Wno-PINMISSING -Wno-UNOPTFLAT    \
	    -Wno-UNSIGNED -Wno-IMPLICIT -Wno-LITENDIAN -Wno-CASEINCOMPLETE        \
	    -Wno-SYMRSVDWORD -Wno-BLKANDNBLK -Wno-BLKSEQ -Wno-SYNCASYNCNET        \
	    -Wno-LATCH -Wno-SELRANGE -Wno-WIDTHCONCAT                                                           \
	    -Wno-COMBDLY -Wno-DEPRECATED                                          \
	    -I$(SIM_DIR)/../rtl/ -I$(SIM_DIR)/../sva/ $$inc $$core $$fp_defs $$fp_inc                \
	    -GMEM_W=$(MEM_W) -GVMEM_W=$(VMEM_W)                                   \
	    -GWritebackStage=$(WRITEBACK_STAGE)                                  \
	    -GICACHE_SZ=$(ICACHE_SZ) -GICACHE_LINE_W=$(ICACHE_LINE_W)             \
	    -GDCACHE_SZ=$(DCACHE_SZ) -GDCACHE_LINE_W=$(DCACHE_LINE_W)             \
	    --cc $$fp_src $$src vproc_pkg.sv $(VPROC_CONFIG_PKG) vproc_top.sv              \
	    vproc_vregpack.sv vproc_vregunpack.sv --top-module vproc_top          \
	    $$options $$cflags --exe verilator_main.cpp

vivado: $(VPROC_CONFIG_PKG)
	cd $(PROJ_DIR) && vivado -mode batch -source $(VIVADO_TCL)                \
	    -tclargs $(SIM_DIR)/../ $(CORE_DIR) $(VPROC_CONFIG_PKG)               \
	    "MEM_W=$(MEM_W) MEM_SZ=$(MEM_SZ) MEM_LATENCY=$(MEM_LATENCY)           \
	    VMEM_W=$(VMEM_W)                                                      \
	    WRITEBACK_STAGE=$(WRITEBACK_STAGE)                                    \
	    ICACHE_SZ=$(ICACHE_SZ) ICACHE_LINE_W=$(ICACHE_LINE_W)                 \
	    DCACHE_SZ=$(DCACHE_SZ) DCACHE_LINE_W=$(DCACHE_LINE_W)"                \
	    $(abspath $(TRACE_FILE)) $(abspath $(PROG_PATHS)) $(TRACE_SIGS)

questa: $(VPROC_CONFIG_PKG)
	cd $(PROJ_DIR) && $(VSIM) -batch -do 'do $(QUESTA_TCL)                    \
	    $(SIM_DIR).. $(CORE_DIR) $(VPROC_CONFIG_PKG)                          \
	    "$(VMEM_W) $(MEM_W) $(MEM_SZ) $(MEM_LATENCY) $(WRITEBACK_STAGE)       \
	    $(ICACHE_SZ) $(ICACHE_LINE_W) $(DCACHE_SZ) $(DCACHE_LINE_W)"          \
	    $(abspath $(TRACE_FILE)) $(abspath $(PROG_PATHS)) "$(TRACE_SIGS)"'
