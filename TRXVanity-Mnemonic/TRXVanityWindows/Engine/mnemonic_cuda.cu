#include "mnemonic_cuda.hpp"

#define NOMINMAX
#include <Windows.h>
#include <cuda_runtime.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <fstream>
#include <limits>
#include <sstream>
#include <vector>

// Apache-2.0 CUDA PBKDF2 implementation vendored from
// XopMC/CUDA_Mnemonic_Recovery. Keeping it in this translation unit lets the
// linker inline the hot HMAC-SHA512 loop for Ada/Blackwell GPUs.
#include "third_party/fastpbkdf2/pbkdf2_func.cu"

// The implementation is built as a relocatable CUDA object; these headers
// expose its device ABI to the full-pipeline kernel below.
#include "third_party/secp256k1/secp256k1.cuh"
#include "third_party/secp256k1/secp256k1_field.cuh"
#include "third_party/secp256k1/secp256k1_group.cuh"
#include "third_party/secp256k1/secp256k1_scalar.cuh"

namespace trx {
namespace {

__constant__ char kBip39Words[2048][9];
__constant__ std::uint8_t kMnemonicSalt[8] = {
    'm', 'n', 'e', 'm', 'o', 'n', 'i', 'c',
};
__constant__ std::uint64_t kBitcoinSeedInnerState[8] = {
    0x2e2af459060c1873ULL, 0x7894b868dc88433aULL,
    0xdd1a797ef1a1933aULL, 0xe6486d04fcb412a7ULL,
    0xfbcc67b9a396caa0ULL, 0xa2970b146f49b65eULL,
    0xfdf1daabc66f6248ULL, 0x2ff99c812ada6dc3ULL,
};
__constant__ std::uint64_t kBitcoinSeedOuterState[8] = {
    0xbbd27bac212e9dbdULL, 0xdd0bc55e7e4037c1ULL,
    0xdfdd3d6890bd6424ULL, 0x2902de663032b34cULL,
    0xa30f8aa6f67899fcULL, 0x69a566c30f88378fULL,
    0x0500247985ecb694ULL, 0xf6d70307c6b2d337ULL,
};
__constant__ std::uint32_t kSha256RoundConstants[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
};

constexpr unsigned kCudaSlotCount = 2;
constexpr unsigned kAddressCandidatesPerThread = 4;
struct CudaBatchSlot {
    std::uint8_t* device_masters = nullptr;
    std::uint8_t* pinned_masters = nullptr;
    std::uint32_t* device_winner = nullptr;
    std::uint32_t* pinned_winner = nullptr;
    cudaStream_t stream = nullptr;
    cudaEvent_t started = nullptr;
    cudaEvent_t finished = nullptr;
    std::uint32_t candidate_count = 0;
    unsigned state = 0;  // 0 = free, 1 = search in flight, 2 = result ready.
};

CudaBatchSlot g_slots[kCudaSlotCount];
std::size_t g_batch_capacity = 0;
secp256k1_ge_storage* g_secp_precomp = nullptr;
std::size_t g_secp_precomp_pitch = 0;
unsigned g_secp_window_bits = 16;
unsigned g_secp_windows = 0;
unsigned g_master_block_size = 256;
unsigned g_address_block_size = 256;

__device__ __forceinline__ std::uint32_t rotate_right32(
    std::uint32_t value,
    unsigned amount) {
    return __funnelshift_r(value, value, amount);
}

__device__ __forceinline__ std::uint8_t entropy_checksum_nibble(
    const std::uint8_t entropy[16]) {
    std::uint32_t schedule[64];
#pragma unroll
    for (int i = 0; i < 4; ++i) {
        schedule[i] = (static_cast<std::uint32_t>(entropy[i * 4]) << 24)
            | (static_cast<std::uint32_t>(entropy[i * 4 + 1]) << 16)
            | (static_cast<std::uint32_t>(entropy[i * 4 + 2]) << 8)
            | static_cast<std::uint32_t>(entropy[i * 4 + 3]);
    }
    schedule[4] = 0x80000000U;
#pragma unroll
    for (int i = 5; i < 15; ++i) schedule[i] = 0;
    schedule[15] = 128U;
#pragma unroll
    for (int i = 16; i < 64; ++i) {
        const auto s0 = rotate_right32(schedule[i - 15], 7)
            ^ rotate_right32(schedule[i - 15], 18)
            ^ (schedule[i - 15] >> 3);
        const auto s1 = rotate_right32(schedule[i - 2], 17)
            ^ rotate_right32(schedule[i - 2], 19)
            ^ (schedule[i - 2] >> 10);
        schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1;
    }

    std::uint32_t a = 0x6a09e667U;
    std::uint32_t b = 0xbb67ae85U;
    std::uint32_t c = 0x3c6ef372U;
    std::uint32_t d = 0xa54ff53aU;
    std::uint32_t e = 0x510e527fU;
    std::uint32_t f = 0x9b05688cU;
    std::uint32_t g = 0x1f83d9abU;
    std::uint32_t h = 0x5be0cd19U;
#pragma unroll
    for (int i = 0; i < 64; ++i) {
        const auto sigma1 = rotate_right32(e, 6)
            ^ rotate_right32(e, 11) ^ rotate_right32(e, 25);
        const auto choose = (e & f) ^ ((~e) & g);
        const auto temporary1 = h + sigma1 + choose
            + kSha256RoundConstants[i] + schedule[i];
        const auto sigma0 = rotate_right32(a, 2)
            ^ rotate_right32(a, 13) ^ rotate_right32(a, 22);
        const auto majority = (a & b) ^ (a & c) ^ (b & c);
        const auto temporary2 = sigma0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temporary1;
        d = c;
        c = b;
        b = a;
        a = temporary1 + temporary2;
    }
    return static_cast<std::uint8_t>((a + 0x6a09e667U) >> 28);
}

__device__ __forceinline__ void store_be64_device(
    std::uint8_t* output,
    std::uint64_t value) {
#pragma unroll
    for (int i = 7; i >= 0; --i) {
        output[i] = static_cast<std::uint8_t>(value);
        value >>= 8;
    }
}

__global__ __launch_bounds__(256) void derive_mnemonic_master_keys_fused(
    std::uint64_t base_high,
    std::uint64_t base_low,
    std::uint64_t first_candidate,
    std::uint32_t candidate_count,
    std::uint8_t* output_masters) {
    const auto candidate = static_cast<std::uint32_t>(
        blockIdx.x * blockDim.x + threadIdx.x);
    if (candidate >= candidate_count) return;

    const auto offset = first_candidate + candidate;
    const auto low = base_low + offset;
    const auto high = base_high + (low < base_low ? 1ULL : 0ULL);
    std::uint8_t entropy[16];
    store_be64_device(entropy, high);
    store_be64_device(entropy + 8, low);
    const auto checksum = entropy_checksum_nibble(entropy);

    char phrase[108];
    std::uint32_t phrase_length = 0;
#pragma unroll
    for (unsigned word = 0; word < 12; ++word) {
        unsigned index = 0;
#pragma unroll
        for (unsigned bit = 0; bit < 11; ++bit) {
            const unsigned source_bit = word * 11 + bit;
            const unsigned value = source_bit < 128
                ? (entropy[source_bit >> 3] >> (7 - (source_bit & 7))) & 1U
                : (checksum >> (3 - (source_bit - 128))) & 1U;
            index = (index << 1) | value;
        }
        if (word != 0) phrase[phrase_length++] = ' ';
#pragma unroll
        for (unsigned character = 0; character < 8; ++character) {
            const char value = kBip39Words[index][character];
            if (value == '\0') break;
            phrase[phrase_length++] = value;
        }
    }

    auto* output = output_masters + static_cast<std::size_t>(candidate) * 64;
    fastpbkdf2_hmac_sha512(
        reinterpret_cast<const std::uint8_t*>(phrase),
        phrase_length,
        kMnemonicSalt,
        sizeof(kMnemonicSalt),
        2048,
        output,
        64);

    std::uint64_t block[16];
#pragma unroll
    for (unsigned index = 0; index < 8; ++index) {
        block[index] = read64_be(output + index * 8);
    }
    block[8] = 0x8000000000000000ULL;
#pragma unroll
    for (unsigned index = 9; index < 15; ++index) block[index] = 0;
    block[15] = 0x0000000000000600ULL;

    std::uint64_t inner_digest[8];
    sha512_raw_transform(
        kBitcoinSeedInnerState, inner_digest, block);
#pragma unroll
    for (unsigned index = 0; index < 8; ++index) {
        block[index] = inner_digest[index];
    }
    block[8] = 0x8000000000000000ULL;
#pragma unroll
    for (unsigned index = 9; index < 15; ++index) block[index] = 0;
    block[15] = 0x0000000000000600ULL;

    std::uint64_t master[8];
    sha512_raw_transform(kBitcoinSeedOuterState, master, block);
#pragma unroll
    for (unsigned index = 0; index < 8; ++index) {
        write64_be(master[index], output + index * 8);
    }
}

__constant__ std::uint64_t kKeccakRoundConstants[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL,
    0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL,
    0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL,
    0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL,
    0x0000000080000001ULL, 0x8000000080008008ULL,
};

__constant__ unsigned kKeccakRotation[25] = {
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14,
};

__device__ __forceinline__ std::uint64_t rotate_left64(
    std::uint64_t value,
    unsigned amount) {
    return amount == 0 ? value : (value << amount) | (value >> (64 - amount));
}

__device__ __noinline__ void keccak256_64(
    const std::uint8_t input[64],
    std::uint8_t output[32]) {
    std::uint64_t state[25] = {};
#pragma unroll
    for (unsigned index = 0; index < 64; ++index) {
        state[index >> 3] ^= static_cast<std::uint64_t>(input[index])
            << ((index & 7U) * 8U);
    }
    // Keccak-256 uses rate 136, domain byte 0x01 (not SHA3's 0x06).
    state[8] ^= 0x01ULL;
    state[16] ^= 0x8000000000000000ULL;

#pragma unroll 1
    for (unsigned round = 0; round < 24; ++round) {
        std::uint64_t column[5];
        std::uint64_t mixed[5];
        std::uint64_t rotated[25];
#pragma unroll
        for (unsigned x = 0; x < 5; ++x) {
            column[x] = state[x] ^ state[x + 5] ^ state[x + 10]
                ^ state[x + 15] ^ state[x + 20];
        }
#pragma unroll
        for (unsigned x = 0; x < 5; ++x) {
            mixed[x] = column[(x + 4) % 5]
                ^ rotate_left64(column[(x + 1) % 5], 1);
        }
#pragma unroll
        for (unsigned y = 0; y < 5; ++y) {
#pragma unroll
            for (unsigned x = 0; x < 5; ++x) {
                state[x + 5 * y] ^= mixed[x];
            }
        }
#pragma unroll
        for (unsigned y = 0; y < 5; ++y) {
#pragma unroll
            for (unsigned x = 0; x < 5; ++x) {
                const unsigned destination_x = y;
                const unsigned destination_y = (2 * x + 3 * y) % 5;
                rotated[destination_x + 5 * destination_y] = rotate_left64(
                    state[x + 5 * y], kKeccakRotation[x + 5 * y]);
            }
        }
#pragma unroll
        for (unsigned y = 0; y < 5; ++y) {
#pragma unroll
            for (unsigned x = 0; x < 5; ++x) {
                state[x + 5 * y] = rotated[x + 5 * y]
                    ^ ((~rotated[(x + 1) % 5 + 5 * y])
                        & rotated[(x + 2) % 5 + 5 * y]);
            }
        }
        state[0] ^= kKeccakRoundConstants[round];
    }

#pragma unroll
    for (unsigned index = 0; index < 32; ++index) {
        output[index] = static_cast<std::uint8_t>(
            state[index >> 3] >> ((index & 7U) * 8U));
    }
}

template <unsigned Length>
__device__ __noinline__ void sha256_small(
    const std::uint8_t* input,
    std::uint8_t output[32]) {
    static_assert(Length <= 55, "The small SHA-256 helper accepts one block.");
    std::uint32_t schedule[64];
#pragma unroll
    for (unsigned word = 0; word < 16; ++word) {
        std::uint32_t value = 0;
#pragma unroll
        for (unsigned byte = 0; byte < 4; ++byte) {
            const unsigned offset = word * 4 + byte;
            std::uint8_t source = 0;
            if (offset < Length) {
                source = input[offset];
            } else if (offset == Length) {
                source = 0x80;
            } else if (offset >= 56) {
                const unsigned bit_shift = (63 - offset) * 8;
                source = static_cast<std::uint8_t>(
                    (static_cast<std::uint64_t>(Length) * 8ULL) >> bit_shift);
            }
            value = (value << 8) | source;
        }
        schedule[word] = value;
    }
#pragma unroll
    for (unsigned word = 16; word < 64; ++word) {
        const auto s0 = rotate_right32(schedule[word - 15], 7)
            ^ rotate_right32(schedule[word - 15], 18)
            ^ (schedule[word - 15] >> 3);
        const auto s1 = rotate_right32(schedule[word - 2], 17)
            ^ rotate_right32(schedule[word - 2], 19)
            ^ (schedule[word - 2] >> 10);
        schedule[word] = schedule[word - 16] + s0
            + schedule[word - 7] + s1;
    }

    std::uint32_t digest[8] = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
    };
    std::uint32_t a = digest[0];
    std::uint32_t b = digest[1];
    std::uint32_t c = digest[2];
    std::uint32_t d = digest[3];
    std::uint32_t e = digest[4];
    std::uint32_t f = digest[5];
    std::uint32_t g = digest[6];
    std::uint32_t h = digest[7];
#pragma unroll
    for (unsigned round = 0; round < 64; ++round) {
        const auto sigma1 = rotate_right32(e, 6)
            ^ rotate_right32(e, 11) ^ rotate_right32(e, 25);
        const auto choose = (e & f) ^ ((~e) & g);
        const auto temporary1 = h + sigma1 + choose
            + kSha256RoundConstants[round] + schedule[round];
        const auto sigma0 = rotate_right32(a, 2)
            ^ rotate_right32(a, 13) ^ rotate_right32(a, 22);
        const auto majority = (a & b) ^ (a & c) ^ (b & c);
        const auto temporary2 = sigma0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temporary1;
        d = c;
        c = b;
        b = a;
        a = temporary1 + temporary2;
    }
    digest[0] += a;
    digest[1] += b;
    digest[2] += c;
    digest[3] += d;
    digest[4] += e;
    digest[5] += f;
    digest[6] += g;
    digest[7] += h;
#pragma unroll
    for (unsigned word = 0; word < 8; ++word) {
        output[word * 4] = static_cast<std::uint8_t>(digest[word] >> 24);
        output[word * 4 + 1] = static_cast<std::uint8_t>(digest[word] >> 16);
        output[word * 4 + 2] = static_cast<std::uint8_t>(digest[word] >> 8);
        output[word * 4 + 3] = static_cast<std::uint8_t>(digest[word]);
    }
}

struct DeviceExtendedPrivateKey {
    std::uint8_t key[32];
    std::uint8_t chain_code[32];
};

__device__ __forceinline__ void store_be32_device(
    std::uint8_t* output,
    std::uint32_t value) {
    output[0] = static_cast<std::uint8_t>(value >> 24);
    output[1] = static_cast<std::uint8_t>(value >> 16);
    output[2] = static_cast<std::uint8_t>(value >> 8);
    output[3] = static_cast<std::uint8_t>(value);
}

__device__ __noinline__ bool derive_hardened_child(
    DeviceExtendedPrivateKey& node,
    std::uint32_t child_number) {
    std::uint8_t message[37];
    message[0] = 0;
    memcpy(message + 1, node.key, 32);
    store_be32_device(message + 33, child_number);
    std::uint8_t digest[64];
    HMAC_SHA512(node.chain_code, 32, message, sizeof(message), digest);
    if (!secp256k1_ec_seckey_tweak_add(digest, node.key)) return false;
    memcpy(node.key, digest, 32);
    memcpy(node.chain_code, digest + 32, 32);
    return true;
}

__device__ __noinline__ bool derive_normal_child_from_public_key(
    DeviceExtendedPrivateKey& node,
    std::uint32_t child_number,
    const std::uint8_t public_key[33]) {
    std::uint8_t message[37];
    memcpy(message, public_key, 33);
    store_be32_device(message + 33, child_number);
    std::uint8_t digest[64];
    HMAC_SHA512(node.chain_code, 32, message, sizeof(message), digest);
    if (!secp256k1_ec_seckey_tweak_add(digest, node.key)) return false;
    memcpy(node.key, digest, 32);
    memcpy(node.chain_code, digest + 32, 32);
    return true;
}

template <bool Compressed>
__device__ __noinline__ void serialize_public_keys_group(
    const DeviceExtendedPrivateKey nodes[kAddressCandidatesPerThread],
    bool active[kAddressCandidatesPerThread],
    std::uint8_t output[kAddressCandidatesPerThread][65],
    const secp256k1_ge_storage* precomp,
    std::size_t precomp_pitch) {
    secp256k1_gej points[kAddressCandidatesPerThread];
    secp256k1_fe z_values[kAddressCandidatesPerThread];
    secp256k1_fe inverse_z[kAddressCandidatesPerThread];
    unsigned indices[kAddressCandidatesPerThread];
    unsigned count = 0;

#pragma unroll
    for (unsigned index = 0; index < kAddressCandidatesPerThread; ++index) {
        if (!active[index]) continue;
        secp256k1_scalar scalar;
        if (!secp256k1_scalar_set_b32_seckey(&scalar, nodes[index].key)) {
            active[index] = false;
            continue;
        }
        indices[count] = index;
        secp256k1_ecmult_big(
            &points[count], &scalar, precomp, precomp_pitch);
        z_values[count] = points[count].z;
        ++count;
    }
    if (count == 0) return;

    secp256k1_fe_inv_all_var(count, inverse_z, z_values);
#pragma unroll
    for (unsigned item = 0; item < kAddressCandidatesPerThread; ++item) {
        if (item >= count) break;
        const unsigned index = indices[item];
        secp256k1_ge affine;
        secp256k1_ge_set_gej_zinv(&affine, &points[item], &inverse_z[item]);
        std::size_t output_length = Compressed ? 33U : 65U;
        if (!secp256k1_eckey_pubkey_serialize(
                &affine, output[index], &output_length, Compressed)) {
            active[index] = false;
        }
    }
}

__device__ __forceinline__ std::uint64_t bytes_modulus(
    const std::uint8_t* bytes,
    unsigned byte_count,
    std::uint64_t modulus) {
    std::uint64_t remainder = 0;
    for (unsigned index = 0; index < byte_count; ++index) {
#pragma unroll
        for (int bit = 7; bit >= 0; --bit) {
            // Double without overflowing uint64. At all times remainder < modulus.
            const auto distance = modulus - remainder;
            remainder = remainder >= distance
                ? remainder - distance
                : remainder + remainder;
            if ((bytes[index] >> bit) & 1U) {
                remainder = remainder == modulus - 1 ? 0 : remainder + 1;
            }
        }
    }
    return remainder;
}

__global__ __launch_bounds__(384) void derive_and_match_tron_addresses(
    const std::uint8_t* masters,
    std::uint32_t candidate_count,
    const secp256k1_ge_storage* precomp,
    std::size_t precomp_pitch,
    std::uint64_t suffix_modulus,
    std::uint64_t suffix_remainder,
    std::uint32_t* winner) {
    const auto first_candidate = static_cast<std::uint32_t>(
        (blockIdx.x * blockDim.x + threadIdx.x)
        * kAddressCandidatesPerThread);
    if (first_candidate >= candidate_count) return;

    DeviceExtendedPrivateKey nodes[kAddressCandidatesPerThread];
    bool active[kAddressCandidatesPerThread] = {};
#pragma unroll
    for (unsigned index = 0; index < kAddressCandidatesPerThread; ++index) {
        const auto candidate = first_candidate + index;
        if (candidate >= candidate_count) continue;
        memcpy(
            &nodes[index],
            masters + static_cast<std::size_t>(candidate) * 64,
            64);
        active[index] = derive_hardened_child(nodes[index], 0x8000002cU)
            && derive_hardened_child(nodes[index], 0x800000c3U)
            && derive_hardened_child(nodes[index], 0x80000000U);
    }

    std::uint8_t public_keys[kAddressCandidatesPerThread][65];
#pragma unroll
    for (unsigned depth = 0; depth < 2; ++depth) {
        serialize_public_keys_group<true>(
            nodes, active, public_keys, precomp, precomp_pitch);
#pragma unroll
        for (unsigned index = 0; index < kAddressCandidatesPerThread; ++index) {
            if (active[index]) {
                active[index] = derive_normal_child_from_public_key(
                    nodes[index], 0, public_keys[index]);
            }
        }
    }

    serialize_public_keys_group<false>(
        nodes, active, public_keys, precomp, precomp_pitch);
#pragma unroll
    for (unsigned index = 0; index < kAddressCandidatesPerThread; ++index) {
        if (!active[index]) continue;
        std::uint8_t keccak_hash[32];
        keccak256_64(public_keys[index] + 1, keccak_hash);

        std::uint8_t address_bytes[25];
        address_bytes[0] = 0x41;
        memcpy(address_bytes + 1, keccak_hash + 12, 20);
        std::uint8_t checksum_first[32];
        std::uint8_t checksum_second[32];
        sha256_small<21>(address_bytes, checksum_first);
        sha256_small<32>(checksum_first, checksum_second);
        memcpy(address_bytes + 21, checksum_second, 4);

        if (bytes_modulus(address_bytes, sizeof(address_bytes), suffix_modulus)
            == suffix_remainder) {
            atomicMin(winner, first_candidate + index);
        }
    }
}

__global__ void build_secp256k1_precomp(
    secp256k1_gej* temporary_points,
    secp256k1_fe* z_ratios,
    secp256k1_ge_storage* precomp,
    std::size_t pitch,
    unsigned window_bits) {
    if (blockIdx.x != 0 || threadIdx.x != 0) return;
    const unsigned windows = 256 / window_bits + 1;
    const std::size_t standard_window_size = 1ULL << (window_bits - 1);
    secp256k1_fe inverse_z;
    secp256k1_ge affine;
    secp256k1_ge window_one = secp256k1_ge_const_g;
    secp256k1_gej window_base;
    secp256k1_gej_set_ge(&window_base, &window_one);
    secp256k1_fe_set_int(&z_ratios[0], 0);

    for (unsigned row = 0; row < windows; ++row) {
        const std::size_t window_size = row == windows - 1
            ? (1ULL << (256 % window_bits))
            : standard_window_size;
        if (row > 0) {
            for (unsigned bit = 0; bit < window_bits; ++bit) {
                secp256k1_gej_double_var(&window_base, &window_base, nullptr);
            }
        }
        temporary_points[0] = window_base;
        secp256k1_ge_set_gej(&window_one, &window_base);
        for (std::size_t index = 1; index < window_size; ++index) {
            secp256k1_gej_add_ge_var(
                &temporary_points[index],
                &temporary_points[index - 1],
                &window_one,
                &z_ratios[index]);
        }

        std::size_t index = window_size - 1;
        secp256k1_fe_inv(&inverse_z, &temporary_points[index].z);
        secp256k1_ge_set_gej_zinv(
            &affine, &temporary_points[index], &inverse_z);
        auto* row_precomp = reinterpret_cast<secp256k1_ge_storage*>(
            reinterpret_cast<char*>(precomp) + row * pitch);
        secp256k1_ge_to_storage(&row_precomp[index], &affine);
        while (index > 0) {
            secp256k1_fe_mul(&inverse_z, &inverse_z, &z_ratios[index]);
            --index;
            secp256k1_ge_set_gej_zinv(
                &affine, &temporary_points[index], &inverse_z);
            secp256k1_ge_to_storage(&row_precomp[index], &affine);
        }
    }
}

std::uint64_t load_be64_host(const std::uint8_t* input) {
    std::uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i) value = (value << 8) | input[i];
    return value;
}

bool cuda_ok(cudaError_t status, const char* operation, std::string& error) {
    if (status == cudaSuccess) return true;
    error = std::string(operation) + ": " + cudaGetErrorString(status);
    return false;
}

bool configure_launch_dimensions(
    unsigned requested_master_block_size,
    unsigned requested_address_block_size,
    std::string& error) {
    cudaFuncAttributes master_attributes{};
    cudaFuncAttributes address_attributes{};
    if (!cuda_ok(
            cudaFuncGetAttributes(
                &master_attributes, derive_mnemonic_master_keys_fused),
            "Inspecting the CUDA BIP39 kernel",
            error)
        || !cuda_ok(
            cudaFuncGetAttributes(
                &address_attributes, derive_and_match_tron_addresses),
            "Inspecting the CUDA TRON kernel",
            error)) {
        return false;
    }

    int device_limit = 0;
    if (!cuda_ok(
            cudaDeviceGetAttribute(
                &device_limit, cudaDevAttrMaxThreadsPerBlock, 0),
            "Reading the CUDA block-size limit",
            error)) {
        return false;
    }
    const auto master_limit = static_cast<unsigned>(std::max(
        0, std::min(device_limit, master_attributes.maxThreadsPerBlock)));
    const auto address_limit = static_cast<unsigned>(std::max(
        0, std::min(device_limit, address_attributes.maxThreadsPerBlock)));
    const auto validate_request = [&](unsigned requested,
                                      unsigned limit,
                                      const char* stage) -> bool {
        if (requested != 0
            && (requested < 32
                || requested % 32 != 0
                || requested > limit)) {
            std::ostringstream message;
            message << "The CUDA " << stage
                    << " block size must be a warp multiple between 32 and "
                    << limit << '.';
            error = message.str();
            return false;
        }
        return true;
    };
    if (!validate_request(
            requested_master_block_size, master_limit, "BIP39")
        || !validate_request(
            requested_address_block_size, address_limit, "address")) {
        return false;
    }

    int minimum_grid = 0;
    int master_block = 0;
    if (requested_master_block_size == 0
        && !cuda_ok(
            cudaOccupancyMaxPotentialBlockSize(
                &minimum_grid,
                &master_block,
                derive_mnemonic_master_keys_fused,
                0,
                0),
            "Auto-tuning the CUDA BIP39 block size",
            error)) {
        return false;
    }
    int address_block = 0;
    if (requested_address_block_size == 0
        && !cuda_ok(
            cudaOccupancyMaxPotentialBlockSize(
                &minimum_grid,
                &address_block,
                derive_and_match_tron_addresses,
                0,
                0),
            "Auto-tuning the CUDA TRON block size",
            error)) {
        return false;
    }
    if ((requested_master_block_size == 0 && master_block <= 0)
        || (requested_address_block_size == 0 && address_block <= 0)) {
        error = "CUDA occupancy analysis returned an invalid block size.";
        return false;
    }
    g_master_block_size = requested_master_block_size == 0
        ? static_cast<unsigned>(master_block)
        : requested_master_block_size;
    g_address_block_size = requested_address_block_size == 0
        ? static_cast<unsigned>(address_block)
        : requested_address_block_size;
    return true;
}

bool initialize_secp256k1_precomp(std::string& error) {
    g_secp_windows = 256 / g_secp_window_bits + 1;
    const auto window_size = static_cast<std::size_t>(1)
        << (g_secp_window_bits - 1);
    if (!cuda_ok(
            cudaMemcpyToSymbol(
                ECMULT_WINDOW_SIZE_CONST,
                &g_secp_window_bits,
                sizeof(g_secp_window_bits)),
            "Configuring the CUDA secp256k1 window size",
            error)
        || !cuda_ok(
            cudaMemcpyToSymbol(
                WINDOWS_SIZE_CONST,
                &g_secp_windows,
                sizeof(g_secp_windows)),
            "Configuring the CUDA secp256k1 window count",
            error)
        || !cuda_ok(
            cudaMallocPitch(
                reinterpret_cast<void**>(&g_secp_precomp),
                &g_secp_precomp_pitch,
                sizeof(secp256k1_ge_storage) * window_size,
                g_secp_windows),
            "Allocating the CUDA secp256k1 precomputation table",
            error)) {
        return false;
    }

    secp256k1_gej* temporary_points = nullptr;
    secp256k1_fe* z_ratios = nullptr;
    if (!cuda_ok(
            cudaMalloc(
                reinterpret_cast<void**>(&temporary_points),
                sizeof(secp256k1_gej) * window_size),
            "Allocating temporary CUDA secp256k1 points",
            error)
        || !cuda_ok(
            cudaMalloc(
                reinterpret_cast<void**>(&z_ratios),
                sizeof(secp256k1_fe) * window_size),
            "Allocating temporary CUDA secp256k1 ratios",
            error)) {
        if (temporary_points != nullptr) (void)cudaFree(temporary_points);
        if (z_ratios != nullptr) (void)cudaFree(z_ratios);
        return false;
    }

    build_secp256k1_precomp<<<1, 1>>>(
        temporary_points,
        z_ratios,
        g_secp_precomp,
        g_secp_precomp_pitch,
        g_secp_window_bits);
    const auto launch_status = cudaGetLastError();
    const auto synchronize_status = launch_status == cudaSuccess
        ? cudaDeviceSynchronize()
        : launch_status;
    (void)cudaFree(temporary_points);
    (void)cudaFree(z_ratios);
    return cuda_ok(
        synchronize_status,
        "Building the CUDA secp256k1 precomputation table",
        error);
}

bool launch_mnemonic_master_pipeline(
    CudaBatchSlot& slot,
    std::uint64_t base_high,
    std::uint64_t base_low,
    std::uint64_t first_candidate,
    std::uint32_t candidate_count,
    std::string& error) {
    const unsigned threads = g_master_block_size;
    const unsigned blocks = (candidate_count + threads - 1) / threads;
    derive_mnemonic_master_keys_fused<<<blocks, threads, 0, slot.stream>>>(
        base_high,
        base_low,
        first_candidate,
        candidate_count,
        slot.device_masters);
    return cuda_ok(
        cudaGetLastError(),
        "Launching the fused CUDA BIP39/PBKDF2 master-key kernel",
        error);
}

}  // namespace

bool cuda_mnemonic_query_device(
    CudaMnemonicDeviceInfo& info,
    std::string& error) {
    info = {};
    int device_count = 0;
    if (!cuda_ok(cudaGetDeviceCount(&device_count), "cudaGetDeviceCount", error)
        || device_count <= 0) {
        if (error.empty()) error = "No CUDA GPU was found.";
        return false;
    }
    if (!cuda_ok(cudaSetDevice(0), "cudaSetDevice", error)) return false;

    cudaDeviceProp properties{};
    if (!cuda_ok(
            cudaGetDeviceProperties(&properties, 0),
            "cudaGetDeviceProperties",
            error)) {
        return false;
    }
    if (properties.major < 7
        || (properties.major == 7 && properties.minor < 5)) {
        error = "This build requires an RTX-class CUDA GPU with compute capability 7.5 or newer.";
        return false;
    }

    std::size_t free_memory = 0;
    std::size_t total_memory = 0;
    if (!cuda_ok(
            cudaMemGetInfo(&free_memory, &total_memory),
            "cudaMemGetInfo",
            error)) {
        return false;
    }

    std::ostringstream name;
    name << properties.name << " (SM " << properties.major << '.'
         << properties.minor << ", " << properties.multiProcessorCount
         << " multiprocessors)";
    info.name = name.str();
    info.compute_major = properties.major;
    info.compute_minor = properties.minor;
    info.multiprocessor_count = properties.multiProcessorCount;
    info.free_memory = free_memory;
    info.total_memory = total_memory;
    error.clear();
    return true;
}

bool cuda_mnemonic_initialize(
    const std::filesystem::path& wordlist_path,
    std::size_t batch_capacity,
    unsigned requested_master_block_size,
    unsigned requested_address_block_size,
    std::string& device_name,
    std::string& error) {
    cuda_mnemonic_shutdown();
    if (batch_capacity == 0
        || batch_capacity > std::numeric_limits<std::uint32_t>::max()) {
        error = "The CUDA mnemonic batch capacity is invalid.";
        return false;
    }

    CudaMnemonicDeviceInfo device_info;
    if (!cuda_mnemonic_query_device(device_info, error)) return false;
    if (!configure_launch_dimensions(
            requested_master_block_size,
            requested_address_block_size,
            error)) {
        return false;
    }

    std::ifstream input(wordlist_path);
    if (!input) {
        error = "BIP39 English word list is missing: " + wordlist_path.string();
        return false;
    }
    std::array<std::array<char, 9>, 2048> words{};
    std::string line;
    std::size_t count = 0;
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (count >= words.size() || line.empty() || line.size() > 8) {
            error = "The BIP39 English word list is malformed.";
            return false;
        }
        std::memcpy(words[count].data(), line.data(), line.size());
        ++count;
    }
    if (count != words.size()) {
        error = "The BIP39 English word list must contain 2048 words.";
        return false;
    }
    if (!cuda_ok(
            cudaMemcpyToSymbol(kBip39Words, words.data(), sizeof(words)),
            "Loading the BIP39 dictionary into CUDA constant memory",
            error)) {
        return false;
    }

    if (!initialize_secp256k1_precomp(error)) {
        cuda_mnemonic_shutdown();
        return false;
    }

    const auto output_bytes = batch_capacity * 64;
    g_batch_capacity = batch_capacity;
    for (auto& slot : g_slots) {
        if (!cuda_ok(
                cudaMalloc(
                    reinterpret_cast<void**>(&slot.device_masters),
                    output_bytes),
                "Allocating CUDA master-key memory",
                error)
            || !cuda_ok(
                cudaHostAlloc(
                    reinterpret_cast<void**>(&slot.pinned_masters),
                    64,
                    cudaHostAllocPortable),
                "Allocating pinned winner-key memory",
                error)
            || !cuda_ok(
                cudaMalloc(
                    reinterpret_cast<void**>(&slot.device_winner),
                    sizeof(std::uint32_t)),
                "Allocating the CUDA winner index",
                error)
            || !cuda_ok(
                cudaHostAlloc(
                    reinterpret_cast<void**>(&slot.pinned_winner),
                    sizeof(std::uint32_t),
                    cudaHostAllocPortable),
                "Allocating the pinned winner index",
                error)
            || !cuda_ok(
                cudaStreamCreateWithFlags(&slot.stream, cudaStreamNonBlocking),
                "Creating CUDA mnemonic stream",
                error)
            || !cuda_ok(
                cudaEventCreate(&slot.started),
                "Creating CUDA start event",
                error)
            || !cuda_ok(
                cudaEventCreate(&slot.finished),
                "Creating CUDA finish event",
                error)) {
            cuda_mnemonic_shutdown();
            return false;
        }
    }
    device_name = device_info.name;
    return true;
}

bool cuda_mnemonic_derive_batch(
    const Entropy128& random_base,
    std::uint64_t first_candidate,
    std::uint32_t candidate_count,
    std::uint8_t*& pinned_master_keys,
    double& gpu_seconds,
    std::string& error) {
    pinned_master_keys = nullptr;
    gpu_seconds = 0;
    if (candidate_count != 1) {
        error = "The CUDA master-key cross-check accepts one candidate.";
        return false;
    }
    auto& slot = g_slots[0];
    if (slot.state != 0 || slot.device_masters == nullptr
        || slot.pinned_masters == nullptr) {
        error = "The CUDA mnemonic cross-check slot is unavailable.";
        return false;
    }
    const auto base_high = load_be64_host(random_base.data());
    const auto base_low = load_be64_host(random_base.data() + 8);
    if (!cuda_ok(
            cudaEventRecord(slot.started, slot.stream),
            "Recording the CUDA cross-check start event",
            error)) {
        return false;
    }
    if (!launch_mnemonic_master_pipeline(
            slot,
            base_high,
            base_low,
            first_candidate,
            1,
            error)
        || !cuda_ok(
            cudaMemcpyAsync(
                slot.pinned_masters,
                slot.device_masters,
                64,
                cudaMemcpyDeviceToHost,
                slot.stream),
            "Reading the CUDA cross-check master key",
            error)
        || !cuda_ok(
            cudaEventRecord(slot.finished, slot.stream),
            "Recording the CUDA cross-check finish event",
            error)
        || !cuda_ok(
            cudaEventSynchronize(slot.finished),
            "Waiting for the CUDA cross-check",
            error)) {
        return false;
    }
    float milliseconds = 0;
    if (!cuda_ok(
            cudaEventElapsedTime(&milliseconds, slot.started, slot.finished),
            "Measuring the CUDA cross-check",
            error)) {
        return false;
    }
    slot.candidate_count = 1;
    slot.state = 2;
    pinned_master_keys = slot.pinned_masters;
    gpu_seconds = static_cast<double>(milliseconds) / 1000.0;
    return true;
}

bool cuda_mnemonic_launch_search_batch(
    unsigned slot_index,
    const Entropy128& random_base,
    std::uint64_t first_candidate,
    std::uint32_t candidate_count,
    std::uint64_t suffix_modulus,
    std::uint64_t suffix_remainder,
    std::string& error) {
    if (slot_index >= kCudaSlotCount) {
        error = "The CUDA mnemonic slot index is invalid.";
        return false;
    }
    auto& slot = g_slots[slot_index];
    if (slot.device_masters == nullptr || slot.pinned_masters == nullptr
        || slot.device_winner == nullptr || slot.pinned_winner == nullptr
        || g_secp_precomp == nullptr) {
        error = "The CUDA mnemonic engine is not initialized.";
        return false;
    }
    if (slot.state != 0) {
        error = "The CUDA mnemonic slot is still in use.";
        return false;
    }
    if (candidate_count == 0 || candidate_count > g_batch_capacity) {
        error = "The CUDA mnemonic batch exceeds the allocated capacity.";
        return false;
    }
    if (suffix_modulus == 0 || suffix_remainder >= suffix_modulus) {
        error = "The CUDA Base58 suffix match parameters are invalid.";
        return false;
    }
    const auto base_high = load_be64_host(random_base.data());
    const auto base_low = load_be64_host(random_base.data() + 8);
    if (!cuda_ok(
            cudaEventRecord(slot.started, slot.stream),
            "Recording CUDA start event",
            error)) {
        return false;
    }
    if (!launch_mnemonic_master_pipeline(
            slot,
            base_high,
            base_low,
            first_candidate,
            candidate_count,
            error)
        || !cuda_ok(
            cudaMemsetAsync(
                slot.device_winner,
                0xff,
                sizeof(std::uint32_t),
                slot.stream),
            "Resetting the CUDA winner index",
            error)) {
        return false;
    }
    const unsigned threads = g_address_block_size;
    const unsigned candidates_per_block =
        threads * kAddressCandidatesPerThread;
    const unsigned blocks =
        (candidate_count + candidates_per_block - 1) / candidates_per_block;
    derive_and_match_tron_addresses<<<blocks, threads, 0, slot.stream>>>(
        slot.device_masters,
        candidate_count,
        g_secp_precomp,
        g_secp_precomp_pitch,
        suffix_modulus,
        suffix_remainder,
        slot.device_winner);
    if (!cuda_ok(
            cudaGetLastError(),
            "Launching the CUDA TRON derivation kernel",
            error)
        || !cuda_ok(
            cudaMemcpyAsync(
                slot.pinned_winner,
                slot.device_winner,
                sizeof(std::uint32_t),
                cudaMemcpyDeviceToHost,
                slot.stream),
            "Reading the CUDA winner index",
            error)
        || !cuda_ok(
            cudaEventRecord(slot.finished, slot.stream),
            "Recording CUDA finish event",
            error)) {
        return false;
    }
    slot.candidate_count = candidate_count;
    slot.state = 1;
    return true;
}

bool cuda_mnemonic_wait_search_batch(
    unsigned slot_index,
    std::uint32_t& winner_index,
    std::uint8_t*& pinned_winner_master,
    double& gpu_seconds,
    std::string& error) {
    winner_index = std::numeric_limits<std::uint32_t>::max();
    pinned_winner_master = nullptr;
    gpu_seconds = 0;
    if (slot_index >= kCudaSlotCount) {
        error = "The CUDA mnemonic slot index is invalid.";
        return false;
    }
    auto& slot = g_slots[slot_index];
    if (slot.state != 1) {
        error = "The CUDA mnemonic slot has no in-flight batch.";
        return false;
    }
    if (!cuda_ok(
            cudaEventSynchronize(slot.finished),
            "Waiting for the CUDA mnemonic batch",
            error)) {
        return false;
    }
    float milliseconds = 0;
    if (!cuda_ok(
            cudaEventElapsedTime(&milliseconds, slot.started, slot.finished),
            "Measuring the CUDA mnemonic kernel",
            error)) {
        return false;
    }
    gpu_seconds = static_cast<double>(milliseconds) / 1000.0;
    winner_index = *slot.pinned_winner;
    if (winner_index < slot.candidate_count) {
        if (!cuda_ok(
                cudaMemcpyAsync(
                    slot.pinned_masters,
                    slot.device_masters
                        + static_cast<std::size_t>(winner_index) * 64,
                    64,
                    cudaMemcpyDeviceToHost,
                    slot.stream),
                "Reading the winning CUDA BIP32 master key",
                error)
            || !cuda_ok(
                cudaStreamSynchronize(slot.stream),
                "Waiting for the winning CUDA BIP32 master key",
                error)) {
            return false;
        }
        pinned_winner_master = slot.pinned_masters;
    }
    slot.state = 2;
    return true;
}

void cuda_mnemonic_clear_slot(
    unsigned slot_index,
    std::size_t candidate_count) noexcept {
    if (slot_index >= kCudaSlotCount) return;
    auto& slot = g_slots[slot_index];
    const auto bounded = std::min(candidate_count, g_batch_capacity);
    if (slot.device_masters != nullptr && bounded != 0) {
        (void)cudaMemsetAsync(
            slot.device_masters, 0, bounded * 64, slot.stream);
    }
    if (slot.pinned_masters != nullptr) {
        SecureZeroMemory(slot.pinned_masters, 64);
    }
    if (slot.pinned_winner != nullptr) {
        *slot.pinned_winner = std::numeric_limits<std::uint32_t>::max();
    }
    slot.candidate_count = 0;
    slot.state = 0;
}

void cuda_mnemonic_clear_host(std::size_t candidate_count) noexcept {
    cuda_mnemonic_clear_slot(0, candidate_count);
}

void cuda_mnemonic_shutdown() noexcept {
    for (auto& slot : g_slots) {
        if (slot.stream != nullptr) {
            (void)cudaStreamSynchronize(slot.stream);
        }
        if (slot.device_masters != nullptr) {
            if (g_batch_capacity != 0) {
                (void)cudaMemset(
                    slot.device_masters, 0, g_batch_capacity * 64);
            }
            (void)cudaFree(slot.device_masters);
            slot.device_masters = nullptr;
        }
        if (slot.pinned_masters != nullptr) {
            SecureZeroMemory(slot.pinned_masters, 64);
            (void)cudaFreeHost(slot.pinned_masters);
            slot.pinned_masters = nullptr;
        }
        if (slot.device_winner != nullptr) {
            (void)cudaFree(slot.device_winner);
            slot.device_winner = nullptr;
        }
        if (slot.pinned_winner != nullptr) {
            *slot.pinned_winner = std::numeric_limits<std::uint32_t>::max();
            (void)cudaFreeHost(slot.pinned_winner);
            slot.pinned_winner = nullptr;
        }
        if (slot.started != nullptr) {
            (void)cudaEventDestroy(slot.started);
            slot.started = nullptr;
        }
        if (slot.finished != nullptr) {
            (void)cudaEventDestroy(slot.finished);
            slot.finished = nullptr;
        }
        if (slot.stream != nullptr) {
            (void)cudaStreamDestroy(slot.stream);
            slot.stream = nullptr;
        }
        slot.candidate_count = 0;
        slot.state = 0;
    }
    if (g_secp_precomp != nullptr) {
        (void)cudaFree(g_secp_precomp);
        g_secp_precomp = nullptr;
    }
    g_secp_precomp_pitch = 0;
    g_secp_windows = 0;
    g_batch_capacity = 0;
    g_master_block_size = 256;
    g_address_block_size = 256;
}

unsigned cuda_mnemonic_master_block_size() noexcept {
    return g_master_block_size;
}

unsigned cuda_mnemonic_address_block_size() noexcept {
    return g_address_block_size;
}

unsigned cuda_mnemonic_address_candidates_per_thread() noexcept {
    return kAddressCandidatesPerThread;
}

}  // namespace trx
