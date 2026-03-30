# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


# Generic Makefile for RV32IMV applications
# Specify program name with PROG, object files with OBJ

SW_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# Clang requires scalar 'f' in -march when vector FP (zve32f) is enabled.
# Use RISCV_SOFT_FLOAT=1 for scalar-float C workloads that must avoid OP-FP.
RISCV_SOFT_FLOAT ?= 0
RISCV_VECTOR_FP := $(if $(or $(filter 1,$(RISCV_ZVE32F)),$(filter 1,$(RISCV_ZVFH))),1,0)

COMPILER ?= llvm
ifeq ($(COMPILER),gcc)
    RISCV_GCC_PREFIX    ?= $(shell if command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then \
                               echo riscv32-unknown-elf;                                      \
                           elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then      \
                               echo riscv64-unknown-elf;                                      \
                           else                                                                \
                               echo riscv32-unknown-elf;                                      \
                           fi)
    RISCV_CC            := $(RISCV_GCC_PREFIX)-gcc
    RISCV_DUMP          := $(RISCV_GCC_PREFIX)-objdump
    RISCV_OBCP          := $(RISCV_GCC_PREFIX)-objcopy
    ifeq ($(filter 1,$(RISCV_SOFT_FLOAT)),1)
        ARCH            := rv32imv
    else
        ARCH            := rv32im$(if $(filter 1,$(RISCV_VECTOR_FP)),f,)v$(if $(filter 1,$(RISCV_VECTOR_FP)),_zve32f,)
    endif
    LD_SCRIPT           := $(SW_DIR)/link.ld
else ifeq ($(COMPILER),llvm)
    # Pick the first clang executable in $PATH with version >= 14, or the
    # default clang if there is no clang >= 14; the individual steps are:
    #  - find all files containing 'clang*' in all directories in $PATH
    #  - use sed to select all those that match 'clang-[0-9]+'
    #  - use awk to select all those that end with a number >= 14
    #  - append 'clang' to that list in case there is no clang >= 14
    #  - select the first executable from that list
    RISCV_CC            := $(shell find `echo $$PATH | sed 's/:/ /g'`         \
                             -maxdepth 1 -name 'clang*' |                     \
                             sed -n '/clang-[0-9][0-9]*$$/p' |                \
                             awk -F"-" '$$NF>=14' | (cat && echo clang) |     \
                             head -n 1) --target=riscv32
    RISCV_DUMP          := $(shell find `echo $$PATH | sed 's/:/ /g'`         \
                             -maxdepth 1 -name 'llvm-objdump*' |              \
                             (cat && echo llvm-objdump) | head -n 1)
    RISCV_OBCP          := $(shell find `echo $$PATH | sed 's/:/ /g'`         \
                             -maxdepth 1 -name 'llvm-objcopy*' |              \
                             (cat && echo llvm-objcopy) | head -n 1)
    ifeq ($(filter 1,$(RISCV_SOFT_FLOAT)),1)
        ARCH            := rv32imzve32x
    else
        ARCH            := rv32im$(if $(filter 1,$(RISCV_VECTOR_FP)),f_zve32f,zve32x)
    endif
    CC_SPECIFIC_OPTIONS := -fuse-ld=lld -Wno-unused-command-line-argument
    LD_SCRIPT           := $(SW_DIR)/lld_link.ld
endif


RISCV_FLAGS := -march=$(ARCH) -mabi=ilp32 -static -mcmodel=medany             \
               -fvisibility=hidden -nostdlib -nostartfiles -Wall              \
               $(CC_SPECIFIC_OPTIONS)

ifeq ($(filter 1,$(RISCV_SOFT_FLOAT)),1)
    SOFT_FLOAT_RT := $(shell                                                 \
        if [ "$(COMPILER)" = "gcc" ]; then                                   \
            cc="$(RISCV_CC)";                                                \
        elif command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then        \
            cc="riscv32-unknown-elf-gcc";                                    \
        elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then        \
            cc="riscv64-unknown-elf-gcc";                                    \
        else                                                                 \
            cc="";                                                           \
        fi;                                                                  \
        if [ -n "$$cc" ]; then                                               \
            lib=`$$cc -march=$(ARCH) -mabi=ilp32 -print-libgcc-file-name     \
                2>/dev/null`;                                                \
            if [ -f "$$lib" ]; then                                          \
                echo "$$lib";                                                \
            fi;                                                              \
        fi)
endif

LDFLAGS := -Wl,--build-id=none $(LDFLAGS)
COMMON_CFLAGS := -O2 -I$(SW_DIR)/lib/ -include $(SW_DIR)/lib/rvv_compat.h

PROG ?= test
OBJ  ?= test.o

# add crt0 to object files
RISCV_OBJ := $(SW_DIR)/crt0.o $(OBJ) $(SW_DIR)/lib/uart.o

all: $(PROG).vmem

dump: $(PROG).elf
	$(RISCV_DUMP) -D $<

$(PROG).elf: $(RISCV_OBJ) $(LD_SCRIPT)
	$(RISCV_CC) $(RISCV_FLAGS) -T $(LD_SCRIPT) $(LDFLAGS) $(RISCV_OBJ) \
	    $(SOFT_FLOAT_RT) -o $@

%.o: %.c
	$(RISCV_CC) $(RISCV_FLAGS) $(COMMON_CFLAGS) $(CFLAGS) -c -o $@ $<

%.o: %.S
	$(RISCV_CC) $(RISCV_FLAGS) $(ASFLAGS) -c -o $@ $<

# currently unusable due to problems with byte order
# (see https://github.com/riscv/riscv-tools/issues/168#issuecomment-554973539)
#%.vmem: %.elf
#	$(OBJCOPY) -O verilog --verilog-data-width 4 $^ $@

# workaround (requires srecord):
# note: start address must be reset manually because it is lost in bin file
%.vmem: %.bin
	srec_cat $^ -binary -offset 0x0000 -byte-swap 4 -o $@ -vmem
%.bin: %.elf
	$(RISCV_OBCP) -O binary $^ $@

clean:
	rm -f *.o *.elf *.bin *.vmem

include $(SW_DIR)/toolchain.mk
