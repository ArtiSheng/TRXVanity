#include "cpu_budget.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(1);
    }
}

}  // namespace

int main() {
    unsigned quota = 999;
    require(
        trx::parse_cgroup_v2_cpu_max("1600000 100000", quota)
            && quota == 16,
        "16-CPU cgroup-v2 quota parse failed");
    require(
        trx::parse_cgroup_v2_cpu_max("150000 100000", quota)
            && quota == 1,
        "fractional cgroup quota must use a conservative whole CPU");
    require(
        trx::parse_cgroup_v2_cpu_max("max 100000", quota)
            && quota == 0,
        "unlimited cgroup-v2 quota parse failed");
    require(
        !trx::parse_cgroup_v2_cpu_max("1600000 0", quota),
        "zero cgroup period was accepted");
    require(
        !trx::parse_cgroup_v2_cpu_max("invalid", quota),
        "malformed cgroup-v2 quota was accepted");

    trx::CpuBudget constrained;
    constrained.effective_cpus = 16;
    require(
        trx::recommended_gpu_cpu_workers(constrained) == 8,
        "16-CPU GPU worker split is incorrect");
    constrained.effective_cpus = 7;
    require(
        trx::recommended_gpu_cpu_workers(constrained) == 3,
        "odd GPU worker split is incorrect");
    constrained.effective_cpus = 24;
    require(
        trx::recommended_gpu_cpu_workers(constrained) == 12,
        "small-quota worker split changed at the tier boundary");
    constrained.effective_cpus = 25;
    require(
        trx::recommended_gpu_cpu_workers(constrained) == 20,
        "25-CPU measured worker tier is incorrect");
    constrained.effective_cpus = 128;
    require(
        trx::recommended_gpu_cpu_workers(constrained) == 20,
        "large host worker cap did not prevent oversubscription");
    constrained.effective_cpus = 2;
    require(
        trx::recommended_gpu_cpu_workers(constrained) == 0,
        "small CPU budget must be reserved for GPU submission");

    const auto detected = trx::detect_cpu_budget();
    require(detected.logical_cpus >= 1, "logical CPU detection returned zero");
    require(detected.affinity_cpus >= 1, "affinity CPU detection returned zero");
    require(detected.effective_cpus >= 1, "effective CPU detection returned zero");
    require(
        detected.effective_cpus <= detected.logical_cpus,
        "effective CPU budget exceeds logical CPUs");
    require(
        detected.effective_cpus <= detected.affinity_cpus,
        "effective CPU budget exceeds affinity CPUs");

    std::cout << "cpu_budget_test OK: " << detected.effective_cpus
              << " effective CPUs from " << detected.source << '\n';
    return 0;
}
