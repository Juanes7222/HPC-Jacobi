#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <semaphore.h>
#include "poisson.h"

#define DEFAULT_N      2000
#define DEFAULT_ITERS  5000
#define DEFAULT_PROCS  4
#define TOLERANCE      1e-6

/*
 * Fork-once architecture: all worker processes are created once before the
 * main loop and synchronize each iteration using semaphores in shared memory.
 * This mirrors the pthread_barrier model in threads.c, making the comparison
 * between the two parallelism strategies structurally equivalent.
 *
 * Synchronization model (asymmetric, same logic as thread 0 in threads.c):
 *   workers_done -- workers 1..p-1 post once; worker 0 waits p-1 times.
 *   go           -- worker 0 posts p-1 times; workers 1..p-1 each wait once.
 *
 * Worker 0 acts as coordinator: waits for all peers, computes the global RMS
 * residual over the full u_new, checks convergence, and flips the buffers.
 *
 * Buffer swap: instead of swapping pointers (which are local to each process),
 * a shared flip flag determines which buffer is u (read) and which is u_new
 * (write) in each iteration. After worker 0 flips the flag, all workers see
 * the updated state before the next iteration begins.
 *
 * Shared memory layout (single mmap allocation):
 *
 *   [ buf_a[0..n+1] | buf_b[0..n+1] | f[0..n+1] | SharedControl ]
 */

typedef struct {
    sem_t workers_done;
    sem_t go;
    int   flip;
    int   converged;
    int   iters_done;
} SharedControl;

typedef struct {
    double        *buf_a;
    double        *buf_b;
    double        *f;
    SharedControl *ctrl;
} Shared;

static Shared alloc_shared(int n) {
    size_t arr_sz = (size_t)(n + 2) * sizeof(double);
    size_t total  = 3 * arr_sz + sizeof(SharedControl);

    char *base = mmap(NULL, total, PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) { perror("mmap"); exit(1); }

    Shared s;
    s.buf_a = (double *)(base);
    s.buf_b = (double *)(base + arr_sz);
    s.f     = (double *)(base + 2 * arr_sz);
    s.ctrl  = (SharedControl *)(base + 3 * arr_sz);
    return s;
}

static void free_shared(Shared s, int n) {
    size_t arr_sz = (size_t)(n + 2) * sizeof(double);
    munmap(s.buf_a, 3 * arr_sz + sizeof(SharedControl));
}

int main(int argc, char *argv[]) {
    int    n         = (argc > 1) ? atoi(argv[1]) : DEFAULT_N;
    int    max_iters = (argc > 2) ? atoi(argv[2]) : DEFAULT_ITERS;
    int    n_procs   = (argc > 3) ? atoi(argv[3]) : DEFAULT_PROCS;
    double h         = 1.0 / (n + 1);

    Shared s = alloc_shared(n);

    initialize_grid(s.buf_a, n);
    initialize_grid(s.buf_b, n);
    compute_rhs(s.f, n, h);

    /* pshared=1: semaphores are shared across forked processes. */
    sem_init(&s.ctrl->workers_done, 1, 0);
    sem_init(&s.ctrl->go,           1, 0);
    s.ctrl->flip       = 0;
    s.ctrl->converged  = 0;
    s.ctrl->iters_done = 0;

    int chunk = n / n_procs;

    double t_start = wall_time();

    pid_t *pids = malloc((size_t)n_procs * sizeof(pid_t));

    for (int p = 0; p < n_procs; p++) {
        int start = p * chunk + 1;
        int end   = (p == n_procs - 1) ? n : (p + 1) * chunk;

        pids[p] = fork();
        if (pids[p] < 0) { perror("fork"); exit(1); }

        if (pids[p] == 0) {
            for (int iter = 0; iter < max_iters; iter++) {
                double *u_read  = (s.ctrl->flip == 0) ? s.buf_a : s.buf_b;
                double *u_write = (s.ctrl->flip == 0) ? s.buf_b : s.buf_a;

                for (int i = start; i <= end; i++)
                    u_write[i] = 0.5 * (u_read[i-1] + u_read[i+1]
                                        + h * h * s.f[i]);

                if (p == 0) {
                    /* Wait for all peers to finish writing u_new before
                     * calling rms_residual, which reads neighbor values
                     * across chunk boundaries. */
                    for (int k = 1; k < n_procs; k++)
                        sem_wait(&s.ctrl->workers_done);

                    s.ctrl->converged  = (rms_residual(u_write, s.f, n, h)
                                          < TOLERANCE);
                    s.ctrl->iters_done = iter + 1;
                    s.ctrl->flip      ^= 1;

                    for (int k = 1; k < n_procs; k++)
                        sem_post(&s.ctrl->go);
                } else {
                    sem_post(&s.ctrl->workers_done);
                    sem_wait(&s.ctrl->go);
                }

                if (s.ctrl->converged) break;
            }
            exit(0);
        }
    }

    for (int p = 0; p < n_procs; p++)
        waitpid(pids[p], NULL, 0);

    double elapsed_ms = (wall_time() - t_start) * 1000.0;

    /* After the last flip, the solution is on the current u_read side. */
    double *u_final = (s.ctrl->flip == 0) ? s.buf_a : s.buf_b;

    fprintf(stderr,
            "processes n=%-6d iters=%-6d p=%-2d  error=%.4e  time=%.3f ms\n",
            n, s.ctrl->iters_done, n_procs,
            max_error(u_final, n, h), elapsed_ms);
    printf("%.3f\n", elapsed_ms);

    sem_destroy(&s.ctrl->workers_done);
    sem_destroy(&s.ctrl->go);
    free(pids);
    free_shared(s, n);
    return 0;
}