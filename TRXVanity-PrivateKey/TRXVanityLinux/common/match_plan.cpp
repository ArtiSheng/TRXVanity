#include "match_plan.hpp"

#include <utility>

namespace trx {
namespace {

constexpr char kAlphabet[] =
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

int base58_digit(unsigned char value) noexcept {
    if (value >= '1' && value <= '9') {
        return value - '1';
    }
    if (value >= 'A' && value <= 'H') {
        return value - 'A' + 9;
    }
    if (value >= 'J' && value <= 'N') {
        return value - 'J' + 17;
    }
    if (value >= 'P' && value <= 'Z') {
        return value - 'P' + 22;
    }
    if (value >= 'a' && value <= 'k') {
        return value - 'a' + 33;
    }
    if (value >= 'm' && value <= 'z') {
        return value - 'm' + 44;
    }
    return -1;
}

bool decode_suffix(
    const std::string& suffix,
    std::uint64_t& modulus,
    std::uint64_t& remainder) noexcept {
    if (suffix.empty() || suffix.size() > 10) {
        return false;
    }
    // 58^10 is 430,804,206,899,405,824 and therefore safely fits in
    // uint64_t. Decode and build the modulus in one pass over the pattern.
    modulus = 1;
    remainder = 0;
    for (const char character : suffix) {
        const int digit = base58_digit(static_cast<unsigned char>(character));
        if (digit < 0) {
            return false;
        }
        modulus *= 58ULL;
        remainder = remainder * 58ULL + static_cast<std::uint64_t>(digit);
    }
    return true;
}

}  // namespace

bool MatchPlan::create(
    const std::string& wanted_prefix,
    const std::string& wanted_suffix,
    MatchPlan& output,
    std::string& error) {
    if (!wanted_prefix.empty()) {
        error = "Custom prefixes are not supported.";
        return false;
    }
    if (wanted_suffix.empty()) {
        error = "A suffix is required.";
        return false;
    }
    MatchPlan plan;
    plan.suffix = wanted_suffix;

    if (!decode_suffix(
            wanted_suffix, plan.suffix_modulus, plan.suffix_remainder)) {
        error = "The suffix must contain 1 to 10 TRON Base58 characters.";
        return false;
    }
    plan.suffix_probe_target = static_cast<std::uint32_t>(
        plan.suffix_remainder % (58ULL * 58ULL * 58ULL));

    output = std::move(plan);
    return true;
}

bool match_plan_self_test(std::string& error) {
    for (std::uint64_t digit = 0; digit < 58; ++digit) {
        MatchPlan digit_plan;
        if (!MatchPlan::create(
                {}, std::string(1, kAlphabet[digit]), digit_plan, error)
            || digit_plan.suffix_modulus != 58
            || digit_plan.suffix_remainder != digit
            || digit_plan.suffix_probe_target != digit) {
            error = "Base58 digit decoding match-plan vector failed.";
            return false;
        }
    }
    std::uint64_t expected_modulus = 1;
    for (std::size_t length = 1; length <= 10; ++length) {
        expected_modulus *= 58ULL;
        MatchPlan length_plan;
        if (!MatchPlan::create({}, std::string(length, '1'), length_plan, error)
            || length_plan.suffix_modulus != expected_modulus
            || length_plan.suffix_remainder != 0) {
            error = "Base58 suffix-length vector failed at length "
                + std::to_string(length) + ".";
            return false;
        }
    }
    MatchPlan upper_case;
    MatchPlan lower_case;
    if (!MatchPlan::create({}, "A", upper_case, error)
        || !MatchPlan::create({}, "a", lower_case, error)
        || upper_case.suffix_remainder == lower_case.suffix_remainder) {
        error = "Base58 suffix matching lost case sensitivity.";
        return false;
    }
    MatchPlan plan;
    if (!MatchPlan::create({}, "Az1zY9mN2x", plan, error)) {
        return false;
    }
    if (plan.prefix_range_count != 0
        || plan.suffix_modulus != 430804206899405824ULL
        || plan.suffix_probe_target != plan.suffix_remainder % 195112ULL) {
        error = "Ten-digit Base58 match-plan vector failed.";
        return false;
    }
    MatchPlan probe_plan;
    if (!MatchPlan::create({}, "Az1", probe_plan, error)
        || probe_plan.suffix_modulus != 195112ULL
        || probe_plan.suffix_remainder != 33582ULL
        || probe_plan.suffix_probe_target != 33582U) {
        error = "Three-digit Base58 probe vector failed.";
        return false;
    }
    MatchPlan rejected;
    if (MatchPlan::create({}, "12345678912", rejected, error)) {
        error = "An eleven-digit suffix was not rejected.";
        return false;
    }
    if (MatchPlan::create({}, "TR0N", rejected, error)) {
        error = "A non-Base58 suffix was not rejected.";
        return false;
    }
    if (MatchPlan::create("1", "abc", rejected, error)) {
        error = "A custom prefix was not rejected.";
        return false;
    }
    error.clear();
    return true;
}

}  // namespace trx
