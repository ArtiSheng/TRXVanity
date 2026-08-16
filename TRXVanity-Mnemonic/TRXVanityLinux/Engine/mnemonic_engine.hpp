#pragma once

#include "match_plan.hpp"
#include "mnemonic.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>

namespace trx {

using ProtocolEmitter = std::function<void(const std::string&)>;

enum class MnemonicComputeProfile {
    rtx_5070,
    rtx_4090,
    smart,
};

bool parse_mnemonic_compute_profile(
    const std::string& value,
    MnemonicComputeProfile& profile) noexcept;
const char* mnemonic_compute_profile_id(
    MnemonicComputeProfile profile) noexcept;

struct MnemonicEngineOptions {
    MnemonicComputeProfile profile = MnemonicComputeProfile::smart;
    std::size_t batch_capacity = 0;
    unsigned cpu_workers = std::numeric_limits<unsigned>::max();
    // Zero selects the profile/device recommendation. Non-zero values are
    // intended for repeatable local benchmarking only.
    unsigned cuda_master_block_size = 0;
    unsigned cuda_address_block_size = 0;
};

struct MnemonicSearchOutcome {
    bool found = false;
    bool stopped = false;
    std::string address;
    std::string mnemonic;
    std::string derivation_path = kTronDerivationPath;
    std::string source;
    std::uint64_t attempts = 0;
    double elapsed = 0;
};

class MnemonicEngine {
public:
    explicit MnemonicEngine(MnemonicEngineOptions options = {});
    ~MnemonicEngine();

    MnemonicEngine(const MnemonicEngine&) = delete;
    MnemonicEngine& operator=(const MnemonicEngine&) = delete;

    bool initialize(
        const std::filesystem::path& executable_directory,
        const ProtocolEmitter& emit,
        std::string& error);

    bool search(
        const MatchPlan& plan,
        const std::atomic<bool>& stop_requested,
        const ProtocolEmitter& emit,
        MnemonicSearchOutcome& outcome,
        std::string& error);

    const std::string& device_name() const noexcept;
    std::size_t batch_capacity() const noexcept;
    std::size_t active_batch_size() const noexcept;
    unsigned cpu_worker_count() const noexcept;
    unsigned cuda_master_block_size() const noexcept;
    unsigned cuda_address_block_size() const noexcept;
    unsigned cpu_budget() const noexcept;
    const std::string& cpu_budget_source() const noexcept;
    MnemonicComputeProfile active_profile() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace trx
