CC ?= gcc
CFLAGS ?= -O2 -g -I../bpf -I../../libbpf/include
LIBS = -lbpf -lelf -lz

all: scx_simple_agent

scx_simple_agent: scx_simple_agent.c ../bpf/scx_simple.skel.h
	$(CC) $(CFLAGS) $< -o $@ $(LIBS)

../bpf/scx_simple.skel.h: ../bpf/scx_simple.bpf.o
	bpftool gen skeleton ../bpf/scx_simple.bpf.o > ../bpf/scx_simple.skel.h

clean:
	rm -f scx_simple_agent ../bpf/scx_simple.skel.h