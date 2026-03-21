CC        = gcc
NOOPT     = -Wall -Wextra
BEST      = -O3 -Wall -march=native -funroll-loops -flto -ffast-math -fomit-frame-pointer
LDFLAGS   = -lm -lpthread
IFLAGS    = -Iinclude

LIB       = src/poisson.c

.PHONY: all clean

all: serial_std serial_opt serial_cache threads processes

serial_std: src/serial.c $(LIB)
	$(CC) $(NOOPT) $(IFLAGS) $^ -o $@ $(LDFLAGS)

serial_opt: src/serial.c $(LIB)
	$(CC) $(BEST) $(IFLAGS) $^ -o $@ $(LDFLAGS)

serial_cache: src/serial_cache.c $(LIB)
	$(CC) $(NOOPT) $(IFLAGS) $^ -o $@ $(LDFLAGS)

threads: src/threads.c $(LIB)
	$(CC) $(NOOPT) $(IFLAGS) $^ -o $@ $(LDFLAGS)

processes: src/processes.c $(LIB)
	$(CC) $(NOOPT) $(IFLAGS) $^ -o $@ $(LDFLAGS)

clean:
	rm -f serial_std serial_opt serial_cache threads processes