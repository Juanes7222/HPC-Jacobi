#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include "poisson.h"

#define DEFAULT_N      2000
#define DEFAULT_ITERS  5000
#define DEFAULT_PROCS  4
#define TOLERANCE      1e-6

/*
 * All shared state lives in a single mmap'd block so every forked child
 * reads from u (read buffer) and writes into u_new (write buffer) on the
 * same physical pages.  The parent owns the convergence check and the
 * buffer swap; children only compute their assigned rows and exit.
 *
 * Memory layout (flat, one mmap call):
 *
 *   [ u[0..n+1] | u_new[0..n+1] | f[0..n+1] ]
 */
typedef struct {
    double *u;
    double *u_new;
    double *f;
} SharedArrays;

static SharedArrays alloc_shared_arrays(int n) {
    int    n2     = n + 2;
    size_t arr_sz = (size_t)n2 * sizeof(double);
    size_t total  = 3 * arr_sz;

    char *base = mmap(NULL, total, PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) { perror("mmap"); exit(1); }

    SharedArrays s;
    s.u     = (double *)(base);
    s.u_new = (double *)(base + arr_sz);
    s.f     = (double *)(base + 2 * arr_sz);
    return s;
}

static void free_shared_arrays(SharedArrays s, int n) {
    int    n2    = n + 2;
    size_t total = 3 * (size_t)n2 * sizeof(double);
    munmap(s.u, total);
}

int main(int argc, char *argv[]) {
    int    n         = (argc > 1) ? atoi(argv[1]) : DEFAULT_N;
    int    max_iters = (argc > 2) ? atoi(argv[2]) : DEFAULT_ITERS;
    int    n_procs   = (argc > 3) ? atoi(argv[3]) : DEFAULT_PROCS;
    double h         = 1.0 / (n + 1);

    SharedArrays s = alloc_shared_arrays(n);

    initialize_grid(s.u,     n);
    initialize_grid(s.u_new, n);
    compute_rhs(s.f, n, h);

    int chunk = n / n_procs;

    double t_start = wall_time();

    int iter = 0;
    for (; iter < max_iters; iter++) {

        /* Fork one child per process slot. Each child computes its rows of
         * u_new from u and exits. */
        pid_t *pids = malloc((size_t)n_procs * sizeof(pid_t));
        for (int p = 0; p < n_procs; p++) {
            int start = p * chunk + 1;
            int end   = (p == n_procs - 1) ? n : (p + 1) * chunk;

            pids[p] = fork();
            if (pids[p] < 0) { perror("fork"); exit(1); }

            if (pids[p] == 0) {
                for (int i = start; i <= end; i++)
                    s.u_new[i] = 0.5 * (s.u[i-1] + s.u[i+1] + h * h * s.f[i]);
                exit(0);
            }
        }

        /* Parent waits for all children — this is the synchronization point. */
        for (int p = 0; p < n_procs; p++)
            waitpid(pids[p], NULL, 0);

        free(pids);

        /* Parent computes RMS residual on the fully-written u_new. */
        double diff = rms_residual(s.u_new, s.f, n, h);

        /* Swap buffers: u_new becomes the new u for the next iteration. */
        double *tmp = s.u;
        s.u         = s.u_new;
        s.u_new     = tmp;

        if (diff < TOLERANCE) break;
    }

    double elapsed_ms = (wall_time() - t_start) * 1000.0;

    fprintf(stderr, "processes n=%-6d iters=%-6d p=%-2d  error=%.4e  time=%.3f ms\n",
            n, iter + 1, n_procs, max_error(s.u, n, h), elapsed_ms);
    printf("%.3f\n", elapsed_ms);

    free_shared_arrays(s, n);
    return 0;
}