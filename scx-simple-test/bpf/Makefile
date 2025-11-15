CLANG ?= clang
LLVM_STRIP ?= llvm-strip
BPF_CFLAGS = -O2 -g -target bpf -I. -I../include

all: scx_simple.bpf.o

scx_simple.bpf.o: scx_simple.bpf.c vmlinux.h
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@
	$(LLVM_STRIP) -g $@

clean:
	rm -f *.o