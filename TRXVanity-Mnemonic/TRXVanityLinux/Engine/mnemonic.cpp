#include "mnemonic.hpp"

#include "openssl_pbkdf2.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <fstream>
#include <limits>

namespace trx {
namespace {

constexpr std::array<std::uint64_t, 80> kSha512RoundConstants{{
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL,
    0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL,
    0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL,
    0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL,
    0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL,
    0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL,
    0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL,
    0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL,
    0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL,
    0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL,
    0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL,
    0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL, 0xd69906245565a910ULL,
    0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL,
    0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL,
    0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL,
    0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL,
    0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL,
    0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL,
    0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL,
    0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL,
    0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL,
}};

inline std::uint64_t rotate_right(std::uint64_t value, unsigned amount) {
    return (value >> amount) | (value << (64U - amount));
}

inline std::uint64_t load_be64(const std::uint8_t* input) {
    std::uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i) {
        value = (value << 8) | input[i];
    }
    return value;
}

inline void store_be64(std::uint8_t* output, std::uint64_t value) {
    for (int i = 7; i >= 0; --i) {
        output[i] = static_cast<std::uint8_t>(value);
        value >>= 8;
    }
}

class Sha512 {
public:
    Sha512()
        : state_{{
              0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
              0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
              0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
              0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL,
          }} {}

    void update(const std::uint8_t* data, std::size_t size) {
        if (size == 0) {
            return;
        }
        total_size_ += size;
        while (size != 0) {
            const auto available = buffer_.size() - buffered_;
            const auto copied = std::min(size, available);
            std::memcpy(buffer_.data() + buffered_, data, copied);
            buffered_ += copied;
            data += copied;
            size -= copied;
            if (buffered_ == buffer_.size()) {
                transform(buffer_.data());
                buffered_ = 0;
            }
        }
    }

    void finish(std::uint8_t output[64]) {
        const auto bit_length = static_cast<std::uint64_t>(total_size_) * 8ULL;
        buffer_[buffered_++] = 0x80;
        if (buffered_ > 112) {
            std::fill(buffer_.begin() + buffered_, buffer_.end(), 0);
            transform(buffer_.data());
            buffered_ = 0;
        }
        std::fill(buffer_.begin() + buffered_, buffer_.begin() + 120, 0);
        store_be64(buffer_.data() + 120, bit_length);
        transform(buffer_.data());
        for (std::size_t i = 0; i < state_.size(); ++i) {
            store_be64(output + i * 8, state_[i]);
        }
        secure_zero(buffer_.data(), buffer_.size());
        secure_zero(state_.data(), state_.size() * sizeof(state_[0]));
        buffered_ = 0;
        total_size_ = 0;
    }

private:
    void transform(const std::uint8_t block[128]) {
        std::array<std::uint64_t, 80> schedule{};
        for (std::size_t i = 0; i < 16; ++i) {
            schedule[i] = load_be64(block + i * 8);
        }
        for (std::size_t i = 16; i < schedule.size(); ++i) {
            const auto s0 = rotate_right(schedule[i - 15], 1)
                ^ rotate_right(schedule[i - 15], 8)
                ^ (schedule[i - 15] >> 7);
            const auto s1 = rotate_right(schedule[i - 2], 19)
                ^ rotate_right(schedule[i - 2], 61)
                ^ (schedule[i - 2] >> 6);
            schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1;
        }

        auto a = state_[0];
        auto b = state_[1];
        auto c = state_[2];
        auto d = state_[3];
        auto e = state_[4];
        auto f = state_[5];
        auto g = state_[6];
        auto h = state_[7];
        for (std::size_t i = 0; i < schedule.size(); ++i) {
            const auto sigma1 = rotate_right(e, 14)
                ^ rotate_right(e, 18) ^ rotate_right(e, 41);
            const auto choose = (e & f) ^ ((~e) & g);
            const auto temporary1 = h + sigma1 + choose
                + kSha512RoundConstants[i] + schedule[i];
            const auto sigma0 = rotate_right(a, 28)
                ^ rotate_right(a, 34) ^ rotate_right(a, 39);
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
        state_[0] += a;
        state_[1] += b;
        state_[2] += c;
        state_[3] += d;
        state_[4] += e;
        state_[5] += f;
        state_[6] += g;
        state_[7] += h;
        secure_zero(schedule.data(), schedule.size() * sizeof(schedule[0]));
    }

    std::array<std::uint64_t, 8> state_;
    std::array<std::uint8_t, 128> buffer_{};
    std::size_t buffered_ = 0;
    std::uint64_t total_size_ = 0;
};

void sha512(
    const std::uint8_t* data,
    std::size_t size,
    std::uint8_t output[64]) {
    Sha512 hash;
    hash.update(data, size);
    hash.finish(output);
}

void hmac_sha512(
    const std::uint8_t* key,
    std::size_t key_size,
    const std::uint8_t* data,
    std::size_t data_size,
    std::uint8_t output[64]) {
    std::array<std::uint8_t, 128> key_block{};
    if (key_size > key_block.size()) {
        sha512(key, key_size, key_block.data());
    } else if (key_size != 0) {
        std::memcpy(key_block.data(), key, key_size);
    }

    std::array<std::uint8_t, 128> inner_pad{};
    std::array<std::uint8_t, 128> outer_pad{};
    for (std::size_t i = 0; i < key_block.size(); ++i) {
        inner_pad[i] = key_block[i] ^ 0x36;
        outer_pad[i] = key_block[i] ^ 0x5c;
    }
    std::array<std::uint8_t, 64> inner_hash{};
    Sha512 inner;
    inner.update(inner_pad.data(), inner_pad.size());
    inner.update(data, data_size);
    inner.finish(inner_hash.data());

    Sha512 outer;
    outer.update(outer_pad.data(), outer_pad.size());
    outer.update(inner_hash.data(), inner_hash.size());
    outer.finish(output);

    secure_zero(key_block.data(), key_block.size());
    secure_zero(inner_pad.data(), inner_pad.size());
    secure_zero(outer_pad.data(), outer_pad.size());
    secure_zero(inner_hash.data(), inner_hash.size());
}

void pbkdf2_hmac_sha512_2048(
    const std::uint8_t* password,
    std::size_t password_size,
    const std::uint8_t* salt,
    std::size_t salt_size,
    std::uint8_t output[64]) {
    std::array<std::uint8_t, 256> first_input{};
    std::memcpy(first_input.data(), salt, salt_size);
    first_input[salt_size + 3] = 1;

    std::array<std::uint8_t, 64> current{};
    hmac_sha512(
        password,
        password_size,
        first_input.data(),
        salt_size + 4,
        current.data());
    std::memcpy(output, current.data(), current.size());
    for (unsigned iteration = 1; iteration < 2048; ++iteration) {
        std::array<std::uint8_t, 64> next{};
        hmac_sha512(
            password,
            password_size,
            current.data(),
            current.size(),
            next.data());
        for (std::size_t i = 0; i < next.size(); ++i) {
            output[i] ^= next[i];
        }
        current = next;
        secure_zero(next.data(), next.size());
    }
    secure_zero(first_input.data(), first_input.size());
    secure_zero(current.data(), current.size());
}

bool master_from_mnemonic(
    const std::string& mnemonic,
    MasterKey& master,
    std::string& error) {
    static constexpr std::uint8_t salt[] = {
        'm', 'n', 'e', 'm', 'o', 'n', 'i', 'c',
    };
    std::array<std::uint8_t, 64> seed{};
    if (!openssl_pbkdf2_sha512_2048(
        reinterpret_cast<const std::uint8_t*>(mnemonic.data()),
        mnemonic.size(),
        salt,
        sizeof(salt),
        seed.data(),
        error)) {
        secure_zero(seed.data(), seed.size());
        return false;
    }
    static constexpr std::uint8_t bitcoin_seed[] = {
        'B', 'i', 't', 'c', 'o', 'i', 'n', ' ', 's', 'e', 'e', 'd',
    };
    hmac_sha512(
        bitcoin_seed,
        sizeof(bitcoin_seed),
        seed.data(),
        seed.size(),
        master.data());
    secure_zero(seed.data(), seed.size());
    error.clear();
    return true;
}

void reference_master_from_mnemonic(
    const std::string& mnemonic,
    MasterKey& master) {
    static constexpr std::uint8_t salt[] = {
        'm', 'n', 'e', 'm', 'o', 'n', 'i', 'c',
    };
    std::array<std::uint8_t, 64> seed{};
    pbkdf2_hmac_sha512_2048(
        reinterpret_cast<const std::uint8_t*>(mnemonic.data()),
        mnemonic.size(),
        salt,
        sizeof(salt),
        seed.data());
    static constexpr std::uint8_t bitcoin_seed[] = {
        'B', 'i', 't', 'c', 'o', 'i', 'n', ' ', 's', 'e', 'e', 'd',
    };
    hmac_sha512(
        bitcoin_seed,
        sizeof(bitcoin_seed),
        seed.data(),
        seed.size(),
        master.data());
    secure_zero(seed.data(), seed.size());
}

struct ExtendedPrivateKey {
    PrivateKey key{};
    std::array<std::uint8_t, 32> chain_code{};
};

bool derive_child(
    const ExtendedPrivateKey& parent,
    std::uint32_t child_number,
    ExtendedPrivateKey& child,
    std::string& error) {
    std::array<std::uint8_t, 37> data{};
    if ((child_number & 0x80000000U) != 0) {
        data[0] = 0;
        std::memcpy(data.data() + 1, parent.key.data(), parent.key.size());
    } else {
        CompressedPublicKey public_key_bytes{};
        if (!compressed_public_key(parent.key, public_key_bytes, error)) {
            return false;
        }
        std::memcpy(data.data(), public_key_bytes.data(), public_key_bytes.size());
        secure_zero(public_key_bytes.data(), public_key_bytes.size());
    }
    data[33] = static_cast<std::uint8_t>(child_number >> 24);
    data[34] = static_cast<std::uint8_t>(child_number >> 16);
    data[35] = static_cast<std::uint8_t>(child_number >> 8);
    data[36] = static_cast<std::uint8_t>(child_number);

    MasterKey digest{};
    hmac_sha512(
        parent.chain_code.data(),
        parent.chain_code.size(),
        data.data(),
        data.size(),
        digest.data());
    PrivateKey tweak{};
    std::memcpy(tweak.data(), digest.data(), tweak.size());
    if (!add_tweak(parent.key, tweak, child.key, error)) {
        secure_zero(data.data(), data.size());
        secure_zero(digest.data(), digest.size());
        secure_zero(tweak.data(), tweak.size());
        return false;
    }
    std::memcpy(
        child.chain_code.data(),
        digest.data() + 32,
        child.chain_code.size());
    secure_zero(data.data(), data.size());
    secure_zero(digest.data(), digest.size());
    secure_zero(tweak.data(), tweak.size());
    return true;
}

bool decode_hex(const char* text, std::uint8_t* output, std::size_t size) {
    const auto nibble = [](char value) -> int {
        if (value >= '0' && value <= '9') return value - '0';
        if (value >= 'a' && value <= 'f') return value - 'a' + 10;
        if (value >= 'A' && value <= 'F') return value - 'A' + 10;
        return -1;
    };
    for (std::size_t i = 0; i < size; ++i) {
        const int high = nibble(text[i * 2]);
        const int low = nibble(text[i * 2 + 1]);
        if (high < 0 || low < 0) return false;
        output[i] = static_cast<std::uint8_t>((high << 4) | low);
    }
    return text[size * 2] == '\0';
}

}  // namespace

bool load_bip39_english_words(
    const std::filesystem::path& path,
    std::vector<std::string>& words,
    std::string& error) {
    std::ifstream input(path);
    if (!input) {
        error = "BIP39 English word list is missing: " + path.string();
        return false;
    }
    std::vector<std::string> loaded;
    loaded.reserve(2048);
    std::string line;
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.empty() || line.size() > 8
            || !std::all_of(line.begin(), line.end(), [](unsigned char value) {
                   return value >= 'a' && value <= 'z';
               })) {
            error = "The BIP39 English word list is malformed.";
            return false;
        }
        loaded.push_back(line);
    }
    if (loaded.size() != 2048
        || !std::is_sorted(loaded.begin(), loaded.end())) {
        error = "The BIP39 English word list must contain 2048 sorted words.";
        return false;
    }
    words = std::move(loaded);
    return true;
}

Entropy128 entropy_at(
    const Entropy128& random_base,
    std::uint64_t candidate_index) noexcept {
    Entropy128 output{};
    auto high = load_be64(random_base.data());
    const auto low_base = load_be64(random_base.data() + 8);
    const auto low = low_base + candidate_index;
    if (low < low_base) {
        ++high;
    }
    store_be64(output.data(), high);
    store_be64(output.data() + 8, low);
    return output;
}

bool entropy_to_mnemonic(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    std::string& mnemonic,
    std::string& error) {
    if (words.size() != 2048) {
        error = "The BIP39 English dictionary is not loaded.";
        return false;
    }
    std::array<std::uint8_t, 32> checksum{};
    if (!sha256(entropy.data(), entropy.size(), checksum, error)) {
        return false;
    }

    mnemonic.clear();
    mnemonic.reserve(108);
    for (unsigned word = 0; word < 12; ++word) {
        unsigned index = 0;
        for (unsigned bit = 0; bit < 11; ++bit) {
            const unsigned source_bit = word * 11 + bit;
            unsigned value = 0;
            if (source_bit < 128) {
                value = (entropy[source_bit / 8]
                    >> (7 - source_bit % 8)) & 1U;
            } else {
                value = (checksum[0] >> (7 - (source_bit - 128))) & 1U;
            }
            index = (index << 1) | value;
        }
        if (word != 0) mnemonic.push_back(' ');
        mnemonic.append(words[index]);
    }
    secure_zero(checksum.data(), checksum.size());
    return true;
}

bool derive_tron_key_from_master(
    const std::uint8_t* master_key,
    PrivateKey& private_key,
    std::string& error) {
    if (master_key == nullptr) {
        error = "The BIP32 master key is missing.";
        return false;
    }
    ExtendedPrivateKey node{};
    std::memcpy(node.key.data(), master_key, node.key.size());
    std::memcpy(node.chain_code.data(), master_key + 32, node.chain_code.size());
    static constexpr std::uint32_t path[] = {
        0x8000002cU,
        0x800000c3U,
        0x80000000U,
        0U,
        0U,
    };
    for (const auto child_number : path) {
        ExtendedPrivateKey child{};
        if (!derive_child(node, child_number, child, error)) {
            secure_zero(&node, sizeof(node));
            secure_zero(&child, sizeof(child));
            return false;
        }
        secure_zero(&node, sizeof(node));
        node = child;
        secure_zero(&child, sizeof(child));
    }
    private_key = node.key;
    secure_zero(&node, sizeof(node));
    return true;
}

bool derive_tron_address_from_master(
    const std::uint8_t* master_key,
    std::string& address,
    std::string& error) {
    PrivateKey private_key{};
    if (!derive_tron_key_from_master(master_key, private_key, error)) {
        return false;
    }
    const bool result = tron_address(private_key, address, error);
    secure_zero(private_key.data(), private_key.size());
    return result;
}

bool derive_mnemonic_candidate(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    std::string& mnemonic,
    std::string& address,
    std::string& error) {
    if (!entropy_to_mnemonic(entropy, words, mnemonic, error)) {
        return false;
    }
    MasterKey master{};
    if (!master_from_mnemonic(mnemonic, master, error)) {
        return false;
    }
    const bool result = derive_tron_address_from_master(
        master.data(), address, error);
    secure_zero(master.data(), master.size());
    return result;
}

bool verify_cpu_mnemonic_candidate(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    const std::string& expected_mnemonic,
    const std::string& expected_address,
    std::string& error) {
    std::string mnemonic;
    if (!entropy_to_mnemonic(entropy, words, mnemonic, error)
        || mnemonic != expected_mnemonic) {
        if (error.empty()) {
            error = "The CPU worker mnemonic did not reproduce its entropy.";
        }
        if (!mnemonic.empty()) {
            secure_zero(mnemonic.data(), mnemonic.size());
        }
        return false;
    }
    MasterKey master{};
    reference_master_from_mnemonic(mnemonic, master);
    std::string address;
    const bool derived = derive_tron_address_from_master(
        master.data(), address, error);
    secure_zero(master.data(), master.size());
    if (!derived) {
        secure_zero(mnemonic.data(), mnemonic.size());
        return false;
    }
    if (address != expected_address) {
        secure_zero(mnemonic.data(), mnemonic.size());
        error = "The reference CPU path rejected the CPU worker address.";
        return false;
    }
    secure_zero(mnemonic.data(), mnemonic.size());
    return true;
}

bool verify_mnemonic_candidate(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    const std::uint8_t* gpu_master_key,
    const std::string& expected_address,
    std::string& mnemonic,
    std::string& error) {
    if (!entropy_to_mnemonic(entropy, words, mnemonic, error)) {
        return false;
    }
    MasterKey cpu_master{};
    reference_master_from_mnemonic(mnemonic, cpu_master);
    if (gpu_master_key == nullptr
        || std::memcmp(cpu_master.data(), gpu_master_key, cpu_master.size()) != 0) {
        secure_zero(cpu_master.data(), cpu_master.size());
        error = "GPU/CPU BIP39 master-key verification failed.";
        return false;
    }
    std::string verified_address;
    if (!derive_tron_address_from_master(
            cpu_master.data(), verified_address, error)) {
        secure_zero(cpu_master.data(), cpu_master.size());
        return false;
    }
    secure_zero(cpu_master.data(), cpu_master.size());
    if (verified_address != expected_address) {
        error = "The mnemonic did not reproduce the matched TRON address.";
        return false;
    }
    return true;
}

bool mnemonic_self_test(
    const std::vector<std::string>& words,
    std::string& error) {
    Entropy128 zero_entropy{};
    std::string mnemonic;
    if (!entropy_to_mnemonic(zero_entropy, words, mnemonic, error)) {
        return false;
    }
    const std::string expected_mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon "
        "abandon abandon abandon about";
    if (mnemonic != expected_mnemonic) {
        error = "BIP39 zero-entropy mnemonic vector failed.";
        return false;
    }

    static constexpr std::uint8_t salt[] = {
        'm', 'n', 'e', 'm', 'o', 'n', 'i', 'c',
    };
    std::array<std::uint8_t, 64> reference_seed{};
    std::array<std::uint8_t, 64> accelerated_seed{};
    pbkdf2_hmac_sha512_2048(
        reinterpret_cast<const std::uint8_t*>(mnemonic.data()),
        mnemonic.size(),
        salt,
        sizeof(salt),
        reference_seed.data());
    if (!openssl_pbkdf2_sha512_2048(
            reinterpret_cast<const std::uint8_t*>(mnemonic.data()),
            mnemonic.size(),
            salt,
            sizeof(salt),
            accelerated_seed.data(),
            error)
        || reference_seed != accelerated_seed) {
        secure_zero(reference_seed.data(), reference_seed.size());
        secure_zero(accelerated_seed.data(), accelerated_seed.size());
        if (error.empty()) {
            error = "OpenSSL/reference BIP39 PBKDF2 verification failed.";
        }
        return false;
    }
    secure_zero(reference_seed.data(), reference_seed.size());
    secure_zero(accelerated_seed.data(), accelerated_seed.size());

    MasterKey master{};
    if (!master_from_mnemonic(mnemonic, master, error)) {
        return false;
    }
    PrivateKey private_key{};
    if (!derive_tron_key_from_master(master.data(), private_key, error)) {
        secure_zero(master.data(), master.size());
        return false;
    }
    PrivateKey expected_private{};
    if (!decode_hex(
            "B5A4CEA271FF424D7C31DC12A3E43E401DF7A40D7412A15750F3F0B6B5449A28",
            expected_private.data(),
            expected_private.size())
        || private_key != expected_private) {
        secure_zero(master.data(), master.size());
        secure_zero(private_key.data(), private_key.size());
        secure_zero(expected_private.data(), expected_private.size());
        error = "BIP32 TRON derivation vector failed.";
        return false;
    }
    std::string address;
    if (!tron_address(private_key, address, error)) {
        secure_zero(master.data(), master.size());
        secure_zero(private_key.data(), private_key.size());
        secure_zero(expected_private.data(), expected_private.size());
        return false;
    }
    secure_zero(master.data(), master.size());
    secure_zero(private_key.data(), private_key.size());
    secure_zero(expected_private.data(), expected_private.size());
    if (address != "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH") {
        error = "TRON mnemonic address vector failed: " + address;
        return false;
    }
    std::string worker_mnemonic;
    std::string worker_address;
    if (!derive_mnemonic_candidate(
            zero_entropy, words, worker_mnemonic, worker_address, error)
        || worker_mnemonic != expected_mnemonic
        || worker_address != address
        || !verify_cpu_mnemonic_candidate(
            zero_entropy, words, worker_mnemonic, worker_address, error)) {
        if (!worker_mnemonic.empty()) {
            secure_zero(worker_mnemonic.data(), worker_mnemonic.size());
        }
        if (error.empty()) {
            error = "The accelerated CPU mnemonic worker vector failed.";
        }
        return false;
    }
    secure_zero(worker_mnemonic.data(), worker_mnemonic.size());
    return true;
}

}  // namespace trx
