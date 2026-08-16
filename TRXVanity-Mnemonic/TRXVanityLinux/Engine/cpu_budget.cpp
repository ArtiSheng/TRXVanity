#include "cpu_budget.hpp"

#include <algorithm>
#include <fstream>
#include <limits>
#include <sstream>
#include <thread>

#if defined(__linux__)
#include <sched.h>
#endif

namespace trx {
namespace {

unsigned positive_logical_cpus() noexcept {
    return std::max(1U, std::thread::hardware_concurrency());
}

unsigned quota_to_cpu_count(
    unsigned long long quota,
    unsigned long long period) noexcept {
    if (quota == 0 || period == 0) return 0;
    const auto whole = quota / period;
    return static_cast<unsigned>(std::max<unsigned long long>(
        1,
        std::min<unsigned long long>(
            whole,
            std::numeric_limits<unsigned>::max())));
}

#if defined(__linux__)
bool read_first_line(const char* path, std::string& output) noexcept {
    try {
        std::ifstream input(path);
        if (!input || !std::getline(input, output)) return false;
        return true;
    } catch (...) {
        return false;
    }
}

bool read_signed_file(
    const char* path,
    long long& output) noexcept {
    std::string line;
    if (!read_first_line(path, line)) return false;
    try {
        std::size_t consumed = 0;
        const auto parsed = std::stoll(line, &consumed);
        if (consumed != line.size()) return false;
        output = parsed;
        return true;
    } catch (...) {
        return false;
    }
}
#endif

unsigned detect_affinity_cpus(unsigned fallback) noexcept {
#if defined(__linux__)
    cpu_set_t allowed;
    CPU_ZERO(&allowed);
    if (::sched_getaffinity(0, sizeof(allowed), &allowed) == 0) {
        const int count = CPU_COUNT(&allowed);
        if (count > 0) return static_cast<unsigned>(count);
    }
#endif
    return fallback;
}

unsigned detect_quota_cpus(std::string& source) noexcept {
#if defined(__linux__)
    std::string cpu_max;
    unsigned quota_cpus = 0;
    if (read_first_line("/sys/fs/cgroup/cpu.max", cpu_max)
        && parse_cgroup_v2_cpu_max(cpu_max, quota_cpus)) {
        if (quota_cpus != 0) source = "cgroup-v2";
        return quota_cpus;
    }

    long long quota = 0;
    long long period = 0;
    if (read_signed_file(
            "/sys/fs/cgroup/cpu/cpu.cfs_quota_us", quota)
        && read_signed_file(
            "/sys/fs/cgroup/cpu/cpu.cfs_period_us", period)
        && quota > 0
        && period > 0) {
        const auto result = quota_to_cpu_count(
            static_cast<unsigned long long>(quota),
            static_cast<unsigned long long>(period));
        if (result != 0) source = "cgroup-v1";
        return result;
    }
#else
    (void)source;
#endif
    return 0;
}

}  // namespace

bool parse_cgroup_v2_cpu_max(
    const std::string& value,
    unsigned& quota_cpus) noexcept {
    quota_cpus = 0;
    try {
        std::istringstream input(value);
        std::string quota_text;
        unsigned long long period = 0;
        std::string trailing;
        if (!(input >> quota_text >> period) || (input >> trailing)
            || period == 0) {
            return false;
        }
        if (quota_text == "max") return true;
        std::size_t consumed = 0;
        const auto quota = std::stoull(quota_text, &consumed);
        if (consumed != quota_text.size() || quota == 0) return false;
        quota_cpus = quota_to_cpu_count(quota, period);
        return quota_cpus != 0;
    } catch (...) {
        quota_cpus = 0;
        return false;
    }
}

CpuBudget detect_cpu_budget() noexcept {
    CpuBudget budget;
    budget.logical_cpus = positive_logical_cpus();
    budget.affinity_cpus = detect_affinity_cpus(budget.logical_cpus);
    budget.source = budget.affinity_cpus < budget.logical_cpus
        ? "affinity"
        : "logical";
    budget.quota_cpus = detect_quota_cpus(budget.source);
    budget.effective_cpus = std::min(
        budget.logical_cpus,
        budget.affinity_cpus);
    if (budget.quota_cpus != 0) {
        budget.effective_cpus = std::min(
            budget.effective_cpus,
            budget.quota_cpus);
    }
    budget.effective_cpus = std::max(1U, budget.effective_cpus);
    return budget;
}

unsigned recommended_gpu_cpu_workers(const CpuBudget& budget) noexcept {
    if (budget.effective_cpus <= 2) return 0;

    // Sustained RTX 5090 measurements found two stable operating tiers:
    // 16 effective CPUs perform best with 8 workers, while a 25-CPU quota can
    // use 20 without cgroup throttling and gains about 0.4% total throughput.
    // Cap the large-budget tier so an unrestricted host never recreates the
    // 128-worker oversubscription that starved CUDA submission.
    if (budget.effective_cpus >= 25) return 20;
    return budget.effective_cpus / 2;
}

}  // namespace trx
