#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>

namespace trx {

bool openssl_pbkdf2_initialize(
    const std::filesystem::path& executable_directory,
    std::string& error);

bool openssl_pbkdf2_sha512_2048(
    const std::uint8_t* password,
    std::size_t password_size,
    const std::uint8_t* salt,
    std::size_t salt_size,
    std::uint8_t output[64],
    std::string& error) noexcept;

void openssl_pbkdf2_shutdown() noexcept;

}  // namespace trx
