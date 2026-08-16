#pragma once

#include "crypto.hpp"
#include "match_plan.hpp"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>

namespace trx {

using ProtocolEmitter = std::function<void(const std::string&)>;

struct SearchOutcome {
    bool found = false;
    bool stopped = false;
    std::string address;
    std::string tweak_hex;
    std::uint64_t attempts = 0;
    double elapsed = 0;
};

class OpenClEngine {
public:
    explicit OpenClEngine(std::size_t inverse_multiple = 0);
    ~OpenClEngine();

    OpenClEngine(const OpenClEngine&) = delete;
    OpenClEngine& operator=(const OpenClEngine&) = delete;

    bool initialize(
        const std::filesystem::path& executable_directory,
        const PublicKey& base_public,
        const ProtocolEmitter& emit,
        std::string& error);

    bool search(
        const MatchPlan& plan,
        const std::atomic<bool>& stop_requested,
        const ProtocolEmitter& emit,
        SearchOutcome& outcome,
        std::string& error,
        std::uint64_t maximum_batches = 0);

    bool forced_suffix_self_test(
        const ProtocolEmitter& emit,
        std::string& error);

    const std::string& device_name() const noexcept;
    std::size_t lane_count() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace trx
