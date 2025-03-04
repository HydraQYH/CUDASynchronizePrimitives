#include <iostream>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <cuda.h>
#include <cooperative_groups.h>
#include <cuda/atomic>
#include <cuda_profiler_api.h>

#define CUDACHECK(cmd)                                              \
  do {                                                              \
    cudaError_t e = cmd;                                            \
    if (e != cudaSuccess) {                                         \
      printf("Failed: Cuda error %s:%d '%s'\n", __FILE__, __LINE__, \
             cudaGetErrorString(e));                                \
      exit(EXIT_FAILURE);                                           \
    }                                                               \
  } while (0)

__device__ __forceinline__ unsigned int ld_cta(const unsigned int *ptr) {
  unsigned int ret;
  asm volatile ("ld.acquire.cta.global.u32 %0, [%1];"  : "=r"(ret) : "l"(ptr));
  return ret;
}

__device__ __forceinline__ void st_cta(unsigned int *ptr, unsigned int value) {
  asm ("st.release.cta.global.u32 [%0], %1;"  :: "l"(ptr), "r"(value) : "memory");
}

__device__ __forceinline__ unsigned int ld_gpu(const unsigned int *ptr) {
  unsigned int ret;
  asm volatile ("ld.acquire.gpu.global.u32 %0, [%1];"  : "=r"(ret) : "l"(ptr));
  return ret;
}

__device__ __forceinline__ void st_gpu(unsigned int *ptr, unsigned int value) {
  asm ("st.release.gpu.global.u32 [%0], %1;"  :: "l"(ptr), "r"(value) : "memory");
}

__device__ __forceinline__ unsigned int ld_sys(const unsigned int *ptr) {
  unsigned int ret;
  asm volatile ("ld.acquire.sys.global.u32 %0, [%1];"  : "=r"(ret) : "l"(ptr));
  return ret;
}

__device__ __forceinline__ void st_sys(unsigned int *ptr, unsigned int value) {
  asm ("st.release.sys.global.u32 [%0], %1;"  :: "l"(ptr), "r"(value) : "memory");
}

__global__ void dummy_kernel() {
  #if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 700
    for (int i = 0; i < 100; i++) __nanosleep(1000000);  // 100ms
  #else
    for (int i = 0; i < 100; i++) {
      long long int start = clock64();
      while (clock64() - start < 150000000);  // approximately 98.4ms on P40
    }
  #endif
}

void __global__ hot_potato_sync_cta_kernel(unsigned int* signal, unsigned int* loops) {
  constexpr unsigned int warp_size = 32;
  constexpr unsigned int threadblock_warp_count = 32;
  namespace cg = cooperative_groups;
  auto tid = cg::this_grid().thread_rank();
  auto warp_id = tid / warp_size;
  auto lane_id = tid % warp_size;
  auto local_warp_id = warp_id % threadblock_warp_count;

  if (lane_id == 0) {
    unsigned int loop_count = 0;
    if (local_warp_id == 0) {
      while (ld_gpu(signal) != warp_id) {
        loop_count++;
      }
    } else {
      while (ld_cta(signal) != warp_id) {
        loop_count++;
      }
    }

    if (local_warp_id != (threadblock_warp_count - 1)) {
      st_cta(signal, warp_id + 1);
    } else {
      st_gpu(signal, warp_id + 1);
    }
    loops[warp_id] = loop_count;
  }
  __syncwarp();
}

void __global__ hot_potato_sync_gpu_kernel(unsigned int* signal, unsigned int* loops) {
  constexpr unsigned int warp_size = 32;
  namespace cg = cooperative_groups;
  auto tid = cg::this_grid().thread_rank();
  auto warp_id = tid / warp_size;
  auto lane_id = tid % warp_size;
  if (lane_id == 0) {
    unsigned int loop_count = 0;
    while (ld_gpu(signal) != warp_id) {
      loop_count++;
    }
    st_gpu(signal, warp_id + 1);
    loops[warp_id] = loop_count;
  }
  __syncwarp();
}

void __global__ hot_potato_sync_sys_kernel(unsigned int* signal, unsigned int* loops) {
  constexpr unsigned int warp_size = 32;
  namespace cg = cooperative_groups;
  auto tid = cg::this_grid().thread_rank();
  auto warp_id = tid / warp_size;
  auto lane_id = tid % warp_size;
  if (lane_id == 0) {
    unsigned int loop_count = 0;
    while (ld_sys(signal) != warp_id) {
      loop_count++;
    }
    st_sys(signal, warp_id + 1);
    loops[warp_id] = loop_count;
  }
  __syncwarp();
}

void __global__ hot_potato_sync_volatile_kernel(volatile unsigned int* signal, unsigned int* loops) {
  constexpr unsigned int warp_size = 32;
  namespace cg = cooperative_groups;
  auto tid = cg::this_grid().thread_rank();
  auto warp_id = tid / warp_size;
  auto lane_id = tid % warp_size;
  if (lane_id == 0) {
    unsigned int loop_count = 0;
    while (*signal != warp_id) {
      loop_count++;
    }
    __threadfence();
    *signal = warp_id + 1;
    loops[warp_id] = loop_count;
  }
  __syncwarp();
}

void __global__ hot_potato_sync_volatile_fence_sys_kernel(volatile unsigned int* signal, unsigned int* loops) {
  constexpr unsigned int warp_size = 32;
  namespace cg = cooperative_groups;
  auto tid = cg::this_grid().thread_rank();
  auto warp_id = tid / warp_size;
  auto lane_id = tid % warp_size;
  if (lane_id == 0) {
    unsigned int loop_count = 0;
    while (*signal != warp_id) {
      loop_count++;
    }
    __threadfence_system();
    *signal = warp_id + 1;
    loops[warp_id] = loop_count;
  }
  __syncwarp();
}

void __global__ hot_potato_sync_atomic_ref_kernel(unsigned int* signal, unsigned int* loops) {
  constexpr unsigned int warp_size = 32;
  cuda::atomic_ref<unsigned int, cuda::thread_scope_device> ref_signal(*signal);
  namespace cg = cooperative_groups;
  auto tid = cg::this_grid().thread_rank();
  auto warp_id = tid / warp_size;
  auto lane_id = tid % warp_size;
  if (lane_id == 0) {
    unsigned int loop_count = 0;
    while (ref_signal.load(cuda::memory_order_acquire) != warp_id) {
      loop_count++;
    }
    ref_signal.store(warp_id + 1, cuda::memory_order_release);
    loops[warp_id] = loop_count;
  }
  __syncwarp();
}

int main(void) {
  constexpr size_t warpCount = 1 << 20;
  constexpr unsigned int blockDimX = 1024;
  constexpr unsigned int gridDimX = warpCount / (blockDimX / 32);

  cudaStream_t stream;
  CUDACHECK(cudaStreamCreate(&stream));

  thrust::device_vector<unsigned int> counts(warpCount * sizeof(unsigned int));
  thrust::device_vector<unsigned int> signal(4096);

  dim3 grid(gridDimX, 1, 1);
  dim3 block(blockDimX, 1, 1);
  CUDACHECK(cudaProfilerStart());

  constexpr int warmup_iters = 2;
  constexpr int num_iters = 10;
  cudaEvent_t start, stop;
  CUDACHECK(cudaEventCreate(&start));
  CUDACHECK(cudaEventCreate(&stop));

  // Test cta sync time
  dummy_kernel<<<1, 1, 0, stream>>>();
  for (int i = 0; i < warmup_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_cta_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(start, stream));
  for (int i = 0; i < num_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_cta_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(stop, stream));
  CUDACHECK(cudaStreamSynchronize(stream));
  float cta_ms = 0.0;
  CUDACHECK(cudaEventElapsedTime(&cta_ms, start, stop));

  // Test gpu sync time
  dummy_kernel<<<1, 1, 0, stream>>>();
  for (int i = 0; i < warmup_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_gpu_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(start, stream));
  for (int i = 0; i < num_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_gpu_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(stop, stream));
  CUDACHECK(cudaStreamSynchronize(stream));
  float gpu_ms = 0.0;
  CUDACHECK(cudaEventElapsedTime(&gpu_ms, start, stop));

  // Test sys sync time
  dummy_kernel<<<1, 1, 0, stream>>>();
  for (int i = 0; i < warmup_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_sys_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(start, stream));
  for (int i = 0; i < num_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_sys_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(stop, stream));
  CUDACHECK(cudaStreamSynchronize(stream));
  float sys_ms = 0.0;
  CUDACHECK(cudaEventElapsedTime(&sys_ms, start, stop));

  // Test volatile + __threadfence() time
  dummy_kernel<<<1, 1, 0, stream>>>();
  for (int i = 0; i < warmup_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_volatile_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(start, stream));
  for (int i = 0; i < num_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_volatile_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(stop, stream));
  CUDACHECK(cudaStreamSynchronize(stream));
  float volatile_ms = 0.0;
  CUDACHECK(cudaEventElapsedTime(&volatile_ms, start, stop));

  // Test volatile + __threadfence_system() time
  dummy_kernel<<<1, 1, 0, stream>>>();
  for (int i = 0; i < warmup_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_volatile_fence_sys_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(start, stream));
  for (int i = 0; i < num_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_volatile_fence_sys_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(stop, stream));
  CUDACHECK(cudaStreamSynchronize(stream));
  float volatile_fence_sys_ms = 0.0;
  CUDACHECK(cudaEventElapsedTime(&volatile_fence_sys_ms, start, stop));

  // Test atomic_ref time
  dummy_kernel<<<1, 1, 0, stream>>>();
  for (int i = 0; i < warmup_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_atomic_ref_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(start, stream));
  for (int i = 0; i < num_iters; i++) {
    CUDACHECK(cudaMemsetAsync(signal.data().get(), 0, 4096, stream));
    hot_potato_sync_atomic_ref_kernel<<<grid, block, 0, stream>>>(signal.data().get(), counts.data().get());
  }
  CUDACHECK(cudaEventRecord(stop, stream));
  CUDACHECK(cudaStreamSynchronize(stream));
  float atomic_ref_ms = 0.0;
  CUDACHECK(cudaEventElapsedTime(&atomic_ref_ms, start, stop));

  std::cout << "CTA Scope Sync Time: " << cta_ms / static_cast<float>(num_iters)
    << " ms\nGPU Scope Sync Time: " << gpu_ms / static_cast<float>(num_iters)
    << " ms\nSYS Scope Sync Time: " << sys_ms / static_cast<float>(num_iters)
    << " ms\nVolatile + Fence Sync Time:" << volatile_ms / static_cast<float>(num_iters)
    << " ms\nVolatile + Fence(System) Sync Time:" << volatile_fence_sys_ms / static_cast<float>(num_iters)
    << " ms\natomic_ref Sync Time:" << atomic_ref_ms / static_cast<float>(num_iters)
    << std::endl;

  CUDACHECK(cudaProfilerStop());
  CUDACHECK(cudaEventDestroy(stop));
  CUDACHECK(cudaEventDestroy(start));
  CUDACHECK(cudaStreamDestroy(stream));
  return 0;
}

