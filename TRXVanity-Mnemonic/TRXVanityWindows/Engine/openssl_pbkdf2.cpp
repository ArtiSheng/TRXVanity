#include "openssl_pbkdf2.hpp"

#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>

#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <mutex>
#include <vector>

namespace trx {
namespace {

struct evp_md_st;
using EvpMd = evp_md_st;
using EvpSha512 = const EvpMd* (__cdecl*)();
using Pbkdf2Hmac = int (__cdecl*)(
    const char*,
    int,
    const unsigned char*,
    int,
    int,
    const EvpMd*,
    int,
    unsigned char*);
using OpenSslCleanup = void (__cdecl*)();

HMODULE g_crypto_module = nullptr;
EvpSha512 g_evp_sha512 = nullptr;
Pbkdf2Hmac g_pbkdf2_hmac = nullptr;
OpenSslCleanup g_openssl_cleanup = nullptr;
std::mutex g_loader_mutex;

bool verify_library_integrity(
    const std::filesystem::path& library,
    std::string& error) {
    static constexpr std::array<std::uint8_t, 32> expected{{
        0x03, 0x30, 0xb5, 0xf5, 0x58, 0x99, 0x6f, 0x29,
        0x7d, 0x68, 0x7e, 0x1a, 0x2b, 0x2f, 0xcc, 0x2c,
        0xac, 0xf8, 0x83, 0xb1, 0x6b, 0xae, 0xf7, 0x4a,
        0xae, 0xf3, 0x52, 0x85, 0xd7, 0xc1, 0x23, 0x1c,
    }};
    std::ifstream input(library, std::ios::binary | std::ios::ate);
    if (!input) {
        error = "Unable to open the bundled OpenSSL CPU accelerator.";
        return false;
    }
    const auto length = input.tellg();
    if (length <= 0
        || static_cast<std::uint64_t>(length) > 64ULL * 1024ULL * 1024ULL) {
        error = "The bundled OpenSSL CPU accelerator has an invalid size.";
        return false;
    }
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    input.seekg(0, std::ios::beg);
    input.read(
        reinterpret_cast<char*>(bytes.data()),
        static_cast<std::streamsize>(bytes.size()));
    if (!input) {
        SecureZeroMemory(bytes.data(), bytes.size());
        error = "Unable to read the bundled OpenSSL CPU accelerator.";
        return false;
    }
    std::array<std::uint8_t, 32> digest{};
    const auto status = BCryptHash(
        BCRYPT_SHA256_ALG_HANDLE,
        nullptr,
        0,
        bytes.data(),
        static_cast<ULONG>(bytes.size()),
        digest.data(),
        static_cast<ULONG>(digest.size()));
    SecureZeroMemory(bytes.data(), bytes.size());
    const bool valid = status == 0
        && std::memcmp(digest.data(), expected.data(), expected.size()) == 0;
    SecureZeroMemory(digest.data(), digest.size());
    if (!valid) {
        error = "The bundled OpenSSL CPU accelerator failed its SHA-256 integrity check.";
    }
    return valid;
}

void reset_symbols() noexcept {
    g_evp_sha512 = nullptr;
    g_pbkdf2_hmac = nullptr;
    g_openssl_cleanup = nullptr;
}

}  // namespace

bool openssl_pbkdf2_initialize(
    const std::wstring& executable_directory,
    std::string& error) {
    std::lock_guard<std::mutex> lock(g_loader_mutex);
    if (g_crypto_module != nullptr) {
        return true;
    }

    const auto library = std::filesystem::path(executable_directory)
        / L"libcrypto-3-x64.dll";
    if (!verify_library_integrity(library, error)) {
        return false;
    }
    g_crypto_module = LoadLibraryExW(
        library.c_str(),
        nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (g_crypto_module == nullptr) {
        error = "Unable to load the bundled OpenSSL CPU accelerator (Windows error "
            + std::to_string(GetLastError()) + ").";
        return false;
    }

    g_evp_sha512 = reinterpret_cast<EvpSha512>(
        GetProcAddress(g_crypto_module, "EVP_sha512"));
    g_pbkdf2_hmac = reinterpret_cast<Pbkdf2Hmac>(
        GetProcAddress(g_crypto_module, "PKCS5_PBKDF2_HMAC"));
    g_openssl_cleanup = reinterpret_cast<OpenSslCleanup>(
        GetProcAddress(g_crypto_module, "OPENSSL_cleanup"));
    if (g_evp_sha512 == nullptr || g_pbkdf2_hmac == nullptr) {
        error = "The bundled OpenSSL library is missing its PBKDF2-SHA512 API.";
        reset_symbols();
        FreeLibrary(g_crypto_module);
        g_crypto_module = nullptr;
        return false;
    }

    return true;
}

bool openssl_pbkdf2_sha512_2048(
    const std::uint8_t* password,
    std::size_t password_size,
    const std::uint8_t* salt,
    std::size_t salt_size,
    std::uint8_t output[64],
    std::string& error) noexcept {
    if (g_pbkdf2_hmac == nullptr || g_evp_sha512 == nullptr) {
        error = "The OpenSSL CPU PBKDF2 accelerator is not initialized.";
        return false;
    }
    if (password == nullptr || salt == nullptr || output == nullptr
        || password_size > static_cast<std::size_t>(std::numeric_limits<int>::max())
        || salt_size > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        error = "The OpenSSL PBKDF2 input is invalid.";
        return false;
    }
    const auto* digest = g_evp_sha512();
    if (digest == nullptr
        || g_pbkdf2_hmac(
            reinterpret_cast<const char*>(password),
            static_cast<int>(password_size),
            salt,
            static_cast<int>(salt_size),
            2048,
            digest,
            64,
            output) != 1) {
        error = "OpenSSL PBKDF2-HMAC-SHA512 failed.";
        return false;
    }
    error.clear();
    return true;
}

void openssl_pbkdf2_shutdown() noexcept {
    std::lock_guard<std::mutex> lock(g_loader_mutex);
    if (g_openssl_cleanup != nullptr) {
        g_openssl_cleanup();
    }
    reset_symbols();
    if (g_crypto_module != nullptr) {
        FreeLibrary(g_crypto_module);
        g_crypto_module = nullptr;
    }
}

}  // namespace trx
