#include <stdio.h>
#include <stdlib.h>
#include "poisson.h"

#define DEFAULT_N     2000
#define DEFAULT_ITERS 5000
#define TOLERANCE     1e-6

int main(int argc, char *argv[]) {
    int    n      = (argc > 1) ? atoi(argv[1]) : DEFAULT_N;
    int    max_it = (argc > 2) ? atoi(argv[2]) : DEFAULT_ITERS;
    double h      = 1.0 / (n + 1);

    double *u     = calloc((size_t)(n + 2), sizeof(double));
    double *u_new = calloc((size_t)(n + 2), sizeof(double));
    double *f     = malloc((size_t)(n + 2) * sizeof(double));

    initialize_grid(u, n);
    compute_rhs(f, n, h);

    double t_start = wall_time();

    int iter = 0;
    for (; iter < max_it; iter++) {
        for (int i = 1; i <= n; i++)
            u_new[i] = 0.5 * (u[i - 1] + u[i + 1] + h * h * f[i]);

        double diff = rms_residual(u_new, f, n, h);

        double *tmp = u; u = u_new; u_new = tmp;

        if (diff < TOLERANCE) break;
    }

    double elapsed_ms = (wall_time() - t_start) * 1000.0;

    fprintf(stderr, "serial n=%-6d iters=%-6d error=%.4e  time=%.3f ms\n",
            n, iter + 1, max_error(u, n, h), elapsed_ms);
    printf("%.3f\n", elapsed_ms);

    free(u); free(u_new); free(f);
    return 0;
}