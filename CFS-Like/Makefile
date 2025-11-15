# ======== Paths ========
BPF_DIR := bpf
USER_DIR := user
VENDOR_DIR := vendor/rbt

BPF_SRC := $(BPF_DIR)/CFS-like.bpf.c
BPF_OBJ := $(BPF_DIR)/CFS-like.bpf.o
BPF_SKEL_HDR := $(BPF_DIR)/CFS-like.bpf.skel.h

USER_SRC := $(USER_DIR)/CFS-like-agent.c
USER_OBJ := $(USER_DIR)/CFS-like-agent.o

RBT_SRC := $(VENDOR_DIR)/red_black_tree.c
RBT_OBJ := $(VENDOR_DIR)/red_black_tree.o

TARGET := CFS-like-agent

# ======== Compiler Flags ========
CLANG := clang
CC := gcc

# BPF flags
BPF_CFLAGS := -g -O2 -target bpf \
	-D__TARGET_ARCH_x86 \
	-I$(BPF_DIR) \
	-I/usr/include/x86_64-linux-gnu \
	-I/usr/include \
	-Wno-compare-distinct-pointer-types

# User-space flags
USER_CFLAGS := -g -O2 \
	-I$(USER_DIR) \
	-I$(VENDOR_DIR) \
	-I$(BPF_DIR) \
	$(shell pkg-config --cflags libbpf)

USER_LDLIBS := $(shell pkg-config --libs libbpf)

# ======== Targets ========

all: $(TARGET)

# --- Build BPF object ---
$(BPF_OBJ): $(BPF_SRC)
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

# --- Generate skeleton header ---
$(BPF_SKEL_HDR): $(BPF_OBJ)
	bpftool gen skeleton $(BPF_OBJ) > $(BPF_SKEL_HDR)

# --- Build RB-tree library ---
$(RBT_OBJ): $(RBT_SRC)
	$(CC) $(USER_CFLAGS) -c $< -o $@

# --- Build user agent ---
$(USER_OBJ): $(USER_SRC) $(BPF_SKEL_HDR)
	$(CC) $(USER_CFLAGS) -c $< -o $@

$(TARGET): $(USER_OBJ) $(RBT_OBJ)
	$(CC) $(USER_OBJ) $(RBT_OBJ) -o $@ $(USER_LDLIBS)

clean:
	rm -f $(BPF_OBJ) $(BPF_SKEL_HDR) $(USER_OBJ) $(RBT_OBJ) $(TARGET)

.PHONY: all clean