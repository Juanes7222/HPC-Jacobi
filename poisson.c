#include "poisson.h"
#include <math.h>
#include <string.h>
#include <time.h>

/**
 * Returns wall-clock time in seconds (CLOCK_MONOTONIC).
 */
double wall_time(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/**
 * Zeroes u[0..n+1], including boundary nodes.
 */
void initialize_grid(double *u, int n) {
    memset(u, 0, (size_t)(n + 2) * sizeof(double));
}

/**
 * Fills f[1..n] = sin(pi * i * h).
 * Corresponds to -u'' = f whose exact solution is u(x) = sin(pi*x)/pi^2.
 */
void compute_rhs(double *f, int n, double h) {
    for (int i = 1; i <= n; i++)
        f[i] = sin(M_PI * i * h);
}

/**
 * Returns max-norm error against u_exact(x) = sin(pi*x)/pi^2 over [1..n].
 */
double max_error(const double *u, int n, double h) {
    double err = 0.0;
    for (int i = 1; i <= n; i++) {
        double d = fabs(u[i] - sin(M_PI * i * h) / (M_PI * M_PI));
        if (d > err) err = d;
    }
    return err;
}

/**
 * Returns max |a[i] - b[i]| for i in [from, to].
 * Used by each worker to compute its local contribution to the global diff.
 */
double local_max_diff(const double *a, const double *b, int from, int to) {
    double diff = 0.0;
    for (int i = from; i <= to; i++) {
        double d = fabs(a[i] - b[i]);
        if (d > diff) diff = d;
    }
    return diff;
}