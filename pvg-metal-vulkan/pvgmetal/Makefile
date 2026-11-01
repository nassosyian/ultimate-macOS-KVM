# pvgmetal: offline test tools for the pvg-linux-pci Metal pieces.
# The translator sources live in the QEMU branch: src/qemu/hw/display/pvg/.
LLVM_CONFIG ?= llvm-config
SRC = ../src/qemu/hw/display/pvg
CFLAGS ?= -O2 -g
CFLAGS += $(EXTRA_CFLAGS) -std=gnu11 -Wall -Wextra -Wno-unused-parameter -I$(SRC) \
	$(shell $(LLVM_CONFIG) --cflags | sed 's/-std=[^ ]*//')
LDLIBS_LLVM = $(shell $(LLVM_CONFIG) --ldflags) $(shell $(LLVM_CONFIG) --libs)
BUILD ?= ../build/pvgmetal

all: $(BUILD)/air2spv-test

$(BUILD)/%.o: $(SRC)/%.c $(SRC)/spv.h $(SRC)/air2spv.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.c $(SRC)/air2spv.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/air2spv-test: $(BUILD)/air2spv-test.o $(BUILD)/air2spv.o $(BUILD)/spv.o
	$(CC) $^ -o $@ $(LDLIBS_LLVM) -lvulkan $(EXTRA_LDFLAGS)

clean:
	rm -rf $(BUILD)

.PHONY: all clean
