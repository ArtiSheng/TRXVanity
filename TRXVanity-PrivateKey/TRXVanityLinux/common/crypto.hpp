#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace trx {

using Scalar = std::array<std::uint8_t, 32>;
using PublicKey = std::array<std::uint8_t, 65>;

void secure_zero(void* data, std::size_t size) noexcept;

std::array<std::uint8_t, 32> keccak256(
    const std::uint8_t* data,
    std::size_t size);
std::array<std::uint8_t, 32> sha256(
    const std::uint8_t* data,
    std::size_t size);

std::string base58_encode(const std::uint8_t* data, std::size_t size);
bool tron_address_from_public_key(
    const PublicKey& public_key,
    std::string& address,
    std::array<std::uint8_t, 32>& public_hash,
    std::string& error);

std::string hex_upper(const std::uint8_t* data, std::size_t size);
bool parse_hex_exact(
    std::string_view input,
    std::uint8_t* output,
    std::size_t output_size,
    std::string& error);
bool matches_suffix(const std::string& address, const std::string& suffix);
bool encoding_self_test(std::string& error);

}  // namespace trx
