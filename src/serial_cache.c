#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "poisson.h"

#define DEFAULT_N     2000
#define DEFAULT_ITERS 5000
#define TOLERANCE     1e-8
#define CACHE_LINE    64

/*
 * Allocates a double array aligned to CACHE_LINE bytes.
 * Standard malloc only guarantees 8-byte alignment, so the first element of
 * an array can straddle two cache lines, causing every access to that element
 * to touch two lines instead of one.  Aligning to 64 bytes eliminates that
 * boundary split and ensures the hardware prefetcher works on full lines.
 */
static double *alloc_aligned(int n) {
    size_t bytes = (size_t)(n + 2) * sizeof(double);
    void  *p     = aligned_alloc(CACHE_LINE, bytes);
    if (!p) { perror("aligned_alloc"); exit(1); }
    memset(p, 0, bytes);
    return (double *)p;
}

int main(int argc, char *argv[]) {
    int    n      = (argc > 1) ? atoi(argv[1]) : DEFAULT_N;
    int    max_it = (argc > 2) ? atoi(argv[2]) : DEFAULT_ITERS;
    double h      = 1.0 / (n + 1);
    double h2     = h * h;

    double *u     = alloc_aligned(n);
    double *u_new = alloc_aligned(n);
    double *f     = alloc_aligned(n);

    compute_rhs(f, n, h);

    double t_start = wall_time();

    int iter = 0;
    for (; iter < max_it; iter++) {
        for (int i = 1; i <= n; i++)
            u_new[i] = 0.5 * (u[i - 1] + u[i + 1] + h2 * f[i]);

        double diff = local_max_diff(u_new, u, 1, n);

        double *tmp = u; u = u_new; u_new = tmp;

        if (diff < TOLERANCE) break;
    }

    double elapsed_ms = (wall_time() - t_start) * 1000.0;

    fprintf(stderr, "serial_cache n=%-6d iters=%-6d error=%.4e  time=%.3f ms\n",
            n, iter + 1, max_error(u, n, h), elapsed_ms);
    printf("%.3f\n", elapsed_ms);

    free(u); free(u_new); free(f);
    return 0;
}