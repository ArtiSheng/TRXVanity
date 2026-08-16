#include "crypto.hpp"
#include "match_plan.hpp"
#include "opencl_engine.hpp"
#include "public_crypto.hpp"
#include "request.hpp"

#include <atomic>
#include <csignal>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

std::atomic<bool>* g_stop = nullptr;

void handle_signal(int) {
    if (g_stop != nullptr) g_stop->store(true, std::memory_order_relaxed);
}

std::string clean_field(std::string value) {
    for (auto& character : value) {
        if (character == '\t' || character == '\r' || character == '\n') {
            character = ' ';
        }
    }
    return value;
}

void emit_line(const std::string& line) {
    std::cout << line << '\n';
    std::cout.flush();
}

std::filesystem::path executable_directory() {
    std::vector<char> path(4096, 0);
    const auto length = readlink("/proc/self/exe", path.data(), path.size() - 1);
    if (length > 0 && static_cast<std::size_t>(length) < path.size()) {
        path[static_cast<std::size_t>(length)] = '\0';
        return std::filesystem::path(path.data()).parent_path();
    }
    return std::filesystem::current_path();
}

bool parse_size(const std::string& value, std::size_t& output) {
    if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos) {
        return false;
    }
    try {
        std::size_t consumed = 0;
        const auto parsed = std::stoull(value, &consumed, 10);
        if (consumed != value.size()
            || parsed > std::numeric_limits<std::size_t>::max()) {
            return false;
        }
        output = static_cast<std::size_t>(parsed);
        return true;
    } catch (...) {
        return false;
    }
}

bool parse_u64(const std::string& value, std::uint64_t& output) {
    if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos) {
        return false;
    }
    try {
        std::size_t consumed = 0;
        output = std::stoull(value, &consumed, 10);
        return consumed == value.size();
    } catch (...) {
        return false;
    }
}

bool fixed_public_key(trx::PublicKey& output, std::string& error) {
    static constexpr char kGenerator[] =
        "0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"
        "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8";
    return trx::parse_hex_exact(kGenerator, output.data(), output.size(), error);
}

bool run_cpu_tests(std::string& error) {
    return trx::encoding_self_test(error)
        && trx::match_plan_self_test(error)
        && trx::public_crypto_self_test(error);
}

int run_self_test(std::size_t inverse_multiple) {
    std::string error;
    if (!run_cpu_tests(error)) {
        std::cerr << "CPU/public self-test failed: " << error << '\n';
        return 1;
    }
    trx::PublicKey public_key{};
    if (!fixed_public_key(public_key, error)) {
        std::cerr << "Fixed public-key vector failed: " << error << '\n';
        return 1;
    }
    trx::OpenClEngine engine(inverse_multiple);
    if (!engine.initialize(executable_directory(), public_key, emit_line, error)) {
        std::cerr << "GPU initialization self-test failed: " << error << '\n';
        return 1;
    }
    if (!engine.forced_suffix_self_test(emit_line, error)) {
        std::cerr << "GPU split-key self-test failed: " << error << '\n';
        return 1;
    }
    emit_line("SELFTEST\tOK\t" + clean_field(engine.device_name()) + "\t"
        + std::to_string(engine.lane_count()) + "\tPUBLIC_ONLY");
    return 0;
}

void usage() {
    std::cerr
        << "Usage:\n"
        << "  trxvanity-linux-gpu --request FILE [--inverse-multiple N] [--max-batches N]\n"
        << "  trxvanity-linux-gpu --self-test [--inverse-multiple N]\n";
}

}  // namespace

int main(int argc, char** argv) {
    std::filesystem::path request_path;
    std::size_t inverse_multiple = 0;
    std::uint64_t maximum_batches = 0;
    bool self_test = false;

    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--self-test") {
            self_test = true;
        } else if (argument == "--request" && index + 1 < argc) {
            request_path = argv[++index];
        } else if (argument == "--inverse-multiple" && index + 1 < argc) {
            if (!parse_size(argv[++index], inverse_multiple) || inverse_multiple == 0) {
                std::cerr << "Invalid --inverse-multiple value.\n";
                return 2;
            }
        } else if (argument == "--max-batches" && index + 1 < argc) {
            if (!parse_u64(argv[++index], maximum_batches) || maximum_batches == 0) {
                std::cerr << "Invalid --max-batches value.\n";
                return 2;
            }
        } else if (argument == "--help" || argument == "-h") {
            usage();
            return 0;
        } else {
            std::cerr << "Unknown or incomplete argument: " << argument << '\n';
            usage();
            return 2;
        }
    }

    if (self_test) {
        if (!request_path.empty() || maximum_batches != 0) {
            std::cerr << "--self-test cannot be combined with --request or --max-batches.\n";
            return 2;
        }
        return run_self_test(inverse_multiple);
    }
    if (request_path.empty()) {
        usage();
        return 2;
    }

    std::string error;
    trx::SplitRequest request;
    if (!trx::read_split_request(request_path, request, error)) {
        emit_line("ERROR\t1\t-\tREQUEST\t" + clean_field(error));
        return 1;
    }
    trx::MatchPlan plan;
    if (!trx::MatchPlan::create({}, request.suffix, plan, error)) {
        emit_line("ERROR\t1\t" + request.job_id + "\tPATTERN\t" + clean_field(error));
        return 1;
    }
    if (!run_cpu_tests(error)) {
        emit_line("ERROR\t1\t" + request.job_id + "\tSELFTEST\t" + clean_field(error));
        return 1;
    }

    emit_line("SECURITY\t1\t" + request.job_id + "\tPUBLIC_ONLY");
    trx::OpenClEngine engine(inverse_multiple);
    const auto engine_emitter = [&](const std::string& line) {
        if (line.rfind("PROGRESS\t", 0) == 0) {
            emit_line("PROGRESS\t1\t" + request.job_id + "\t" + line.substr(9));
        } else {
            emit_line(line);
        }
    };
    if (!engine.initialize(
            executable_directory(), request.base_public, engine_emitter, error)) {
        emit_line("ERROR\t1\t" + request.job_id + "\tGPU_INIT\t" + clean_field(error));
        return 1;
    }
    emit_line("READY\t1\t" + request.job_id + "\t"
        + clean_field(engine.device_name()) + "\t" + std::to_string(engine.lane_count()));
    emit_line("SEARCHING\t1\t" + request.job_id + "\t" + request.suffix);

    std::atomic<bool> stop{false};
    g_stop = &stop;
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
    trx::SearchOutcome outcome;
    const bool searched = engine.search(
        plan, stop, engine_emitter, outcome, error, maximum_batches);
    g_stop = nullptr;
    if (!searched) {
        emit_line("ERROR\t1\t" + request.job_id + "\tSEARCH\t" + clean_field(error));
        return 1;
    }
    if (!outcome.found) {
        emit_line("STOPPED\t1\t" + request.job_id);
        return 3;
    }

    std::ostringstream result;
    result << "RESULT\t1\t" << request.job_id << '\t' << outcome.address << '\t'
           << outcome.tweak_hex << '\t' << outcome.attempts << '\t'
           << std::fixed << std::setprecision(3) << outcome.elapsed;
    emit_line(result.str());
    return 0;
}
