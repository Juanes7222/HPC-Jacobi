CC      = gcc
CFLAGS  = -O2 -Wall -Wextra -Iinclude
LDFLAGS = -lm -lpthread

SRC_LIB = src/poisson.c
TARGETS = serial threads processes

.PHONY: all clean run

all: $(TARGETS)

serial: src/serial.c $(SRC_LIB)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)

threads: src/threads.c $(SRC_LIB)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)

processes: src/processes.c $(SRC_LIB)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)

run: all
	@bash benchmark.sh

clean:
	rm -f $(TARGETS)