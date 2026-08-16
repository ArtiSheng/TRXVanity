#include "openssl_pbkdf2.hpp"

#include <openssl/crypto.h>
#include <openssl/evp.h>

#include <atomic>
#include <limits>
#include <mutex>

namespace trx {
namespace {

std::atomic<bool> g_initialized{false};
std::mutex g_initialize_mutex;

}  // namespace

bool openssl_pbkdf2_initialize(
    const std::filesystem::path& executable_directory,
    std::string& error) {
    (void)executable_directory;
    std::lock_guard<std::mutex> lock(g_initialize_mutex);
    if (g_initialized.load(std::memory_order_acquire)) {
        error.clear();
        return true;
    }

    // Ubuntu 22.04 supplies OpenSSL 3 through libcrypto. Link to that audited
    // system library instead of loading an architecture-specific DLL beside
    // the executable. The mnemonic self-test immediately following this call
    // verifies the complete PBKDF2-HMAC-SHA512 path against its reference
    // vectors before any search is accepted.
    if (OPENSSL_init_crypto(
            OPENSSL_INIT_LOAD_CRYPTO_STRINGS | OPENSSL_INIT_ADD_ALL_DIGESTS,
            nullptr) != 1
        || EVP_sha512() == nullptr) {
        error = "Unable to initialize the OpenSSL 3 CPU PBKDF2 accelerator.";
        return false;
    }

    g_initialized.store(true, std::memory_order_release);
    error.clear();
    return true;
}

bool openssl_pbkdf2_sha512_2048(
    const std::uint8_t* password,
    std::size_t password_size,
    const std::uint8_t* salt,
    std::size_t salt_size,
    std::uint8_t output[64],
    std::string& error) noexcept {
    if (!g_initialized.load(std::memory_order_acquire)) {
        error = "The OpenSSL CPU PBKDF2 accelerator is not initialized.";
        return false;
    }
    if (password == nullptr || salt == nullptr || output == nullptr
        || password_size > static_cast<std::size_t>(std::numeric_limits<int>::max())
        || salt_size > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        error = "The OpenSSL PBKDF2 input is invalid.";
        return false;
    }

    if (PKCS5_PBKDF2_HMAC(
            reinterpret_cast<const char*>(password),
            static_cast<int>(password_size),
            salt,
            static_cast<int>(salt_size),
            2048,
            EVP_sha512(),
            64,
            output) != 1) {
        error = "OpenSSL PBKDF2-HMAC-SHA512 failed.";
        return false;
    }
    error.clear();
    return true;
}

void openssl_pbkdf2_shutdown() noexcept {
    // OPENSSL_cleanup() is process-global and prevents later reinitialization.
    // The executable links libcrypto for hashing and secure randomness too, so
    // leave OpenSSL's normal process-lifetime cleanup in control.
    g_initialized.store(false, std::memory_order_release);
}

}  // namespace trx
