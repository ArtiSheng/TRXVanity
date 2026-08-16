#include "fastpbkdf2.cuh"




/* --- SHA512 --- */
#define _name       sha512
#define _blocksz    CF_SHA512_BLOCKSZ
#define _hashsz     CF_SHA512_HASHSZ
#define _ctx        cf_sha512_context
#define _blocktype  cf_sha512_block
#define _cvt_input  sha512_convert_input
#define _cvt_output sha512_convert_output
#define _init       cf_sha512_init
#define _update     cf_sha512_update
#define _final      cf_sha512_final
#define _transform  sha512_raw_transform
#define _xor        sha512_xor

#define CF_SHA512_BLOCKSZ 128
#define CF_SHA512_HASHSZ 64

#define MIN(a, b) ((a) > (b)) ? (b) : (a)
#define rotl32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))
#define rotr32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define rotr64(x, n) (((x) >> (n)) | ((x) << (64 - (n))))

// Device helper: read32_be.
__device__ __forceinline__ uint32_t read32_be(const uint8_t x[4])
{

    uint32_t r = (uint32_t)(x[0]) << 24 |
        (uint32_t)(x[1]) << 16 |
        (uint32_t)(x[2]) << 8 |
        (uint32_t)(x[3]);
    return r;

}

// Device helper: write32_be.
__device__ __forceinline__ void write32_be(uint32_t n, uint8_t out[4])
{

    out[0] = (n >> 24) & 0xff;
    out[1] = (n >> 16) & 0xff;
    out[2] = (n >> 8) & 0xff;
    out[3] = n & 0xff;

}

// Device helper: read64_be.
__device__ __forceinline__ uint64_t read64_be(const uint8_t x[8])
{

    uint64_t r = (uint64_t)(x[0]) << 56 |
        (uint64_t)(x[1]) << 48 |
        (uint64_t)(x[2]) << 40 |
        (uint64_t)(x[3]) << 32 |
        (uint64_t)(x[4]) << 24 |
        (uint64_t)(x[5]) << 16 |
        (uint64_t)(x[6]) << 8 |
        (uint64_t)(x[7]);
    return r;

}

// Device helper: write64_be.
__device__ __forceinline__ void write64_be(uint64_t n, uint8_t out[8])
{

    write32_be((n >> 32) & 0xffffffff, out);
    write32_be(n & 0xffffffff, out + 4);

}

/* --- Optional OpenMP parallelisation of consecutive blocks --- */
#ifdef WITH_OPENMP
# define OPENMP_PARALLEL_FOR _Pragma("omp parallel for")
#else
# define OPENMP_PARALLEL_FOR
#endif

/* Prepare block (of blocksz bytes) to contain md padding denoting a msg-size
 * message (in bytes).  block has a prefix of used bytes.
 *
 * Message length is expressed in 32 bits (so suitable for sha1, sha256, sha512). */
__device__ __forceinline__ void md_pad(uint8_t* block, size_t blocksz, size_t used, size_t msg)
{
    memset(block + used, 0, blocksz - used - 4);
    block[used] = 0x80;
    block += blocksz - 4;
    write32_be((uint32_t)(msg * 8), block);
}


typedef struct
{
    uint64_t H[8];
    uint8_t partial[CF_SHA512_BLOCKSZ];
    uint32_t blocks;
    size_t npartial;
} cf_sha512_context;

typedef uint64_t cf_sha512_block[16];




typedef void (*cf_blockwise_in_fn)(void* ctx, const uint8_t* data);

__device__ __forceinline__ void cf_blockwise_accumulate(uint8_t* partial, size_t* npartial, size_t nblock,
    const void* inp, size_t nbytes,
    cf_blockwise_in_fn process,
    void* ctx)
{
    const uint8_t* bufin = reinterpret_cast<const uint8_t*>(inp);
    assert(partial && *npartial < nblock);
    assert(inp || !nbytes);
    assert(process && ctx);

    /* If we have partial data, copy in to buffer. */
    if (*npartial && nbytes)
    {
        size_t space = nblock - *npartial;
        size_t taken = MIN(space, nbytes);

        memcpy(partial + *npartial, bufin, taken);

        bufin += taken;
        nbytes -= taken;
        *npartial += taken;

        /* If that gives us a full block, process it. */
        if (*npartial == nblock)
        {
            process(ctx, partial);
            *npartial = 0;
        }
    }

    /* now nbytes < nblock or *npartial == 0. */

    /* If we have a full block of data, process it directly. */
    while (nbytes >= nblock)
    {
        /* Partial buffer must be empty, or we're ignoring extant data */
        assert(*npartial == 0);

        process(ctx, bufin);
        bufin += nblock;
        nbytes -= nblock;
    }

    /* Finally, if we have remaining data, buffer it. */
    while (nbytes)
    {
        size_t space = nblock - *npartial;
        size_t taken = MIN(space, nbytes);

        memcpy(partial + *npartial, bufin, taken);

        bufin += taken;
        nbytes -= taken;
        *npartial += taken;

        /* If we started with *npartial, we must have copied it
         * in first. */
        assert(*npartial < nblock);
    }
}

__device__ __forceinline__ void cf_blockwise_acc_byte(uint8_t* partial, size_t* npartial,
    size_t nblock,
    uint8_t byte, size_t nbytes,
    cf_blockwise_in_fn process,
    void* ctx)
{
    /* only memset the whole of the block once */
    int filled = 0;

    while (nbytes)
    {
        size_t start = *npartial;
        size_t count = MIN(nbytes, nblock - start);

        if (!filled)
            memset(partial + start, byte, count);

        if (start == 0 && count == nblock)
            filled = 1;

        if (start + count == nblock)
        {
            process(ctx, partial);
            *npartial = 0;
        }
        else {
            *npartial += count;
        }

        nbytes -= count;
    }
}

__device__ __forceinline__ void cf_blockwise_acc_pad(uint8_t* partial, size_t* npartial,
    size_t nblock,
    uint8_t fbyte, uint8_t mbyte, uint8_t lbyte,
    size_t nbytes,
    cf_blockwise_in_fn process,
    void* ctx)
{

    switch (nbytes)
    {
    case 0: break;
    case 1: fbyte ^= lbyte;
        cf_blockwise_accumulate(partial, npartial, nblock, &fbyte, 1, process, ctx);
        break;
    case 2:
        cf_blockwise_accumulate(partial, npartial, nblock, &fbyte, 1, process, ctx);
        cf_blockwise_accumulate(partial, npartial, nblock, &lbyte, 1, process, ctx);
        break;
    default:
        cf_blockwise_accumulate(partial, npartial, nblock, &fbyte, 1, process, ctx);

        /* If the middle and last bytes differ, then process the last byte separately.
         * Otherwise, just extend the middle block size. */
        if (lbyte != mbyte)
        {
            cf_blockwise_acc_byte(partial, npartial, nblock, mbyte, nbytes - 2, process, ctx);
            cf_blockwise_accumulate(partial, npartial, nblock, &lbyte, 1, process, ctx);
        }
        else {
            cf_blockwise_acc_byte(partial, npartial, nblock, mbyte, nbytes - 1, process, ctx);
        }

        break;
    }
}



// Device helper: cf_sha512_init.
__device__ __forceinline__ void cf_sha512_init(cf_sha512_context* ctx)
{
    memset(ctx, 0, sizeof * ctx);
    ctx->H[0] = UINT64_C(0x6a09e667f3bcc908);
    ctx->H[1] = UINT64_C(0xbb67ae8584caa73b);
    ctx->H[2] = UINT64_C(0x3c6ef372fe94f82b);
    ctx->H[3] = UINT64_C(0xa54ff53a5f1d36f1);
    ctx->H[4] = UINT64_C(0x510e527fade682d1);
    ctx->H[5] = UINT64_C(0x9b05688c2b3e6c1f);
    ctx->H[6] = UINT64_C(0x1f83d9abfb41bd6b);
    ctx->H[7] = UINT64_C(0x5be0cd19137e2179);
}

__device__ __forceinline__ void sha512_raw_transform(const uint64_t state_in[8],
    uint64_t state_out[8],
    const cf_sha512_block inp)
{
    uint64_t W[16];

    uint64_t a = state_in[0],
        b = state_in[1],
        c = state_in[2],
        d = state_in[3],
        e = state_in[4],
        f = state_in[5],
        g = state_in[6],
        h = state_in[7];

# define CH(x, y, z) ((z) ^ ((x) & ((y) ^ (z))))
# define MAJ(x, y, z) (((x) & (y)) | ((z) & ((x) ^ (y))))
# define BSIG0(x) (rotr64((x), 28) ^ rotr64((x), 34) ^ rotr64((x), 39))
# define BSIG1(x) (rotr64((x), 14) ^ rotr64((x), 18) ^ rotr64((x), 41))
# define SSIG0(x) (rotr64((x), 1) ^ rotr64((x), 8) ^ ((x) >> 7))
# define SSIG1(x) (rotr64((x), 19) ^ rotr64((x), 61) ^ ((x) >> 6))

# define R(a, b, c, d, e, f, g, h, wi, K)                          \
      do {                                                         \
        uint64_t T1 = h + BSIG1(e) + CH(e, f, g) + K + (wi);       \
        uint64_t T2 = BSIG0(a) + MAJ(a, b, c);                     \
        d += T1;                                                   \
        h = T1 + T2;                                               \
      } while (0)

# define Wi(i) (W[i] = inp[i])
# define Wn(i) (W[(i)&15] = SSIG1(W[((i)-2)&15]) + W[((i)-7)&15] + SSIG0(W[((i)-15)&15]) + W[((i)-16)&15])

    R(a, b, c, d, e, f, g, h, Wi(0),  UINT64_C(0x428a2f98d728ae22));
    R(h, a, b, c, d, e, f, g, Wi(1),  UINT64_C(0x7137449123ef65cd));
    R(g, h, a, b, c, d, e, f, Wi(2),  UINT64_C(0xb5c0fbcfec4d3b2f));
    R(f, g, h, a, b, c, d, e, Wi(3),  UINT64_C(0xe9b5dba58189dbbc));
    R(e, f, g, h, a, b, c, d, Wi(4),  UINT64_C(0x3956c25bf348b538));
    R(d, e, f, g, h, a, b, c, Wi(5),  UINT64_C(0x59f111f1b605d019));
    R(c, d, e, f, g, h, a, b, Wi(6),  UINT64_C(0x923f82a4af194f9b));
    R(b, c, d, e, f, g, h, a, Wi(7),  UINT64_C(0xab1c5ed5da6d8118));
    R(a, b, c, d, e, f, g, h, Wi(8),  UINT64_C(0xd807aa98a3030242));
    R(h, a, b, c, d, e, f, g, Wi(9),  UINT64_C(0x12835b0145706fbe));
    R(g, h, a, b, c, d, e, f, Wi(10), UINT64_C(0x243185be4ee4b28c));
    R(f, g, h, a, b, c, d, e, Wi(11), UINT64_C(0x550c7dc3d5ffb4e2));
    R(e, f, g, h, a, b, c, d, Wi(12), UINT64_C(0x72be5d74f27b896f));
    R(d, e, f, g, h, a, b, c, Wi(13), UINT64_C(0x80deb1fe3b1696b1));
    R(c, d, e, f, g, h, a, b, Wi(14), UINT64_C(0x9bdc06a725c71235));
    R(b, c, d, e, f, g, h, a, Wi(15), UINT64_C(0xc19bf174cf692694));

    R(a, b, c, d, e, f, g, h, Wn(16), UINT64_C(0xe49b69c19ef14ad2));
    R(h, a, b, c, d, e, f, g, Wn(17), UINT64_C(0xefbe4786384f25e3));
    R(g, h, a, b, c, d, e, f, Wn(18), UINT64_C(0x0fc19dc68b8cd5b5));
    R(f, g, h, a, b, c, d, e, Wn(19), UINT64_C(0x240ca1cc77ac9c65));
    R(e, f, g, h, a, b, c, d, Wn(20), UINT64_C(0x2de92c6f592b0275));
    R(d, e, f, g, h, a, b, c, Wn(21), UINT64_C(0x4a7484aa6ea6e483));
    R(c, d, e, f, g, h, a, b, Wn(22), UINT64_C(0x5cb0a9dcbd41fbd4));
    R(b, c, d, e, f, g, h, a, Wn(23), UINT64_C(0x76f988da831153b5));
    R(a, b, c, d, e, f, g, h, Wn(24), UINT64_C(0x983e5152ee66dfab));
    R(h, a, b, c, d, e, f, g, Wn(25), UINT64_C(0xa831c66d2db43210));
    R(g, h, a, b, c, d, e, f, Wn(26), UINT64_C(0xb00327c898fb213f));
    R(f, g, h, a, b, c, d, e, Wn(27), UINT64_C(0xbf597fc7beef0ee4));
    R(e, f, g, h, a, b, c, d, Wn(28), UINT64_C(0xc6e00bf33da88fc2));
    R(d, e, f, g, h, a, b, c, Wn(29), UINT64_C(0xd5a79147930aa725));
    R(c, d, e, f, g, h, a, b, Wn(30), UINT64_C(0x06ca6351e003826f));
    R(b, c, d, e, f, g, h, a, Wn(31), UINT64_C(0x142929670a0e6e70));
    R(a, b, c, d, e, f, g, h, Wn(32), UINT64_C(0x27b70a8546d22ffc));
    R(h, a, b, c, d, e, f, g, Wn(33), UINT64_C(0x2e1b21385c26c926));
    R(g, h, a, b, c, d, e, f, Wn(34), UINT64_C(0x4d2c6dfc5ac42aed));
    R(f, g, h, a, b, c, d, e, Wn(35), UINT64_C(0x53380d139d95b3df));
    R(e, f, g, h, a, b, c, d, Wn(36), UINT64_C(0x650a73548baf63de));
    R(d, e, f, g, h, a, b, c, Wn(37), UINT64_C(0x766a0abb3c77b2a8));
    R(c, d, e, f, g, h, a, b, Wn(38), UINT64_C(0x81c2c92e47edaee6));
    R(b, c, d, e, f, g, h, a, Wn(39), UINT64_C(0x92722c851482353b));
    R(a, b, c, d, e, f, g, h, Wn(40), UINT64_C(0xa2bfe8a14cf10364));
    R(h, a, b, c, d, e, f, g, Wn(41), UINT64_C(0xa81a664bbc423001));
    R(g, h, a, b, c, d, e, f, Wn(42), UINT64_C(0xc24b8b70d0f89791));
    R(f, g, h, a, b, c, d, e, Wn(43), UINT64_C(0xc76c51a30654be30));
    R(e, f, g, h, a, b, c, d, Wn(44), UINT64_C(0xd192e819d6ef5218));
    R(d, e, f, g, h, a, b, c, Wn(45), UINT64_C(0xd69906245565a910));
    R(c, d, e, f, g, h, a, b, Wn(46), UINT64_C(0xf40e35855771202a));
    R(b, c, d, e, f, g, h, a, Wn(47), UINT64_C(0x106aa07032bbd1b8));
    R(a, b, c, d, e, f, g, h, Wn(48), UINT64_C(0x19a4c116b8d2d0c8));
    R(h, a, b, c, d, e, f, g, Wn(49), UINT64_C(0x1e376c085141ab53));
    R(g, h, a, b, c, d, e, f, Wn(50), UINT64_C(0x2748774cdf8eeb99));
    R(f, g, h, a, b, c, d, e, Wn(51), UINT64_C(0x34b0bcb5e19b48a8));
    R(e, f, g, h, a, b, c, d, Wn(52), UINT64_C(0x391c0cb3c5c95a63));
    R(d, e, f, g, h, a, b, c, Wn(53), UINT64_C(0x4ed8aa4ae3418acb));
    R(c, d, e, f, g, h, a, b, Wn(54), UINT64_C(0x5b9cca4f7763e373));
    R(b, c, d, e, f, g, h, a, Wn(55), UINT64_C(0x682e6ff3d6b2b8a3));
    R(a, b, c, d, e, f, g, h, Wn(56), UINT64_C(0x748f82ee5defb2fc));
    R(h, a, b, c, d, e, f, g, Wn(57), UINT64_C(0x78a5636f43172f60));
    R(g, h, a, b, c, d, e, f, Wn(58), UINT64_C(0x84c87814a1f0ab72));
    R(f, g, h, a, b, c, d, e, Wn(59), UINT64_C(0x8cc702081a6439ec));
    R(e, f, g, h, a, b, c, d, Wn(60), UINT64_C(0x90befffa23631e28));
    R(d, e, f, g, h, a, b, c, Wn(61), UINT64_C(0xa4506cebde82bde9));
    R(c, d, e, f, g, h, a, b, Wn(62), UINT64_C(0xbef9a3f7b2c67915));
    R(b, c, d, e, f, g, h, a, Wn(63), UINT64_C(0xc67178f2e372532b));
    R(a, b, c, d, e, f, g, h, Wn(64), UINT64_C(0xca273eceea26619c));
    R(h, a, b, c, d, e, f, g, Wn(65), UINT64_C(0xd186b8c721c0c207));
    R(g, h, a, b, c, d, e, f, Wn(66), UINT64_C(0xeada7dd6cde0eb1e));
    R(f, g, h, a, b, c, d, e, Wn(67), UINT64_C(0xf57d4f7fee6ed178));
    R(e, f, g, h, a, b, c, d, Wn(68), UINT64_C(0x06f067aa72176fba));
    R(d, e, f, g, h, a, b, c, Wn(69), UINT64_C(0x0a637dc5a2c898a6));
    R(c, d, e, f, g, h, a, b, Wn(70), UINT64_C(0x113f9804bef90dae));
    R(b, c, d, e, f, g, h, a, Wn(71), UINT64_C(0x1b710b35131c471b));
    R(a, b, c, d, e, f, g, h, Wn(72), UINT64_C(0x28db77f523047d84));
    R(h, a, b, c, d, e, f, g, Wn(73), UINT64_C(0x32caab7b40c72493));
    R(g, h, a, b, c, d, e, f, Wn(74), UINT64_C(0x3c9ebe0a15c9bebc));
    R(f, g, h, a, b, c, d, e, Wn(75), UINT64_C(0x431d67c49c100d4c));
    R(e, f, g, h, a, b, c, d, Wn(76), UINT64_C(0x4cc5d4becb3e42b6));
    R(d, e, f, g, h, a, b, c, Wn(77), UINT64_C(0x597f299cfc657e2a));
    R(c, d, e, f, g, h, a, b, Wn(78), UINT64_C(0x5fcb6fab3ad6faec));
    R(b, c, d, e, f, g, h, a, Wn(79), UINT64_C(0x6c44198c4a475817));

    state_out[0] = state_in[0] + a;
    state_out[1] = state_in[1] + b;
    state_out[2] = state_in[2] + c;
    state_out[3] = state_in[3] + d;
    state_out[4] = state_in[4] + e;
    state_out[5] = state_in[5] + f;
    state_out[6] = state_in[6] + g;
    state_out[7] = state_in[7] + h;

#undef CH
#undef MAJ
#undef SSIG0
#undef SSIG1
#undef BSIG0
#undef BSIG1
#undef R
#undef Wi
#undef Wn
}

// Device helper: sha512_convert_input.
__device__ __forceinline__ void sha512_convert_input(cf_sha512_block inp64, const uint8_t inp[CF_SHA512_BLOCKSZ])
{
#pragma unroll
    for (int i = 0; i < CF_SHA512_BLOCKSZ; i += 8)
        inp64[i >> 3] = read64_be(inp + i);
}

// Device helper: sha512_update_block.
__device__ __forceinline__  void sha512_update_block(void* vctx, const uint8_t* inp)
{
    cf_sha512_context* ctx = reinterpret_cast<cf_sha512_context*>(vctx);
    cf_sha512_block inp64;
    sha512_convert_input(inp64, inp);
    sha512_raw_transform(ctx->H, ctx->H, inp64);
    ctx->blocks += 1;
}

// Device helper: cf_sha512_update.
__device__ __forceinline__  void cf_sha512_update(cf_sha512_context* ctx, const void* data, size_t nbytes)
{
    cf_blockwise_accumulate(ctx->partial, &ctx->npartial, sizeof ctx->partial,
        data, nbytes,
        sha512_update_block, ctx);
}

__device__ __forceinline__  void sha512_convert_output(const uint64_t H[8],
    uint8_t hash[CF_SHA512_HASHSZ])
{
    write64_be(H[0], hash + 0);
    write64_be(H[1], hash + 8);
    write64_be(H[2], hash + 16);
    write64_be(H[3], hash + 24);
    write64_be(H[4], hash + 32);
    write64_be(H[5], hash + 40);
    write64_be(H[6], hash + 48);
    write64_be(H[7], hash + 56);
}

// Device helper: sha512_xor.
__device__ __forceinline__  void sha512_xor(uint64_t* __restrict__ out, const uint64_t* __restrict__ in)
{
    out[0] ^= in[0];
    out[1] ^= in[1];
    out[2] ^= in[2];
    out[3] ^= in[3];
    out[4] ^= in[4];
    out[5] ^= in[5];
    out[6] ^= in[6];
    out[7] ^= in[7];
}

// Device helper: cf_sha512_final.
__device__ __forceinline__  void cf_sha512_final(cf_sha512_context* ctx, uint8_t hash[CF_SHA512_HASHSZ])
{
    uint32_t digested_bytes = ctx->blocks;
    digested_bytes = digested_bytes * CF_SHA512_BLOCKSZ + ctx->npartial;
    uint32_t digested_bits = digested_bytes * 8;

    size_t padbytes = CF_SHA512_BLOCKSZ - ((digested_bytes + 4) % CF_SHA512_BLOCKSZ);

    /* Hash 0x80 00 ... block first. */
    cf_blockwise_acc_pad(ctx->partial, &ctx->npartial, sizeof ctx->partial,
        0x80, 0x00, 0x00, padbytes,
        sha512_update_block, ctx);

    /* Now hash length (this is 128 bits long). */
    uint8_t buf[4];
    write32_be(digested_bits, buf);
    cf_sha512_update(ctx, buf, 4);

    /* We ought to have got our padding calculation right! */
    assert(ctx->npartial == 0);

    sha512_convert_output(ctx->H, hash);
}


#ifndef HMAC_CTX
# define GLUE3(a, b, c) a ## b ## c
# define HMAC_CTX(_name) GLUE3(HMAC_, _name, _ctx)
# define HMAC_INIT(_name) GLUE3(HMAC_, _name, _init)
# define HMAC_UPDATE(_name) GLUE3(HMAC_, _name, _update)
# define HMAC_FINAL(_name) GLUE3(HMAC_, _name, _final)

# define PBKDF2_F(_name) GLUE3(pbkdf2, _f_, _name)
# define PBKDF2(_name) GLUE3(pbkdf2, _, _name)
#endif



typedef struct {
    _ctx inner;
    _ctx outer;
} HMAC_CTX(_name);

__device__ __forceinline__   void HMAC_INIT(_name)(HMAC_CTX(_name)* ctx,
    const uint8_t* key, size_t nkey)
{
    /* Prepare key: */
    uint8_t k[_blocksz];

    /* Shorten long keys. */
    if (nkey > _blocksz)
    {
        _init(&ctx->inner);
        _update(&ctx->inner, key, nkey);
        _final(&ctx->inner, k);

        key = k;
        nkey = _hashsz;
    }

    /* Standard doesn't cover case where blocksz < hashsz. */
    assert(nkey <= _blocksz);

    /* Right zero-pad short keys. */
    if (k != key)
        memcpy(k, key, nkey);
    if (_blocksz > nkey)
        memset(k + nkey, 0, _blocksz - nkey);

    /* Build ipad block in-place, hash it, then mutate to opad in-place. */
#pragma unroll
    for (size_t i = 0; i < _blocksz; i++)
    {
        k[i] ^= 0x36;
    }

    _init(&ctx->inner);
    _update(&ctx->inner, k, _blocksz);

#pragma unroll
    for (size_t i = 0; i < _blocksz; i++)
    {
        k[i] ^= (0x36 ^ 0x5c);
    }

    _init(&ctx->outer);
    _update(&ctx->outer, k, _blocksz);
}

__device__ __forceinline__   void HMAC_UPDATE(_name)(HMAC_CTX(_name)* ctx,
    const void* data, size_t ndata)
{
    _update(&ctx->inner, data, ndata);
}

__device__ __forceinline__   void HMAC_FINAL(_name)(HMAC_CTX(_name)* ctx,
    uint8_t out[_hashsz])
{
    _final(&ctx->inner, out);
    _update(&ctx->outer, out, _hashsz);
    _final(&ctx->outer, out);
}

typedef struct {
    uint64_t inner_H[8];
    uint64_t outer_H[8];
} pbkdf2_sha512_precomp_t;

// Device helper: pbkdf2_load_key_word_be.
__device__ __forceinline__ uint64_t pbkdf2_load_key_word_be(const uint8_t* __restrict__ key, size_t nkey, int word_idx)
{
    const size_t off = (size_t)word_idx * 8u;
    if (off >= nkey) {
        return 0;
    }
    if ((off + 8u) <= nkey) {
        return read64_be(key + off);
    }

    const size_t tail = nkey - off;
    uint64_t w = 0;
#pragma unroll
    for (int j = 0; j < 8; ++j) {
        w <<= 8;
        if ((size_t)j < tail) {
            w |= (uint64_t)key[off + (size_t)j];
        }
    }
    return w;
}

__device__ __forceinline__ void pbkdf2_sha512_init_precomp(const uint8_t* key,
    size_t nkey,
    pbkdf2_sha512_precomp_t* __restrict__ out_ctx)
{
    uint8_t hashed_key[_hashsz];
    if (nkey > _blocksz)
    {
        SHA512(key, nkey, hashed_key);
        key = hashed_key;
        nkey = _hashsz;
    }

    const uint64_t iv[8] = {
        UINT64_C(0x6a09e667f3bcc908), UINT64_C(0xbb67ae8584caa73b),
        UINT64_C(0x3c6ef372fe94f82b), UINT64_C(0xa54ff53a5f1d36f1),
        UINT64_C(0x510e527fade682d1), UINT64_C(0x9b05688c2b3e6c1f),
        UINT64_C(0x1f83d9abfb41bd6b), UINT64_C(0x5be0cd19137e2179)
    };

    _blocktype block_words;
#pragma unroll
    for (int i = 0; i < 16; i++)
    {
        block_words[i] = pbkdf2_load_key_word_be(key, nkey, i) ^ UINT64_C(0x3636363636363636);
    }
    _transform(iv, out_ctx->inner_H, block_words);

    // Reuse prepared block: ipad ^ opad = 0x6a on each byte.
#pragma unroll
    for (int i = 0; i < 16; i++)
    {
        block_words[i] ^= UINT64_C(0x6a6a6a6a6a6a6a6a);
    }
    _transform(iv, out_ctx->outer_H, block_words);
}

__device__ __forceinline__ void pbkdf2_copy_salt_count_bytes(uint8_t* __restrict__ dst,
    size_t len,
    const uint8_t* __restrict__ salt,
    size_t nsalt,
    const uint8_t countbuf[4],
    size_t offset)
{
    size_t copied = 0;
    if (offset < nsalt)
    {
        size_t salt_avail = nsalt - offset;
        size_t take_salt = (len < salt_avail) ? len : salt_avail;
        memcpy(dst, salt + offset, take_salt);
        copied = take_salt;
    }
    size_t rem = len - copied;
    if (rem)
    {
        size_t count_off = offset + copied - nsalt;
        memcpy(dst + copied, countbuf + count_off, rem);
    }
}

__device__ __forceinline__ void pbkdf2_u1_sha512_words(const pbkdf2_sha512_precomp_t* __restrict__ startctx,
    uint32_t counter,
    const uint8_t* __restrict__ salt,
    size_t nsalt,
    uint64_t out_words[8])
{
    uint8_t countbuf[4];
    write32_be(counter, countbuf);

    size_t msg_len = nsalt + sizeof(countbuf);
    const uint32_t total_inner_bits = (uint32_t)((_blocksz + msg_len) * 8);

    // Hot path for BIP39: salt is usually <= 124 bytes ("mnemonic" + passphrase)
    if (msg_len <= _blocksz)
    {
        uint8_t block_bytes[_blocksz];
        _blocktype block_words;
        memset(block_bytes, 0, _blocksz);
        if (nsalt)
        {
            memcpy(block_bytes, salt, nsalt);
        }
        memcpy(block_bytes + nsalt, countbuf, sizeof(countbuf));
        block_bytes[msg_len] = 0x80;
        write32_be(total_inner_bits, block_bytes + (_blocksz - 4));
        _cvt_input(block_words, block_bytes);

        uint64_t inner_out[8];
        _transform(startctx->inner_H, inner_out, block_words);

        _blocktype outer_block;
#pragma unroll
        for (int j = 0; j < 8; j++) {
            outer_block[j] = inner_out[j];
        }
        outer_block[8] = UINT64_C(0x8000000000000000);
#pragma unroll
        for (int j = 9; j < 15; j++) {
            outer_block[j] = 0;
        }
        outer_block[15] = UINT64_C(0x0000000000000600);

        _transform(startctx->outer_H, out_words, outer_block);
        return;
    }

    // Rare fallback for very long passphrases that force two message blocks.
    uint8_t block_bytes[_blocksz];
    _blocktype block_words;
    uint64_t inner_a[8];
    uint64_t inner_b[8];
    const uint64_t* in_state = startctx->inner_H;
    uint64_t* out_state = inner_a;
    size_t offset = 0;

    while (msg_len >= _blocksz)
    {
        pbkdf2_copy_salt_count_bytes(block_bytes, _blocksz, salt, nsalt, countbuf, offset);
        _cvt_input(block_words, block_bytes);
        _transform(in_state, out_state, block_words);
        in_state = out_state;
        out_state = (out_state == inner_a) ? inner_b : inner_a;
        offset += _blocksz;
        msg_len -= _blocksz;
    }

    memset(block_bytes, 0, _blocksz);
    if (msg_len)
    {
        pbkdf2_copy_salt_count_bytes(block_bytes, msg_len, salt, nsalt, countbuf, offset);
    }
    block_bytes[msg_len] = 0x80;
    write32_be(total_inner_bits, block_bytes + (_blocksz - 4));
    _cvt_input(block_words, block_bytes);
    _transform(in_state, out_state, block_words);

    _blocktype outer_block;
#pragma unroll
    for (int j = 0; j < 8; j++) {
        outer_block[j] = out_state[j];
    }
    outer_block[8] = UINT64_C(0x8000000000000000);
#pragma unroll
    for (int j = 9; j < 15; j++) {
        outer_block[j] = 0;
    }
    outer_block[15] = UINT64_C(0x0000000000000600);

    _transform(startctx->outer_H, out_words, outer_block);
}

// __host__ __device__ void printBuffer(const uint8_t* buffer, uint32_t size)
//{
//    for (uint32_t i = 0; i < size; i++)
//        printf("%02x", uint32_t(buffer[i]));
//    printf("\n");
//}


/* --- PBKDF2 --- */
__device__ __forceinline__   void PBKDF2_F(_name)(const pbkdf2_sha512_precomp_t* startctx,
    uint32_t counter,
    const uint8_t* salt, size_t nsalt,
    uint64_t iterations,
    uint8_t* out)
{
    uint64_t resultH[8];
    pbkdf2_u1_sha512_words(startctx, counter, salt, nsalt, resultH);

    _blocktype Ublock;
#pragma unroll
    for (int j = 0; j < 8; j++) {
        Ublock[j] = resultH[j];
    }
    Ublock[8] = UINT64_C(0x8000000000000000);
    Ublock[9] = 0;
    Ublock[10] = 0;
    Ublock[11] = 0;
    Ublock[12] = 0;
    Ublock[13] = 0;
    Ublock[14] = 0;
    Ublock[15] = UINT64_C(0x0000000000000600);

    /* Subsequent iterations:
     *   U_c = PRF(P, U_{c-1})
     *
     * At this point, Ublock contains U_1 plus MD padding, in native
     * byte order.
     */
     //uint32_t id = threadIdx.x + blockIdx.x * blockDim.x;
     //if (id == 0)
     //{
     //    printf("Ublock = \n");
     //    printBuffer(reinterpret_cast<uint8_t*>(Ublock), sizeof(Ublock));
     //}
    for (uint64_t i = 1; i < iterations; i++)
    {
        _transform(startctx->inner_H, Ublock, Ublock);
        _transform(startctx->outer_H, Ublock, Ublock);
        _xor(resultH, Ublock);
    }

    //printBuffer(reinterpret_cast<uint8_t*>(result.H), sizeof(result.H));
    /* Reform result into output buffer. */
    _cvt_output(resultH, out);
}

__device__ __forceinline__   void PBKDF2(_name)(const uint8_t* pw, size_t npw,
    const uint8_t* salt, size_t nsalt,
    uint64_t iterations,
    uint8_t* out, size_t nout)
{
    assert(iterations);
    assert(out && nout);

    pbkdf2_sha512_precomp_t ctx;
    pbkdf2_sha512_init_precomp(pw, npw, &ctx);

    // Hot path for mnemonic flow: exactly one SHA-512 block output (64 bytes).
    if (nout == _hashsz)
    {
        PBKDF2_F(_name)(&ctx, 1, salt, nsalt, iterations, out);
        return;
    }

    //printf("%s %d\n", pw, npw);
    //printf("%s\n", salt);
    //printf("%xu %xu\n", ctx.inner.H[0], ctx.outer.H[0]);

    /* How many blocks do we need? */
    uint32_t blocks_needed = (nout + _hashsz - 1) / _hashsz;

    OPENMP_PARALLEL_FOR
#pragma unroll 1
        for (uint32_t counter = 1; counter <= blocks_needed; counter++)
        {
            uint8_t block[_hashsz];
            PBKDF2_F(_name)(&ctx, counter, salt, nsalt, iterations, block);

            size_t offset = (counter - 1) * _hashsz;
            size_t taken = MIN(nout - offset, _hashsz);
            memcpy(out + offset, block, taken);
            //printBuffer(block, sizeof(block));
        }
}

__device__ void fastpbkdf2_hmac_sha512(const uint8_t* pw, size_t npw,
    const uint8_t* salt, size_t nsalt,
    uint64_t iterations,
    uint8_t* out, size_t nout)
{
    PBKDF2(sha512)(pw, npw, salt, nsalt, iterations, out, nout);
}

__device__ void HMAC_SHA512(const uint8_t* key, size_t key_len,
    const uint8_t* data, size_t data_len,
    uint8_t* out) {
    HMAC_CTX(sha512) ctx;

    HMAC_INIT(sha512)(&ctx, key, key_len);

    HMAC_UPDATE(sha512)(&ctx, data, data_len);

    HMAC_FINAL(sha512)(&ctx, out);
}

// Device helper: SHA512.
__device__ void SHA512(const uint8_t* data, size_t len, uint8_t out[64]) {
    cf_sha512_context ctx;
    cf_sha512_init(&ctx);
    cf_sha512_update(&ctx, data, len);
    cf_sha512_final(&ctx, out);
}
