#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace trx {

struct MatchPlan {
    std::string prefix;
    std::string suffix;
    std::vector<std::uint8_t> payload_mins;
    std::vector<std::uint8_t> payload_maxs;
    std::vector<std::uint8_t> full_mins;
    std::vector<std::uint8_t> full_maxs;
    std::uint32_t prefix_range_count = 0;
    std::uint64_t suffix_modulus = 1;
    std::uint64_t suffix_remainder = 0;
    std::uint32_t suffix_probe_target = 0;

    static bool create(
        const std::string& prefix,
        const std::string& suffix,
        MatchPlan& output,
        std::string& error);
};

bool match_plan_self_test(std::string& error);

}  // namespace trx
