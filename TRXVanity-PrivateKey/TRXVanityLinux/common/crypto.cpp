#include "crypto.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <vector>

namespace trx {
namespace {

constexpr char kBase58Alphabet[] =
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

constexpr std::uint32_t rotate_right(std::uint32_t value, unsigned count) noexcept {
    return (value >> count) | (value << (32U - count));
}

constexpr std::uint64_t rotate_left(std::uint64_t value, unsigned count) noexcept {
    return count == 0 ? value : (value << count) | (value >> (64U - count));
}

void sha256_transform(std::uint32_t state[8], const std::uint8_t block[64]) noexcept {
    static constexpr std::uint32_t constants[64] = {
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
    std::uint32_t words[64]{};
    for (unsigned i = 0; i < 16; ++i) {
        const auto offset = i * 4U;
        words[i] = (static_cast<std::uint32_t>(block[offset]) << 24U)
            | (static_cast<std::uint32_t>(block[offset + 1]) << 16U)
            | (static_cast<std::uint32_t>(block[offset + 2]) << 8U)
            | static_cast<std::uint32_t>(block[offset + 3]);
    }
    for (unsigned i = 16; i < 64; ++i) {
        const auto s0 = rotate_right(words[i - 15], 7)
            ^ rotate_right(words[i - 15], 18) ^ (words[i - 15] >> 3U);
        const auto s1 = rotate_right(words[i - 2], 17)
            ^ rotate_right(words[i - 2], 19) ^ (words[i - 2] >> 10U);
        words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }

    auto a = state[0];
    auto b = state[1];
    auto c = state[2];
    auto d = state[3];
    auto e = state[4];
    auto f = state[5];
    auto g = state[6];
    auto h = state[7];
    for (unsigned i = 0; i < 64; ++i) {
        const auto sum1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
        const auto choice = (e & f) ^ ((~e) & g);
        const auto temporary1 = h + sum1 + choice + constants[i] + words[i];
        const auto sum0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
        const auto majority = (a & b) ^ (a & c) ^ (b & c);
        const auto temporary2 = sum0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temporary1;
        d = c;
        c = b;
        b = a;
        a = temporary1 + temporary2;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
    secure_zero(words, sizeof(words));
}

void keccak_permute(std::uint64_t state[25]) noexcept {
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
        const auto c0 = state[0] ^ state[5] ^ state[10] ^ state[15] ^ state[20];
        const auto c1 = state[1] ^ state[6] ^ state[11] ^ state[16] ^ state[21];
        const auto c2 = state[2] ^ state[7] ^ state[12] ^ state[17] ^ state[22];
        const auto c3 = state[3] ^ state[8] ^ state[13] ^ state[18] ^ state[23];
        const auto c4 = state[4] ^ state[9] ^ state[14] ^ state[19] ^ state[24];
        const auto d0 = c4 ^ rotate_left(c1, 1);
        const auto d1 = c0 ^ rotate_left(c2, 1);
        const auto d2 = c1 ^ rotate_left(c3, 1);
        const auto d3 = c2 ^ rotate_left(c4, 1);
        const auto d4 = c3 ^ rotate_left(c0, 1);
        for (unsigned row = 0; row < 25; row += 5) {
            state[row] ^= d0;
            state[row + 1] ^= d1;
            state[row + 2] ^= d2;
            state[row + 3] ^= d3;
            state[row + 4] ^= d4;
        }
        auto carried = state[1];
        for (unsigned i = 0; i < 24; ++i) {
            const auto destination = pi_destinations[i];
            const auto displaced = state[destination];
            state[destination] = rotate_left(carried, rotation_offsets[i]);
            carried = displaced;
        }
        for (unsigned row = 0; row < 25; row += 5) {
            const auto a0 = state[row];
            const auto a1 = state[row + 1];
            const auto a2 = state[row + 2];
            const auto a3 = state[row + 3];
            const auto a4 = state[row + 4];
            state[row] = a0 ^ ((~a1) & a2);
            state[row + 1] = a1 ^ ((~a2) & a3);
            state[row + 2] = a2 ^ ((~a3) & a4);
            state[row + 3] = a3 ^ ((~a4) & a0);
            state[row + 4] = a4 ^ ((~a0) & a1);
        }
        state[0] ^= round_constants[round];
    }
}

int hex_digit(char value) noexcept {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

}  // namespace

void secure_zero(void* data, std::size_t size) noexcept {
    if (data == nullptr) return;
    auto* bytes = static_cast<volatile std::uint8_t*>(data);
    while (size-- != 0) *bytes++ = 0;
    std::atomic_signal_fence(std::memory_order_seq_cst);
}

std::array<std::uint8_t, 32> sha256(const std::uint8_t* data, std::size_t size) {
    std::uint32_t state[8] = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
    };
    const auto original_size = size;
    while (size >= 64) {
        sha256_transform(state, data);
        data += 64;
        size -= 64;
    }
    std::uint8_t final_blocks[128]{};
    if (size != 0) std::memcpy(final_blocks, data, size);
    final_blocks[size] = 0x80;
    const auto final_size = size < 56 ? 64U : 128U;
    const auto bit_length = static_cast<std::uint64_t>(original_size) * 8ULL;
    for (unsigned i = 0; i < 8; ++i) {
        final_blocks[final_size - 1U - i] =
            static_cast<std::uint8_t>(bit_length >> (i * 8U));
    }
    sha256_transform(state, final_blocks);
    if (final_size == 128) sha256_transform(state, final_blocks + 64);

    std::array<std::uint8_t, 32> output{};
    for (unsigned i = 0; i < 8; ++i) {
        output[i * 4] = static_cast<std::uint8_t>(state[i] >> 24U);
        output[i * 4 + 1] = static_cast<std::uint8_t>(state[i] >> 16U);
        output[i * 4 + 2] = static_cast<std::uint8_t>(state[i] >> 8U);
        output[i * 4 + 3] = static_cast<std::uint8_t>(state[i]);
    }
    secure_zero(state, sizeof(state));
    secure_zero(final_blocks, sizeof(final_blocks));
    return output;
}

std::array<std::uint8_t, 32> keccak256(const std::uint8_t* data, std::size_t size) {
    constexpr std::size_t rate = 136;
    constexpr std::size_t rate_lanes = rate / sizeof(std::uint64_t);
    std::uint64_t state[25]{};
    std::size_t cursor = 0;
    while (size - cursor >= rate) {
        for (std::size_t lane = 0; lane < rate_lanes; ++lane) {
            std::uint64_t word = 0;
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
    for (std::size_t i = whole_lanes * sizeof(std::uint64_t); i < remaining; ++i) {
        tail |= static_cast<std::uint64_t>(data[cursor + i])
            << ((i % sizeof(std::uint64_t)) * 8U);
    }
    state[whole_lanes] ^= tail;
    state[remaining / 8] ^= 0x01ULL << ((remaining % 8) * 8U);
    state[rate_lanes - 1] ^= 0x8000000000000000ULL;
    keccak_permute(state);
    std::array<std::uint8_t, 32> output{};
    std::memcpy(output.data(), state, output.size());
    secure_zero(state, sizeof(state));
    return output;
}

std::string base58_encode(const std::uint8_t* data, std::size_t size) {
    if (data == nullptr || size == 0) return {};
    std::size_t zero_count = 0;
    while (zero_count < size && data[zero_count] == 0) ++zero_count;
    const auto significant_size = size - zero_count;
    const auto capacity = significant_size * 138 / 100 + 1;
    std::vector<std::uint8_t> digits(capacity, 0);
    std::size_t encoded_length = 0;
    for (std::size_t index = zero_count; index < size; ++index) {
        unsigned carry = data[index];
        std::size_t visited = 0;
        auto digit = digits.rbegin();
        while ((carry != 0 || visited < encoded_length) && digit != digits.rend()) {
            carry += 256U * *digit;
            *digit = static_cast<std::uint8_t>(carry % 58U);
            carry /= 58U;
            ++digit;
            ++visited;
        }
        encoded_length = visited;
    }
    auto first = digits.end() - static_cast<std::ptrdiff_t>(encoded_length);
    while (first != digits.end() && *first == 0) ++first;
    std::string output(zero_count, kBase58Alphabet[0]);
    while (first != digits.end()) output.push_back(kBase58Alphabet[*first++]);
    return output;
}

bool tron_address_from_public_key(
    const PublicKey& public_key,
    std::string& address,
    std::array<std::uint8_t, 32>& public_hash,
    std::string& error) {
    if (public_key[0] != 0x04) {
        error = "The public key must use 65-byte uncompressed secp256k1 format.";
        return false;
    }
    public_hash = keccak256(public_key.data() + 1, 64);
    std::array<std::uint8_t, 25> raw{};
    raw[0] = 0x41;
    std::memcpy(raw.data() + 1, public_hash.data() + 12, 20);
    const auto first = sha256(raw.data(), 21);
    const auto second = sha256(first.data(), first.size());
    std::memcpy(raw.data() + 21, second.data(), 4);
    address = base58_encode(raw.data(), raw.size());
    return true;
}

std::string hex_upper(const std::uint8_t* data, std::size_t size) {
    static constexpr char digits[] = "0123456789ABCDEF";
    std::string output(size * 2, '\0');
    for (std::size_t i = 0; i < size; ++i) {
        output[i * 2] = digits[data[i] >> 4U];
        output[i * 2 + 1] = digits[data[i] & 0x0fU];
    }
    return output;
}

bool parse_hex_exact(
    std::string_view input,
    std::uint8_t* output,
    std::size_t output_size,
    std::string& error) {
    if (output == nullptr || input.size() != output_size * 2) {
        error = "Unexpected hexadecimal field length.";
        return false;
    }
    for (std::size_t i = 0; i < output_size; ++i) {
        const auto high = hex_digit(input[i * 2]);
        const auto low = hex_digit(input[i * 2 + 1]);
        if (high < 0 || low < 0) {
            secure_zero(output, output_size);
            error = "A hexadecimal field contains an invalid character.";
            return false;
        }
        output[i] = static_cast<std::uint8_t>((high << 4) | low);
    }
    return true;
}

bool matches_suffix(const std::string& address, const std::string& suffix) {
    return !suffix.empty() && suffix.size() <= address.size()
        && std::memcmp(
            address.data() + address.size() - suffix.size(),
            suffix.data(),
            suffix.size()) == 0;
}

bool encoding_self_test(std::string& error) {
    const auto empty_hash = keccak256(nullptr, 0);
    if (hex_upper(empty_hash.data(), empty_hash.size())
        != "C5D2460186F7233C927E7DB2DCC703C0E500B653CA82273B7BFAD8045D85A470") {
        error = "Keccak-256 empty-input vector failed.";
        return false;
    }
    static constexpr std::uint8_t abc[] = {'a', 'b', 'c'};
    const auto abc_keccak = keccak256(abc, sizeof(abc));
    if (hex_upper(abc_keccak.data(), abc_keccak.size())
        != "4E03657AEA45A94FC7D47BA826C8D667C0D1E6E33A64A036EC44F58FA12D6C45") {
        error = "Keccak-256 abc vector failed.";
        return false;
    }
    const auto abc_sha = sha256(abc, sizeof(abc));
    if (hex_upper(abc_sha.data(), abc_sha.size())
        != "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD") {
        error = "SHA-256 abc vector failed.";
        return false;
    }
    const std::array<std::uint8_t, 4> leading_zero{{0, 0, 0, 1}};
    if (base58_encode(leading_zero.data(), leading_zero.size()) != "1112") {
        error = "Base58 leading-zero vector failed.";
        return false;
    }
    const auto reference_base58 = [](const std::uint8_t* data, std::size_t size) {
        if (data == nullptr || size == 0) return std::string{};
        std::size_t zero_count = 0;
        while (zero_count < size && data[zero_count] == 0) ++zero_count;
        std::vector<std::uint8_t> input(data, data + size);
        std::string reversed;
        std::size_t start = zero_count;
        while (start < input.size()) {
            unsigned remainder = 0;
            for (std::size_t index = start; index < input.size(); ++index) {
                const unsigned accumulator = remainder * 256U + input[index];
                input[index] = static_cast<std::uint8_t>(accumulator / 58U);
                remainder = accumulator % 58U;
            }
            reversed.push_back(kBase58Alphabet[remainder]);
            while (start < input.size() && input[start] == 0) ++start;
        }
        reversed.append(zero_count, kBase58Alphabet[0]);
        std::reverse(reversed.begin(), reversed.end());
        return reversed;
    };
    std::array<std::uint8_t, 64> random_bytes{};
    std::uint32_t random_state = 0x9e3779b9U;
    for (std::size_t test_size = 1; test_size <= random_bytes.size(); ++test_size) {
        for (std::size_t index = 0; index < test_size; ++index) {
            random_state ^= random_state << 13U;
            random_state ^= random_state >> 17U;
            random_state ^= random_state << 5U;
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
    Scalar parsed{};
    if (!parse_hex_exact(std::string(64, 'A'), parsed.data(), parsed.size(), error)
        || hex_upper(parsed.data(), parsed.size()) != std::string(64, 'A')) {
        error = "Hexadecimal round-trip vector failed.";
        return false;
    }
    secure_zero(parsed.data(), parsed.size());
    error.clear();
    return true;
}

}  // namespace trx
