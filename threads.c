#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include "poisson.h"

#define DEFAULT_N        2000
#define DEFAULT_ITERS    5000
#define DEFAULT_THREADS  4
#define TOLERANCE        1e-8

static double           *g_u;
static double           *g_u_new;
static const double     *g_f;
static double            g_h;
static int               g_n_threads;
static double           *g_local_diff;
static double            g_global_diff;
static int               g_converged;
static int               g_iters_done;
static pthread_barrier_t g_barrier;

typedef struct {
    int id;
    int start;
    int end;
    int max_iters;
} ThreadArgs;

static void *worker(void *arg) {
    ThreadArgs *t = (ThreadArgs *)arg;

    for (int iter = 0; iter < t->max_iters; iter++) {
        for (int i = t->start; i <= t->end; i++)
            g_u_new[i] = 0.5 * (g_u[i - 1] + g_u[i + 1] + g_h * g_h * g_f[i]);

        g_local_diff[t->id] = local_max_diff(g_u_new, g_u, t->start, t->end);

        pthread_barrier_wait(&g_barrier);

        if (t->id == 0) {
            g_global_diff = 0.0;
            for (int k = 0; k < g_n_threads; k++)
                if (g_local_diff[k] > g_global_diff)
                    g_global_diff = g_local_diff[k];

            g_converged  = (g_global_diff < TOLERANCE);
            g_iters_done = iter + 1;

            double *tmp = g_u; g_u = g_u_new; g_u_new = tmp;
        }

        pthread_barrier_wait(&g_barrier);

        if (g_converged) break;
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    int    n         = (argc > 1) ? atoi(argv[1]) : DEFAULT_N;
    int    max_iters = (argc > 2) ? atoi(argv[2]) : DEFAULT_ITERS;
    int    n_threads = (argc > 3) ? atoi(argv[3]) : DEFAULT_THREADS;
    double h         = 1.0 / (n + 1);

    double *u     = calloc((size_t)(n + 2), sizeof(double));
    double *u_new = calloc((size_t)(n + 2), sizeof(double));
    double *f     = malloc((size_t)(n + 2) * sizeof(double));

    initialize_grid(u, n);
    compute_rhs(f, n, h);

    g_u          = u;
    g_u_new      = u_new;
    g_f          = f;
    g_h          = h;
    g_n_threads  = n_threads;
    g_converged  = 0;
    g_iters_done = 0;
    g_local_diff = calloc((size_t)n_threads, sizeof(double));

    pthread_barrier_init(&g_barrier, NULL, (unsigned)n_threads);

    ThreadArgs *args = malloc((size_t)n_threads * sizeof(ThreadArgs));
    pthread_t  *tids = malloc((size_t)n_threads * sizeof(pthread_t));

    int chunk = n / n_threads;
    for (int i = 0; i < n_threads; i++) {
        args[i].id        = i;
        args[i].start     = i * chunk + 1;
        args[i].end       = (i == n_threads - 1) ? n : (i + 1) * chunk;
        args[i].max_iters = max_iters;
    }

    double t_start = wall_time();

    for (int i = 0; i < n_threads; i++)
        pthread_create(&tids[i], NULL, worker, &args[i]);
    for (int i = 0; i < n_threads; i++)
        pthread_join(tids[i], NULL);

    double elapsed_ms = (wall_time() - t_start) * 1000.0;

    fprintf(stderr, "threads n=%-6d iters=%-6d t=%-2d  error=%.4e  time=%.3f ms\n",
            n, g_iters_done, n_threads, max_error(g_u, n, h), elapsed_ms);
    printf("%.3f\n", elapsed_ms);

    pthread_barrier_destroy(&g_barrier);
    free(args); free(tids); free(g_local_diff);
    free(u); free(u_new); free(f);
    return 0;
}