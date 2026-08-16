/*
 * TRON-specific matcher for the Profanity2 public-point walker.
 *
 * The host gives the GPU a public secp256k1 point only. This kernel advances
 * that point, derives the TRON payload, performs Base58-equivalent prefix and
 * suffix tests, and reports only the public lane/round offset. The private base
 * scalar never enters OpenCL memory.
 */

#define TRX_ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define TRX_CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define TRX_MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define TRX_SIGMA0(x) (TRX_ROTR((x), 2) ^ TRX_ROTR((x), 13) ^ TRX_ROTR((x), 22))
#define TRX_SIGMA1(x) (TRX_ROTR((x), 6) ^ TRX_ROTR((x), 11) ^ TRX_ROTR((x), 25))
#define TRX_sigma0(x) (TRX_ROTR((x), 7) ^ TRX_ROTR((x), 18) ^ ((x) >> 3))
#define TRX_sigma1(x) (TRX_ROTR((x), 17) ^ TRX_ROTR((x), 19) ^ ((x) >> 10))

__constant uint TRX_SHA_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

inline void trx_sha_round(
        __private uint* a, __private uint* b, __private uint* c, __private uint* d,
        __private uint* e, __private uint* f, __private uint* g, __private uint* h,
        uint k, uint w) {
    const uint t1 = *h + TRX_SIGMA1(*e) + TRX_CH(*e, *f, *g) + k + w;
    const uint t2 = TRX_SIGMA0(*a) + TRX_MAJ(*a, *b, *c);
    *h = *g; *g = *f; *f = *e; *e = *d + t1;
    *d = *c; *c = *b; *b = *a; *a = t1 + t2;
}

inline void trx_sha256_21(__private const uchar* input, __private uint* output) {
    uint a = 0x6a09e667, b = 0xbb67ae85, c = 0x3c6ef372, d = 0xa54ff53a;
    uint e = 0x510e527f, f = 0x9b05688c, g = 0x1f83d9ab, h = 0x5be0cd19;

    uint w0 = ((uint)input[0] << 24) | ((uint)input[1] << 16) | ((uint)input[2] << 8) | input[3];
    uint w1 = ((uint)input[4] << 24) | ((uint)input[5] << 16) | ((uint)input[6] << 8) | input[7];
    uint w2 = ((uint)input[8] << 24) | ((uint)input[9] << 16) | ((uint)input[10] << 8) | input[11];
    uint w3 = ((uint)input[12] << 24) | ((uint)input[13] << 16) | ((uint)input[14] << 8) | input[15];
    uint w4 = ((uint)input[16] << 24) | ((uint)input[17] << 16) | ((uint)input[18] << 8) | input[19];
    uint w5 = ((uint)input[20] << 24) | 0x00800000;
    uint w6 = 0, w7 = 0, w8 = 0, w9 = 0, w10 = 0, w11 = 0, w12 = 0, w13 = 0, w14 = 0;
    uint w15 = 168;

    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[0],w0);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[1],w1);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[2],w2);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[3],w3);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[4],w4);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[5],w5);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[6],w6);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[7],w7);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[8],w8);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[9],w9);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[10],w10);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[11],w11);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[12],w12);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[13],w13);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[14],w14);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[15],w15);

    #pragma unroll
    for (int i = 16; i < 64; ++i) {
        const uint next = TRX_sigma1(w14) + w9 + TRX_sigma0(w1) + w0;
        trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[i],next);
        w0=w1; w1=w2; w2=w3; w3=w4; w4=w5; w5=w6; w6=w7; w7=w8;
        w8=w9; w9=w10; w10=w11; w11=w12; w12=w13; w13=w14; w14=w15; w15=next;
    }

    output[0]=a+0x6a09e667; output[1]=b+0xbb67ae85;
    output[2]=c+0x3c6ef372; output[3]=d+0xa54ff53a;
    output[4]=e+0x510e527f; output[5]=f+0x9b05688c;
    output[6]=g+0x1f83d9ab; output[7]=h+0x5be0cd19;
}

inline void trx_sha256_32(__private const uint* input, __private uint* output) {
    uint a = 0x6a09e667, b = 0xbb67ae85, c = 0x3c6ef372, d = 0xa54ff53a;
    uint e = 0x510e527f, f = 0x9b05688c, g = 0x1f83d9ab, h = 0x5be0cd19;

    uint w0=input[0], w1=input[1], w2=input[2], w3=input[3];
    uint w4=input[4], w5=input[5], w6=input[6], w7=input[7];
    uint w8=0x80000000, w9=0, w10=0, w11=0, w12=0, w13=0, w14=0, w15=256;

    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[0],w0);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[1],w1);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[2],w2);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[3],w3);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[4],w4);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[5],w5);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[6],w6);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[7],w7);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[8],w8);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[9],w9);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[10],w10);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[11],w11);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[12],w12);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[13],w13);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[14],w14);
    trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[15],w15);

    #pragma unroll
    for (int i = 16; i < 64; ++i) {
        const uint next = TRX_sigma1(w14) + w9 + TRX_sigma0(w1) + w0;
        trx_sha_round(&a,&b,&c,&d,&e,&f,&g,&h,TRX_SHA_K[i],next);
        w0=w1; w1=w2; w2=w3; w3=w4; w4=w5; w5=w6; w6=w7; w7=w8;
        w8=w9; w9=w10; w10=w11; w11=w12; w12=w13; w13=w14; w14=w15; w15=next;
    }

    output[0]=a+0x6a09e667; output[1]=b+0xbb67ae85;
    output[2]=c+0x3c6ef372; output[3]=d+0xa54ff53a;
    output[4]=e+0x510e527f; output[5]=f+0x9b05688c;
    output[6]=g+0x1f83d9ab; output[7]=h+0x5be0cd19;
}

inline ulong trx_add_mod_reduced(ulong lhs, ulong rhs, ulong modulus) {
    return lhs >= modulus - rhs ? lhs - (modulus - rhs) : lhs + rhs;
}

inline ulong trx_suffix_mod(__private const uchar* data, ulong modulus) {
    ulong remainder = 0;
    if (modulus <= (~0UL) / 256UL) {
        for (int i = 0; i < 25; ++i) {
            remainder = (remainder * 256UL + (ulong)data[i]) % modulus;
        }
        return remainder;
    }
    for (int i = 0; i < 25; ++i) {
        for (int bit = 0; bit < 8; ++bit) {
            remainder = trx_add_mod_reduced(remainder, remainder, modulus);
        }
        remainder = trx_add_mod_reduced(remainder, (ulong)data[i], modulus);
    }
    return remainder;
}

__constant uint TRX_SUFFIX_WEIGHTS[25] = {
    162536, 152304, 44800, 122120, 63736,
    180880, 163808, 40272, 71800, 144328,
    69920, 33808, 77872, 135968, 180400,
    172952, 129480, 118640, 178808, 95968,
    161952, 192696, 65536, 256, 1
};

inline uint trx_suffix_probe(__private const uchar* data) {
    uint sum = 0;
    for (uint i = 0; i < 25; ++i) {
        sum += (uint)data[i] * (uint)TRX_SUFFIX_WEIGHTS[i];
    }
    return sum % 195112U;
}

inline uint trx_checksum(__private const uchar* address) {
    uint first[8];
    uint second[8];
    trx_sha256_21(address, first);
    trx_sha256_32(first, second);
    return second[0];
}

inline void trx_report(
        size_t id,
        __private const uint* hash_words,
        __global result* output) {
    volatile __global unsigned int* found =
        (volatile __global unsigned int*)&output[0].found;
    if (atomic_cmpxchg(found, 0U, 1U) == 0U) {
        output[0].foundId = (uint)id;
        for (int i = 0; i < 20; ++i) {
            output[0].foundHash[i] = profanity_byte(hash_words, i);
        }
    }
}

__kernel void trx_iterate_short(
        __global mp_number* const delta_x,
        __global const mp_number* const inverse,
        __global mp_number* const previous_lambda,
        __global result* const output,
        const ulong suffix_modulus,
        const ulong suffix_remainder,
        const uint suffix_probe_target) {
    const size_t id = get_global_id(0);
    uint hash_words[5];
    profanity_iterate(delta_x, inverse, previous_lambda, id, (uchar)0, hash_words);

    uchar address[25];
    address[0] = 0x41;
    for (int i = 0; i < 20; ++i) {
        address[i + 1] = profanity_byte(hash_words, i);
    }

    const uint checksum = trx_checksum(address);
    address[21] = (uchar)(checksum >> 24);
    address[22] = (uchar)(checksum >> 16);
    address[23] = (uchar)(checksum >> 8);
    address[24] = (uchar)checksum;

    if (suffix_modulus != 1UL) {
        const uint probe = trx_suffix_probe(address);
        if (suffix_modulus == 58UL) {
            if ((probe % 58U) != suffix_probe_target) return;
        } else if (suffix_modulus == 3364UL) {
            if ((probe % 3364U) != suffix_probe_target) return;
        } else if (probe != suffix_probe_target) {
            return;
        } else if (suffix_modulus > 195112UL
                   && trx_suffix_mod(address, suffix_modulus) != suffix_remainder) {
            return;
        }
    }

    trx_report(id, hash_words, output);
}

// A suffix of n >= 6 digits gives modulus 58^n = 2^n * 29^n.  Writing the
// 32-bit checksum as r0 + 2^n*t leaves a congruence with at most one possible
// t.  These exact payload filters reject impossible checksums before the two
// SHA-256 passes.  Dedicated entry points keep every modulus compile-time
// constant and avoid penalizing the common short-suffix kernel.
__constant ulong TRX_SIX_WEIGHTS[20] = {
    15593048UL, 539119545UL, 520252813UL, 548061458UL, 71846723UL,
    458015785UL, 557112459UL, 143911465UL, 555885489UL, 92789043UL,
    197862388UL, 549125649UL, 464527213UL, 27373374UL, 41930442UL,
    385869538UL, 480154194UL, 517698951UL, 524816196UL, 67108864UL
};

inline bool trx_checksum_candidate6(
        __private const uint* hash_words,
        ulong suffix_remainder,
        ulong target_quotient,
        __private uint* expected_checksum) {
    ulong weighted = 125350764UL;
    #pragma unroll
    for (uint i = 0; i < 20; ++i) {
        weighted += (ulong)profanity_byte(hash_words, i) * TRX_SIX_WEIGHTS[i];
    }
    const ulong payload_term = weighted % 594823321UL;
    const ulong difference = target_quotient >= payload_term
        ? target_quotient - payload_term
        : target_quotient + 594823321UL - payload_term;
    if (difference >= 67108864UL) return false;
    *expected_checksum = ((uint)difference << 6) | (uint)(suffix_remainder & 63UL);
    return true;
}

__constant ulong TRX_SEVEN_WEIGHTS[20] = {
    602619845UL, 5325558001UL, 14238474450UL, 8006733902UL, 15798741368UL,
    7069476084UL, 14851727594UL, 12860657134UL, 13661467467UL, 15214389207UL,
    9021281009UL, 14252910868UL, 4098615193UL, 13694623070UL, 1805435184UL,
    9710107905UL, 240077097UL, 8288964309UL, 8589934592UL, 33554432UL
};

inline bool trx_checksum_candidate7(
        __private const uint* hash_words,
        ulong suffix_remainder,
        ulong target_quotient,
        __private uint* expected_checksum) {
    ulong weighted = 5416085271UL;
    #pragma unroll
    for (uint i = 0; i < 20; ++i) {
        weighted += (ulong)profanity_byte(hash_words, i) * TRX_SEVEN_WEIGHTS[i];
    }
    const ulong payload_term = weighted % 17249876309UL;
    const ulong difference = target_quotient >= payload_term
        ? target_quotient - payload_term
        : target_quotient + 17249876309UL - payload_term;
    if (difference >= 33554432UL) return false;
    *expected_checksum = ((uint)difference << 7) | (uint)(suffix_remainder & 127UL);
    return true;
}

__constant ulong TRX_EIGHT_WEIGHTS[20] = {
    440173155802UL, 201036356554UL, 231367629242UL, 262751511586UL, 59648999611UL,
    72534243278UL, 473172524140UL, 40930081185UL, 498452208540UL, 447479040483UL,
    496132115311UL, 472873115777UL, 62423874678UL, 144846322007UL, 18152593901UL,
    99729373652UL, 336492626574UL, 99018801854UL, 4294967296UL, 16777216UL
};

inline bool trx_checksum_candidate8(
        __private const uint* hash_words,
        ulong suffix_remainder,
        ulong target_quotient,
        __private uint* expected_checksum) {
    ulong weighted = 373580383279UL;
    #pragma unroll
    for (uint i = 0; i < 20; ++i) {
        weighted += (ulong)profanity_byte(hash_words, i) * TRX_EIGHT_WEIGHTS[i];
    }
    const ulong payload_term = weighted % 500246412961UL;
    const ulong difference = target_quotient >= payload_term
        ? target_quotient - payload_term
        : target_quotient + 500246412961UL - payload_term;
    if (difference >= 16777216UL) return false;
    *expected_checksum = ((uint)difference << 8) | (uint)(suffix_remainder & 255UL);
    return true;
}

inline void trx_match_candidate8(
        size_t id,
        __private const uint* hash_words,
        __global result* output,
        ulong suffix_modulus,
        ulong suffix_remainder,
        ulong target_quotient) {
    uint expected_checksum;
    if (!trx_checksum_candidate8(
            hash_words, suffix_remainder, target_quotient, &expected_checksum)) return;
    uchar address[25];
    address[0] = 0x41;
    for (int i = 0; i < 20; ++i) address[i + 1] = profanity_byte(hash_words, i);
    const uint checksum = trx_checksum(address);
    if (checksum != expected_checksum) return;
    address[21] = (uchar)(checksum >> 24);
    address[22] = (uchar)(checksum >> 16);
    address[23] = (uchar)(checksum >> 8);
    address[24] = (uchar)checksum;
    if (suffix_modulus != 128063081718016UL
        && trx_suffix_mod(address, suffix_modulus) != suffix_remainder) return;
    trx_report(id, hash_words, output);
}

inline void trx_match_candidate7(
        size_t id,
        __private const uint* hash_words,
        __global result* output,
        ulong suffix_modulus,
        ulong suffix_remainder,
        ulong target_quotient) {
    uint expected_checksum;
    if (!trx_checksum_candidate7(
            hash_words, suffix_remainder, target_quotient, &expected_checksum)) return;
    uchar address[25];
    address[0] = 0x41;
    for (int i = 0; i < 20; ++i) address[i + 1] = profanity_byte(hash_words, i);
    const uint checksum = trx_checksum(address);
    if (checksum != expected_checksum) return;
    address[21] = (uchar)(checksum >> 24);
    address[22] = (uchar)(checksum >> 16);
    address[23] = (uchar)(checksum >> 8);
    address[24] = (uchar)checksum;
    if (suffix_modulus != 2207984167552UL
        && trx_suffix_mod(address, suffix_modulus) != suffix_remainder) return;
    trx_report(id, hash_words, output);
}

#define TRX_FILTERED_KERNEL(NAME, FILTER, EXACT_MODULUS) \
__kernel void NAME( \
        __global mp_number* const delta_x, \
        __global const mp_number* const inverse, \
        __global mp_number* const previous_lambda, \
        __global result* const output, \
        const ulong suffix_modulus, \
        const ulong suffix_remainder, \
        const ulong target_quotient) { \
    const size_t id = get_global_id(0); \
    uint hash_words[5]; \
    profanity_iterate(delta_x, inverse, previous_lambda, id, (uchar)0, hash_words); \
    uint expected_checksum; \
    if (!FILTER(hash_words, suffix_remainder, target_quotient, &expected_checksum)) return; \
    uchar address[25]; \
    address[0] = 0x41; \
    for (int i = 0; i < 20; ++i) address[i + 1] = profanity_byte(hash_words, i); \
    const uint checksum = trx_checksum(address); \
    if (checksum != expected_checksum) return; \
    address[21] = (uchar)(checksum >> 24); \
    address[22] = (uchar)(checksum >> 16); \
    address[23] = (uchar)(checksum >> 8); \
    address[24] = (uchar)checksum; \
    if (suffix_modulus != EXACT_MODULUS \
        && trx_suffix_mod(address, suffix_modulus) != suffix_remainder) return; \
    trx_report(id, hash_words, output); \
}

TRX_FILTERED_KERNEL(trx_iterate_six, trx_checksum_candidate6, 38068692544UL)
#undef TRX_FILTERED_KERNEL

// Fusing the reverse half of batch inversion with point iteration keeps each
// lane inverse private.  This removes one 32-byte global write and read per
// candidate while retaining coalesced transposed lane access.
__kernel void trx_inverse_iterate_long(
        __global mp_number* restrict const delta_x,
        __global mp_number* restrict const previous_lambda,
        __global result* const output,
        const ulong suffix_modulus,
        const ulong suffix_remainder,
        const ulong target_quotient) {
    const size_t id = get_global_id(0);
    const size_t stride = get_global_size(0);
    mp_number negative_double_gy = {{
        0x09de52bf, 0xc7705edf, 0xb2f557cc, 0x05d0976e,
        0xe3ddeeae, 0x44b60807, 0xb2b87735, 0x6f8a4b11
    }};
    mp_number accumulated;
    mp_number lane_value;
    mp_number prefix[PROFANITY_INVERSE_SIZE];

    prefix[0] = delta_x[id];
    size_t lane = id + stride;
    for (uint i = 1; i < PROFANITY_INVERSE_SIZE; ++i) {
        lane_value = delta_x[lane];
        mp_mod_mul(&prefix[i], &lane_value, &prefix[i - 1]);
        lane += stride;
    }
    accumulated = prefix[PROFANITY_INVERSE_SIZE - 1];
    mp_mod_inverse(&accumulated);
    mp_mod_mul(&accumulated, &accumulated, &negative_double_gy);

    lane = id + (PROFANITY_INVERSE_SIZE - 1) * stride;
    for (uint i = PROFANITY_INVERSE_SIZE - 1; i > 0; --i) {
        mp_number lane_inverse;
        mp_mod_mul(&lane_inverse, &accumulated, &prefix[i - 1]);
        lane_value = delta_x[lane];
        uint hash_words[5];
        profanity_iterate_with_inverse(
            delta_x, previous_lambda, lane, &lane_inverse, (uchar)0, hash_words);
        trx_match_candidate8(
            lane, hash_words, output, suffix_modulus, suffix_remainder, target_quotient);
        mp_mod_mul(&accumulated, &accumulated, &lane_value);
        lane -= stride;
    }

    uint hash_words[5];
    profanity_iterate_with_inverse(
        delta_x, previous_lambda, id, &accumulated, (uchar)0, hash_words);
    trx_match_candidate8(
        id, hash_words, output, suffix_modulus, suffix_remainder, target_quotient);
}

__kernel void trx_inverse_iterate_medium(
        __global mp_number* restrict const delta_x,
        __global mp_number* restrict const previous_lambda,
        __global result* const output,
        const ulong suffix_modulus,
        const ulong suffix_remainder,
        const ulong target_quotient) {
    const size_t id = get_global_id(0);
    const size_t stride = get_global_size(0);
    mp_number negative_double_gy = {{
        0x09de52bf, 0xc7705edf, 0xb2f557cc, 0x05d0976e,
        0xe3ddeeae, 0x44b60807, 0xb2b87735, 0x6f8a4b11
    }};
    mp_number accumulated;
    mp_number lane_value;
    mp_number prefix[PROFANITY_INVERSE_SIZE];

    prefix[0] = delta_x[id];
    size_t lane = id + stride;
    for (uint i = 1; i < PROFANITY_INVERSE_SIZE; ++i) {
        lane_value = delta_x[lane];
        mp_mod_mul(&prefix[i], &lane_value, &prefix[i - 1]);
        lane += stride;
    }
    accumulated = prefix[PROFANITY_INVERSE_SIZE - 1];
    mp_mod_inverse(&accumulated);
    mp_mod_mul(&accumulated, &accumulated, &negative_double_gy);

    lane = id + (PROFANITY_INVERSE_SIZE - 1) * stride;
    for (uint i = PROFANITY_INVERSE_SIZE - 1; i > 0; --i) {
        mp_number lane_inverse;
        mp_mod_mul(&lane_inverse, &accumulated, &prefix[i - 1]);
        lane_value = delta_x[lane];
        uint hash_words[5];
        profanity_iterate_with_inverse(
            delta_x, previous_lambda, lane, &lane_inverse, (uchar)0, hash_words);
        trx_match_candidate7(
            lane, hash_words, output, suffix_modulus, suffix_remainder, target_quotient);
        mp_mod_mul(&accumulated, &accumulated, &lane_value);
        lane -= stride;
    }

    uint hash_words[5];
    profanity_iterate_with_inverse(
        delta_x, previous_lambda, id, &accumulated, (uchar)0, hash_words);
    trx_match_candidate7(
        id, hash_words, output, suffix_modulus, suffix_remainder, target_quotient);
}
