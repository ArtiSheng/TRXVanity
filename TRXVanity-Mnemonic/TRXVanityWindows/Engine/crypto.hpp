#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace trx {

using PrivateKey = std::array<std::uint8_t, 32>;
using PublicKey = std::array<std::uint8_t, 65>;
using CompressedPublicKey = std::array<std::uint8_t, 33>;

void secure_zero(void* data, std::size_t size) noexcept;

bool public_key(const PrivateKey& private_key, PublicKey& output, std::string& error);
bool compressed_public_key(
    const PrivateKey& private_key,
    CompressedPublicKey& output,
    std::string& error);
bool add_tweak(
    const PrivateKey& base,
    const PrivateKey& tweak,
    PrivateKey& output,
    std::string& error);

std::array<std::uint8_t, 32> keccak256(const std::uint8_t* data, std::size_t size);
bool sha256(
    const std::uint8_t* data,
    std::size_t size,
    std::array<std::uint8_t, 32>& output,
    std::string& error);

std::string base58_encode(const std::uint8_t* data, std::size_t size);
bool tron_address(
    const PrivateKey& private_key,
    std::string& address,
    std::string& error);
bool tron_address_from_public_key(
    const PublicKey& public_key,
    std::string& address,
    std::array<std::uint8_t, 32>& public_hash,
    std::string& error);

std::string hex_upper(const std::uint8_t* data, std::size_t size);
bool matches(const std::string& address, const std::string& prefix, const std::string& suffix);
bool crypto_self_test(std::string& error);

}  // namespace trx
