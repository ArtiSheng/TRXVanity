__device__  int secp256k1_scalar_is_zero(const secp256k1_scalar* __restrict__ a);

__device__  int secp256k1_scalar_reduce(secp256k1_scalar* __restrict__ r, uint32_t overflow);

__device__  int secp256k1_scalar_check_overflow(const secp256k1_scalar* __restrict__ a);

__device__  void secp256k1_scalar_set_int(secp256k1_scalar* r, unsigned int v);

__device__  void secp256k1_scalar_get_b32(unsigned char* bin, const secp256k1_scalar* __restrict__ a);

__device__  void secp256k1_scalar_set_b32(secp256k1_scalar* __restrict__ r, const unsigned char* __restrict__ b32, int* __restrict__ overflow);

__device__ __noinline__ int secp256k1_scalar_set_b32_seckey(secp256k1_scalar* r, const unsigned char* __restrict__ bin);

__device__ __noinline__ void secp256k1_scalar_cmov(secp256k1_scalar* r, const secp256k1_scalar* a, int flag);

__device__  int secp256k1_scalar_add(secp256k1_scalar* r, const secp256k1_scalar* __restrict__ a, const secp256k1_scalar* __restrict__ b);

__device__  void secp256k1_scalar_clear(secp256k1_scalar* r);

__device__  unsigned int secp256k1_scalar_get_bits(const secp256k1_scalar* __restrict__ a, unsigned int offset, unsigned int count);

__device__  int secp256k1_scalar_shr_int(secp256k1_scalar* __restrict__ r, int n);

__device__ void secp256k1_scalar_mul(secp256k1_scalar* r, const secp256k1_scalar* a, const secp256k1_scalar* b);
