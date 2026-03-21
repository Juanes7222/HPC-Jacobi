#ifndef POISSON_H
#define POISSON_H

double wall_time(void);
void   initialize_grid(double *u, int n);
void   compute_rhs(double *f, int n, double h);
double max_error(const double *u, int n, double h);
double local_max_diff(const double *a, const double *b, int from, int to);

#endif