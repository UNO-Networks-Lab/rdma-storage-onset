# cas_gate -- user-space CAS admission gate over NVMe-oF. Needs liburing-dev.
#   sudo apt-get install -y liburing-dev
CC      ?= gcc
CFLAGS  ?= -std=gnu11 -O2 -Wall -Wextra
LDLIBS  ?= -luring

cas_gate: cas_gate.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f cas_gate

.PHONY: clean
