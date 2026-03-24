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
 * Fills f[1..n] = -x*(x+3)*exp(x) at x = i*h.
 * Forcing term for -u'' = f whose exact solution is u(x) = x*(x-1)*exp(x).
 */
void compute_rhs(double *f, int n, double h) {
    for (int i = 1; i <= n; i++) {
        double x = i * h;
        f[i] = -x * (x + 3.0) * exp(x);
    }
}

/**
 * Returns max-norm error against u_exact(x) = x*(x-1)*exp(x) over [1..n].
 */
double max_error(const double *u, int n, double h) {
    double err = 0.0;
    for (int i = 1; i <= n; i++) {
        double x = i * h;
        double d = fabs(u[i] - x * (x - 1.0) * exp(x));
        if (d > err) err = d;
    }
    return err;
}

/**
 * Returns RMS norm of the residual r = A*u - f over [1..n].
 * r[i] = (-u[i-1] + 2*u[i] - u[i+1]) / h^2 - f[i].
 * Convergence criterion recommended by Burkardt (2011), section 9.
 */
double rms_residual(const double *u, const double *f, int n, double h) {
    double h2  = h * h;
    double rss = 0.0;
    for (int i = 1; i <= n; i++) {
        double r = (-u[i - 1] + 2.0 * u[i] - u[i + 1]) / h2 - f[i];
        rss += r * r;
    }
    return sqrt(rss / n);
}