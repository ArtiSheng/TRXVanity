#include "crypto.hpp"

#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>
#include <secp256k1.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <vector>

namespace trx {
namespace {

constexpr char kBase58Alphabet[] =
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

struct SecpContext {
    secp256k1_context* value = nullptr;

    SecpContext() {
        value = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
        if (value != nullptr) {
            std::array<std::uint8_t, 32> seed{};
            if (BCryptGenRandom(
                    nullptr,
                    seed.data(),
                    static_cast<ULONG>(seed.size()),
                    BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0) {
                (void)secp256k1_context_randomize(value, seed.data());
            }
            secure_zero(seed.data(), seed.size());
        }
    }

    ~SecpContext() {
        if (value != nullptr) {
            secp256k1_context_destroy(value);
            value = nullptr;
        }
    }
};

secp256k1_context* context() {
    static SecpContext holder;
    return holder.value;
}

inline std::uint64_t rotate_left(std::uint64_t value, unsigned count) {
    return count == 0 ? value : (value << count) | (value >> (64U - count));
}

void keccak_permute(std::uint64_t state[25]) {
    static constexpr std::uint64_t round_constants[24] = {
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
    // Rho offsets and Pi destinations for the single 24-lane cycle. Keeping
    // Pi in place avoids clearing and copying a second 200-byte state every
    // round, which matters for the 64-byte public-key hash used by TRON.
    static constexpr unsigned rotation_offsets[24] = {
         1,  3,  6, 10, 15, 21, 28, 36,
        45, 55,  2, 14, 27, 41, 56,  8,
        25, 43, 62, 18, 39, 61, 20, 44,
    };
    static constexpr unsigned pi_destinations[24] = {
        10,  7, 11, 17, 18,  3,  5, 16,
         8, 21, 24,  4, 15, 23, 19, 13,
        12,  2, 20, 14, 22,  9,  6,  1,
    };

    for (unsigned round = 0; round < 24; ++round) {
        const std::uint64_t c0 = state[0] ^ state[5] ^ state[10]
            ^ state[15] ^ state[20];
        const std::uint64_t c1 = state[1] ^ state[6] ^ state[11]
            ^ state[16] ^ state[21];
        const std::uint64_t c2 = state[2] ^ state[7] ^ state[12]
            ^ state[17] ^ state[22];
        const std::uint64_t c3 = state[3] ^ state[8] ^ state[13]
            ^ state[18] ^ state[23];
        const std::uint64_t c4 = state[4] ^ state[9] ^ state[14]
            ^ state[19] ^ state[24];
        const std::uint64_t d0 = c4 ^ rotate_left(c1, 1);
        const std::uint64_t d1 = c0 ^ rotate_left(c2, 1);
        const std::uint64_t d2 = c1 ^ rotate_left(c3, 1);
        const std::uint64_t d3 = c2 ^ rotate_left(c4, 1);
        const std::uint64_t d4 = c3 ^ rotate_left(c0, 1);
        for (unsigned row = 0; row < 25; row += 5) {
            state[row] ^= d0;
            state[row + 1] ^= d1;
            state[row + 2] ^= d2;
            state[row + 3] ^= d3;
            state[row + 4] ^= d4;
        }

        std::uint64_t carried = state[1];
        for (unsigned index = 0; index < 24; ++index) {
            const unsigned destination = pi_destinations[index];
            const std::uint64_t displaced = state[destination];
            state[destination] = rotate_left(carried, rotation_offsets[index]);
            carried = displaced;
        }

        for (unsigned row = 0; row < 25; row += 5) {
            const std::uint64_t a0 = state[row];
            const std::uint64_t a1 = state[row + 1];
            const std::uint64_t a2 = state[row + 2];
            const std::uint64_t a3 = state[row + 3];
            const std::uint64_t a4 = state[row + 4];
            state[row] = a0 ^ ((~a1) & a2);
            state[row + 1] = a1 ^ ((~a2) & a3);
            state[row + 2] = a2 ^ ((~a3) & a4);
            state[row + 3] = a3 ^ ((~a4) & a0);
            state[row + 4] = a4 ^ ((~a0) & a1);
        }
        state[0] ^= round_constants[round];
    }
}

}  // namespace

void secure_zero(void* data, std::size_t size) noexcept {
    if (data != nullptr && size != 0) {
        SecureZeroMemory(data, size);
    }
}

bool random_private_key(PrivateKey& output, std::string& error) {
    auto* ctx = context();
    if (ctx == nullptr) {
        error = "Unable to create the secp256k1 verification context.";
        return false;
    }

    for (unsigned attempt = 0; attempt < 128; ++attempt) {
        if (BCryptGenRandom(
                nullptr,
                output.data(),
                static_cast<ULONG>(output.size()),
                BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
            error = "BCryptGenRandom failed.";
            secure_zero(output.data(), output.size());
            return false;
        }
        if (secp256k1_ec_seckey_verify(ctx, output.data()) == 1) {
            return true;
        }
        secure_zero(output.data(), output.size());
    }

    error = "Windows did not produce a valid secp256k1 private scalar.";
    return false;
}

bool public_key(const PrivateKey& private_key, PublicKey& output, std::string& error) {
    auto* ctx = context();
    if (ctx == nullptr) {
        error = "Unable to create the secp256k1 context.";
        return false;
    }

    secp256k1_pubkey key{};
    if (secp256k1_ec_pubkey_create(ctx, &key, private_key.data()) != 1) {
        error = "secp256k1 rejected the private key.";
        return false;
    }
    std::size_t output_size = output.size();
    if (secp256k1_ec_pubkey_serialize(
            ctx,
            output.data(),
            &output_size,
            &key,
            SECP256K1_EC_UNCOMPRESSED) != 1
        || output_size != output.size()) {
        error = "Unable to serialize the secp256k1 public key.";
        return false;
    }
    return true;
}

bool add_tweak(
    const PrivateKey& base,
    const PrivateKey& tweak,
    PrivateKey& output,
    std::string& error) {
    auto* ctx = context();
    if (ctx == nullptr) {
        error = "Unable to create the secp256k1 context.";
        return false;
    }
    output = base;
    if (secp256k1_ec_seckey_tweak_add(ctx, output.data(), tweak.data()) != 1) {
        secure_zero(output.data(), output.size());
        error = "The recovered GPU scalar is outside the secp256k1 group.";
        return false;
    }
    return true;
}

std::array<std::uint8_t, 32> keccak256(const std::uint8_t* data, std::size_t size) {
    constexpr std::size_t rate = 136;
    constexpr std::size_t rate_lanes = rate / sizeof(std::uint64_t);
    std::uint64_t state[25]{};
    std::size_t cursor = 0;

    while (size - cursor >= rate) {
        for (std::size_t lane = 0; lane < rate_lanes; ++lane) {
            std::uint64_t word = 0;
            // This program is Windows x64-only, so native words are little
            // endian, exactly matching Keccak's lane representation.
            std::memcpy(&word, data + cursor + lane * sizeof(word), sizeof(word));
            state[lane] ^= word;
        }
        keccak_permute(state);
        cursor += rate;
    }

    const auto remaining = size - cursor;
    const auto whole_lanes = remaining / sizeof(std::uint64_t);
    for (std::size_t lane = 0; lane < whole_lanes; ++lane) {
        std::uint64_t word = 0;
        std::memcpy(&word, data + cursor + lane * sizeof(word), sizeof(word));
        state[lane] ^= word;
    }
    std::uint64_t tail = 0;
    for (std::size_t index = whole_lanes * sizeof(std::uint64_t);
         index < remaining;
         ++index) {
        tail |= static_cast<std::uint64_t>(data[cursor + index])
            << ((index % sizeof(std::uint64_t)) * 8);
    }
    state[whole_lanes] ^= tail;
    state[remaining / 8] ^= 0x01ULL << ((remaining % 8) * 8);
    state[rate_lanes - 1] ^= 0x8000000000000000ULL;
    keccak_permute(state);

    std::array<std::uint8_t, 32> output{};
    std::memcpy(output.data(), state, output.size());
    secure_zero(state, sizeof(state));
    return output;
}

bool sha256(
    const std::uint8_t* data,
    std::size_t size,
    std::array<std::uint8_t, 32>& output,
    std::string& error) {
    const auto status = BCryptHash(
        BCRYPT_SHA256_ALG_HANDLE,
        nullptr,
        0,
        const_cast<PUCHAR>(data),
        static_cast<ULONG>(size),
        output.data(),
        static_cast<ULONG>(output.size()));
    if (status != 0) {
        error = "Windows SHA-256 hashing failed.";
        return false;
    }
    return true;
}

std::string base58_encode(const std::uint8_t* data, std::size_t size) {
    if (data == nullptr || size == 0) {
        return {};
    }
    std::size_t zero_count = 0;
    while (zero_count < size && data[zero_count] == 0) {
        ++zero_count;
    }

    const auto significant_size = size - zero_count;
    const auto encoded_capacity = significant_size * 138 / 100 + 1;
    constexpr std::size_t kStackCapacity = 128;
    std::array<std::uint8_t, kStackCapacity> stack_digits{};
    std::vector<std::uint8_t> heap_digits;
    std::uint8_t* digits = stack_digits.data();
    if (encoded_capacity > stack_digits.size()) {
        heap_digits.assign(encoded_capacity, 0);
        digits = heap_digits.data();
    }
    std::uint8_t* const digits_end = digits + encoded_capacity;

    std::size_t encoded_length = 0;
    for (std::size_t index = zero_count; index < size; ++index) {
        unsigned carry = data[index];
        std::size_t visited = 0;
        auto* digit = digits_end;
        while ((carry != 0 || visited < encoded_length) && digit != digits) {
            --digit;
            carry += 256U * *digit;
            *digit = static_cast<std::uint8_t>(carry % 58U);
            carry /= 58U;
            ++visited;
        }
        encoded_length = visited;
    }

    auto* first = digits_end - encoded_length;
    while (first != digits_end && *first == 0) {
        ++first;
    }
    std::string output(zero_count, kBase58Alphabet[0]);
    output.reserve(zero_count + static_cast<std::size_t>(digits_end - first));
    while (first != digits_end) {
        output.push_back(kBase58Alphabet[*first++]);
    }
    return output;
}

bool tron_address_from_public_key(
    const PublicKey& pub,
    std::string& address,
    std::array<std::uint8_t, 32>& public_hash,
    std::string& error) {
    public_hash = keccak256(pub.data() + 1, 64);
    std::array<std::uint8_t, 25> raw{};
    raw[0] = 0x41;
    std::memcpy(raw.data() + 1, public_hash.data() + 12, 20);

    std::array<std::uint8_t, 32> first{};
    std::array<std::uint8_t, 32> second{};
    if (!sha256(raw.data(), 21, first, error)
        || !sha256(first.data(), first.size(), second, error)) {
        secure_zero(first.data(), first.size());
        secure_zero(second.data(), second.size());
        return false;
    }
    std::memcpy(raw.data() + 21, second.data(), 4);
    address = base58_encode(raw.data(), raw.size());

    secure_zero(first.data(), first.size());
    secure_zero(second.data(), second.size());
    return true;
}

bool tron_address(
    const PrivateKey& private_key,
    std::string& address,
    std::string& error) {
    PublicKey pub{};
    if (!public_key(private_key, pub, error)) {
        return false;
    }
    std::array<std::uint8_t, 32> public_hash{};
    const bool encoded = tron_address_from_public_key(
        pub, address, public_hash, error);
    secure_zero(pub.data(), pub.size());
    return encoded;
}

std::string hex_upper(const std::uint8_t* data, std::size_t size) {
    static constexpr char digits[] = "0123456789ABCDEF";
    std::string output(size * 2, '\0');
    for (std::size_t i = 0; i < size; ++i) {
        output[i * 2] = digits[data[i] >> 4];
        output[i * 2 + 1] = digits[data[i] & 0x0f];
    }
    return output;
}

bool matches(const std::string& address, const std::string& prefix, const std::string& suffix) {
    if (!prefix.empty()
        && (address.size() < 2
            || prefix.size() > address.size() - 2
            || std::memcmp(address.data() + 2, prefix.data(), prefix.size()) != 0)) {
        return false;
    }
    return suffix.empty()
        || (suffix.size() <= address.size()
            && std::memcmp(
                address.data() + address.size() - suffix.size(),
                suffix.data(),
                suffix.size()) == 0);
}

bool crypto_self_test(std::string& error) {
    const auto empty_hash = keccak256(nullptr, 0);
    if (hex_upper(empty_hash.data(), empty_hash.size())
        != "C5D2460186F7233C927E7DB2DCC703C0E500B653CA82273B7BFAD8045D85A470") {
        error = "Keccak-256 empty-input vector failed.";
        return false;
    }
    static constexpr std::uint8_t abc[] = {'a', 'b', 'c'};
    const auto abc_hash = keccak256(abc, sizeof(abc));
    if (hex_upper(abc_hash.data(), abc_hash.size())
        != "4E03657AEA45A94FC7D47BA826C8D667C0D1E6E33A64A036EC44F58FA12D6C45") {
        error = "Keccak-256 abc vector failed.";
        return false;
    }

    const std::array<std::uint8_t, 4> leading_zero_vector{{0, 0, 0, 1}};
    if (base58_encode(leading_zero_vector.data(), leading_zero_vector.size())
        != "1112") {
        error = "Base58 leading-zero vector failed.";
        return false;
    }

    // Cross-check the optimized base-256-to-base-58 conversion against the
    // independent long-division formulation it replaced. Deterministic input
    // keeps startup tests reproducible while exercising varied leading zeros.
    const auto reference_base58 = [](const std::uint8_t* data, std::size_t size) {
        if (data == nullptr || size == 0) {
            return std::string{};
        }
        std::size_t zero_count = 0;
        while (zero_count < size && data[zero_count] == 0) {
            ++zero_count;
        }
        std::vector<std::uint8_t> input(data, data + size);
        std::string reversed;
        reversed.reserve(size * 2);
        std::size_t start = zero_count;
        while (start < input.size()) {
            unsigned remainder = 0;
            for (std::size_t index = start; index < input.size(); ++index) {
                const unsigned accumulator = remainder * 256U + input[index];
                input[index] = static_cast<std::uint8_t>(accumulator / 58U);
                remainder = accumulator % 58U;
            }
            reversed.push_back(kBase58Alphabet[remainder]);
            while (start < input.size() && input[start] == 0) {
                ++start;
            }
        }
        reversed.append(zero_count, kBase58Alphabet[0]);
        std::reverse(reversed.begin(), reversed.end());
        return reversed;
    };
    std::array<std::uint8_t, 64> random_bytes{};
    std::uint32_t random_state = 0x9e3779b9U;
    for (std::size_t test_size = 1; test_size <= random_bytes.size(); ++test_size) {
        for (std::size_t index = 0; index < test_size; ++index) {
            random_state ^= random_state << 13;
            random_state ^= random_state >> 17;
            random_state ^= random_state << 5;
            random_bytes[index] = static_cast<std::uint8_t>(random_state);
        }
        const auto leading_zeros = std::min(test_size, test_size % 7);
        std::fill_n(random_bytes.begin(), leading_zeros, 0);
        if (base58_encode(random_bytes.data(), test_size)
            != reference_base58(random_bytes.data(), test_size)) {
            error = "Base58 deterministic randomized cross-check failed.";
            return false;
        }
    }

    PrivateKey one{};
    one.back() = 1;
    PublicKey pub{};
    if (!public_key(one, pub, error)) {
        return false;
    }
    const std::string expected_public =
        "0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"
        "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8";
    if (hex_upper(pub.data(), pub.size()) != expected_public) {
        error = "secp256k1 private-key-one vector failed.";
        return false;
    }

    std::string address;
    if (!tron_address(one, address, error)) {
        return false;
    }
    if (address != "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC") {
        error = "TRON private-key-one address vector failed: " + address;
        return false;
    }
    secure_zero(one.data(), one.size());
    secure_zero(pub.data(), pub.size());
    return true;
}

}  // namespace trx
