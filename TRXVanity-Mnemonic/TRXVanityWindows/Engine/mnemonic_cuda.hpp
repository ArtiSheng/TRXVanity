#pragma once

#include "mnemonic.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>

namespace trx {

struct CudaMnemonicDeviceInfo {
    std::string name;
    int compute_major = 0;
    int compute_minor = 0;
    int multiprocessor_count = 0;
    std::size_t free_memory = 0;
    std::size_t total_memory = 0;
};

bool cuda_mnemonic_query_device(
    CudaMnemonicDeviceInfo& info,
    std::string& error);

bool cuda_mnemonic_initialize(
    const std::filesystem::path& wordlist_path,
    std::size_t batch_capacity,
    unsigned requested_master_block_size,
    unsigned requested_address_block_size,
    std::string& device_name,
    std::string& error);

unsigned cuda_mnemonic_master_block_size() noexcept;
unsigned cuda_mnemonic_address_block_size() noexcept;
unsigned cuda_mnemonic_address_candidates_per_thread() noexcept;

bool cuda_mnemonic_derive_batch(
    const Entropy128& random_base,
    std::uint64_t first_candidate,
    std::uint32_t candidate_count,
    std::uint8_t*& pinned_master_keys,
    double& gpu_seconds,
    std::string& error);

// Launches the complete BIP39 -> BIP32 -> secp256k1 -> TRON address
// pipeline. Only a winning index and its 64-byte BIP32 master key cross
// the PCIe boundary; ordinary candidate keys remain on the GPU.
bool cuda_mnemonic_launch_search_batch(
    unsigned slot,
    const Entropy128& random_base,
    std::uint64_t first_candidate,
    std::uint32_t candidate_count,
    std::uint64_t suffix_modulus,
    std::uint64_t suffix_remainder,
    std::string& error);

bool cuda_mnemonic_wait_search_batch(
    unsigned slot,
    std::uint32_t& winner_index,
    std::uint8_t*& pinned_winner_master,
    double& gpu_seconds,
    std::string& error);

void cuda_mnemonic_clear_slot(
    unsigned slot,
    std::size_t candidate_count) noexcept;
void cuda_mnemonic_clear_host(std::size_t candidate_count) noexcept;
void cuda_mnemonic_shutdown() noexcept;

}  // namespace trx
