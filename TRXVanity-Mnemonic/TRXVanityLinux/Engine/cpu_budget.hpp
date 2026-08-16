#pragma once

#include <string>

namespace trx {

struct CpuBudget {
    unsigned logical_cpus = 1;
    unsigned affinity_cpus = 1;
    unsigned quota_cpus = 0;
    unsigned effective_cpus = 1;
    std::string source = "logical";
};

// Parse the cgroup-v2 "cpu.max" payload. A zero quota means unlimited.
bool parse_cgroup_v2_cpu_max(
    const std::string& value,
    unsigned& quota_cpus) noexcept;

CpuBudget detect_cpu_budget() noexcept;

// Select a measured, bounded worker tier from the effective CPU budget. Small
// quotas reserve half for CUDA/control work; large quotas cap CPU search at 20
// so an unrestricted host cannot starve CUDA submission. Explicit values
// remain available to the benchmark harness.
unsigned recommended_gpu_cpu_workers(const CpuBudget& budget) noexcept;

}  // namespace trx
