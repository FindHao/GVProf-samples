#include <cstdio>
#include <omp.h>
#include <cuda.h>
#include <cuda_runtime.h>
#ifdef USE_MPI
#include <mpi.h>
#endif

#include "common.h"


static const size_t N = 1000;


void init(int *p, size_t size) {
  for (size_t i = 0; i < size; ++i) {
    p[i] = i;
  }
}


void output(int *p, size_t size) {
  for (size_t i = 0; i < size; ++i) {
    printf("index %zu: %d\n", i, p[i]);
  }
}


__global__
void vecAdd(int *l, int *r, int *p, size_t N) {
  size_t idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < N) {
    p[idx] = l[idx] + r[idx];
  }
}


__global__
void vecAdd_eq(int *l, int *r, int *p, size_t N) {
  size_t idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < N) {
    l[idx] = r[idx];
  }
}


__global__
void vecAdd_odd(int *l, int *r, int *p, size_t N) {
  size_t idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < N && idx % 2) {
    p[idx] = l[idx] + r[idx];
  }
}


int main(int argc, char *argv[]) {
#ifdef USE_MPI
  int numtasks, rank;
  MPI_Init(&argc, &argv);
  MPI_Comm_size(MPI_COMM_WORLD, &numtasks);
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  printf("MPI task %d/%d\n", rank, numtasks);
#endif

  // Init device
  int device_id = 0;
  if (argc > 1) {
    device_id = atoi(argv[1]);
  }
  cuda_init_device(device_id);

  #pragma omp parallel
  {
    int l[N], r[N], p[N];
    int *dl, *dr, *dp;

    init(l, N);
    init(r, N);

    RUNTIME_API_CALL(cudaMalloc(&dl, N * sizeof(int)));
    RUNTIME_API_CALL(cudaMalloc(&dr, N * sizeof(int)));
    RUNTIME_API_CALL(cudaMalloc(&dp, N * sizeof(int)));

    RUNTIME_API_CALL(cudaMemcpy(dl, l, N * sizeof(int), cudaMemcpyHostToDevice));
    RUNTIME_API_CALL(cudaMemcpy(dr, r, N * sizeof(int), cudaMemcpyHostToDevice));
    
    // 1. redundant h2d copy
    RUNTIME_API_CALL(cudaMemcpy(dl, l, N * sizeof(int), cudaMemcpyHostToDevice));
    
    // 2. redundant d2d copy
    // partial overwrite
    RUNTIME_API_CALL(cudaMemcpy(dl, dr, N / 2 * sizeof(int), cudaMemcpyDeviceToDevice));

    // non-zero offset redundant write
    RUNTIME_API_CALL(cudaMemcpy(dl + N / 2, dl + N / 2, N / 2 * sizeof(int), cudaMemcpyDeviceToDevice));

    size_t threads = 256;
    size_t blocks = (N - 1) / threads + 1;

    vecAdd<<<blocks, threads>>>(dl, dr, dp, N);
    
    // 3. kernel to kernel duplicate
    vecAdd_eq<<<blocks, threads>>>(dp, dp, dp, N);

    // 4. kernel to kernel duplicate, partial write
    vecAdd_odd<<<blocks, threads>>>(dl, dr, dp, N);

    RUNTIME_API_CALL(cudaMemcpy(p, dp, N * sizeof(int), cudaMemcpyDeviceToHost));

    RUNTIME_API_CALL(cudaFree(dl));
    RUNTIME_API_CALL(cudaFree(dr));
    RUNTIME_API_CALL(cudaFree(dp));

#ifdef OUTPUT
    #pragma omp critical
    {
      printf("Thread %d\n", omp_get_thread_num());
      output(p, N);
    }
#endif
  }

  cudaDeviceSynchronize();

#ifdef USE_MPI
  MPI_Finalize();
#endif
  return 0;
}
