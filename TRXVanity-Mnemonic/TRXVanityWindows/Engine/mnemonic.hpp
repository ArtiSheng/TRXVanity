#pragma once

#include "crypto.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace trx {

constexpr const char* kTronDerivationPath = "m/44'/195'/0'/0/0";
using Entropy128 = std::array<std::uint8_t, 16>;
using MasterKey = std::array<std::uint8_t, 64>;

bool load_bip39_english_words(
    const std::filesystem::path& path,
    std::vector<std::string>& words,
    std::string& error);

Entropy128 entropy_at(
    const Entropy128& random_base,
    std::uint64_t candidate_index) noexcept;

bool entropy_to_mnemonic(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    std::string& mnemonic,
    std::string& error);

bool derive_tron_key_from_master(
    const std::uint8_t* master_key,
    PrivateKey& private_key,
    std::string& error);

bool derive_tron_address_from_master(
    const std::uint8_t* master_key,
    std::string& address,
    std::string& error);

bool derive_mnemonic_candidate(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    std::string& mnemonic,
    std::string& address,
    std::string& error);

bool verify_cpu_mnemonic_candidate(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    const std::string& expected_mnemonic,
    const std::string& expected_address,
    std::string& error);

bool verify_mnemonic_candidate(
    const Entropy128& entropy,
    const std::vector<std::string>& words,
    const std::uint8_t* gpu_master_key,
    const std::string& expected_address,
    std::string& mnemonic,
    std::string& error);

bool mnemonic_self_test(
    const std::vector<std::string>& words,
    std::string& error);

}  // namespace trx
