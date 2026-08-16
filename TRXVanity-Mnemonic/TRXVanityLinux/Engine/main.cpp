#include "crypto.hpp"
#include "match_plan.hpp"
#include "mnemonic_engine.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <sys/prctl.h>
#include <sys/resource.h>

namespace {

std::string clean_field(std::string value) {
    for (auto& character : value) {
        if (character == '\t' || character == '\r' || character == '\n') {
            character = ' ';
        }
    }
    return value;
}

// Protocol lines already contain intentional tab separators. Only payloads are
// sanitized by callers, so this variant preserves the separators. All engine
// callbacks are synchronous on the host/search thread, so no output lock is
// needed. Flush exactly once per complete line for prompt UI updates.
void emit_protocol(const std::string& line) {
    std::cout.write(line.data(), static_cast<std::streamsize>(line.size()));
    std::cout.put('\n');
    std::cout.flush();
}

std::filesystem::path executable_directory() {
    std::error_code error;
    const auto executable = std::filesystem::read_symlink("/proc/self/exe", error);
    if (error || executable.empty()) {
        return std::filesystem::current_path();
    }
    return executable.parent_path();
}

std::vector<std::string> split_tabs(const std::string& line) {
    std::vector<std::string> fields;
    std::size_t start = 0;
    while (true) {
        const auto position = line.find('\t', start);
        if (position == std::string::npos) {
            fields.push_back(line.substr(start));
            return fields;
        }
        fields.push_back(line.substr(start, position - start));
        start = position + 1;
    }
}

struct CommandState {
    struct PendingCommand {
        std::string line;
        std::uint64_t cancel_epoch = 0;
    };

    std::mutex mutex;
    std::condition_variable condition;
    std::deque<PendingCommand> pending;
    // Protected by mutex. Each STOP advances the epoch, invalidating only
    // START commands accepted before that STOP. Commands accepted afterwards
    // carry the new epoch and can safely restart after an active search exits.
    std::uint64_t cancel_epoch = 0;
    std::atomic<bool> stop_requested{false};
    std::atomic<bool> exit_requested{false};
};

void read_commands(CommandState& state) {
    std::string line;
    while (std::getline(std::cin, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line == "STOP") {
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                ++state.cancel_epoch;
                state.stop_requested.store(true, std::memory_order_relaxed);
            }
            state.condition.notify_all();
            continue;
        }
        if (line == "EXIT") {
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                state.stop_requested.store(true, std::memory_order_relaxed);
                state.exit_requested.store(true, std::memory_order_relaxed);
            }
            state.condition.notify_all();
            return;
        }
        if (line.rfind("START\t", 0) == 0) {
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                state.pending.push_back({line, state.cancel_epoch});
            }
            state.condition.notify_one();
        }
    }
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.stop_requested.store(true, std::memory_order_relaxed);
        state.exit_requested.store(true, std::memory_order_relaxed);
    }
    state.condition.notify_all();
}

bool parse_size_value(
    const char* option,
    const char* value,
    std::size_t& output) {
    try {
        const std::string text(value);
        std::size_t consumed = 0;
        const auto parsed = std::stoull(text, &consumed);
        if (consumed != text.size()
            || parsed > std::numeric_limits<std::size_t>::max()) {
            throw std::out_of_range("size");
        }
        output = static_cast<std::size_t>(parsed);
        return true;
    } catch (...) {
        std::cerr << "Invalid " << option << " value." << std::endl;
        return false;
    }
}

bool parse_cuda_block_size(
    const char* option,
    const char* value,
    unsigned& output) {
    std::size_t parsed_block_size = 0;
    if (!parse_size_value(option, value, parsed_block_size)
        || parsed_block_size < 32
        || parsed_block_size > 1024
        || parsed_block_size % 32 != 0) {
        std::cerr << option
                  << " must be a warp multiple between 32 and 1024."
                  << std::endl;
        return false;
    }
    output = static_cast<unsigned>(parsed_block_size);
    return true;
}

bool run_self_test(const trx::MnemonicEngineOptions& options) {
    std::string error;
    if (!trx::crypto_self_test(error)) {
        std::cerr << "CPU crypto self-test failed: " << error << std::endl;
        return false;
    }
    if (!trx::match_plan_self_test(error)) {
        std::cerr << "Match-plan self-test failed: " << error << std::endl;
        return false;
    }

    trx::MnemonicEngine engine(options);
    const auto test_emitter = [](const std::string& line) {
        std::cout << line << std::endl;
    };
    if (!engine.initialize(executable_directory(), test_emitter, error)) {
        std::cerr << "GPU initialization self-test failed: " << error << std::endl;
        return false;
    }

    std::cout << "SELFTEST\tOK\t" << engine.device_name() << '\t'
              << trx::kTronDerivationPath << std::endl;
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    // A successful search briefly exists in this process as plaintext.  Do
    // not permit core dumps or ordinary ptrace-style process inspection to
    // copy it to persistent storage or another process.
    const rlimit core_limit{0, 0};
    if (setrlimit(RLIMIT_CORE, &core_limit) != 0
        || prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) {
        std::cerr << "Unable to apply Linux secret-memory process hardening."
                  << std::endl;
        return 1;
    }

    std::ios::sync_with_stdio(false);

    bool self_test = false;
    bool unified_cuda_block_size_seen = false;
    bool separate_cuda_block_size_seen = false;
    trx::MnemonicEngineOptions engine_options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--self-test") {
            self_test = true;
        } else if (argument == "--profile" && index + 1 < argc) {
            if (!trx::parse_mnemonic_compute_profile(
                    argv[++index], engine_options.profile)) {
                std::cerr << "Invalid --profile value. Expected rtx5070, rtx4090, "
                    "or smart." << std::endl;
                return 2;
            }
        } else if (argument == "--batch-size" && index + 1 < argc) {
            if (!parse_size_value(
                    "--batch-size", argv[++index], engine_options.batch_capacity)) return 2;
        } else if (argument == "--cpu-workers" && index + 1 < argc) {
            std::size_t parsed_workers = 0;
            if (!parse_size_value(
                    "--cpu-workers", argv[++index], parsed_workers)
                || parsed_workers > 256) {
                std::cerr << "--cpu-workers must be between 0 and 256." << std::endl;
                return 2;
            }
            engine_options.cpu_workers = static_cast<unsigned>(parsed_workers);
        } else if (argument == "--cuda-block-size" && index + 1 < argc) {
            if (separate_cuda_block_size_seen) {
                std::cerr << "--cuda-block-size cannot be combined with "
                             "--cuda-master-block-size or --cuda-address-block-size."
                          << std::endl;
                return 2;
            }
            unsigned block_size = 0;
            if (!parse_cuda_block_size(
                    "--cuda-block-size", argv[++index], block_size)) return 2;
            engine_options.cuda_master_block_size = block_size;
            engine_options.cuda_address_block_size = block_size;
            unified_cuda_block_size_seen = true;
        } else if (argument == "--cuda-master-block-size" && index + 1 < argc) {
            if (unified_cuda_block_size_seen) {
                std::cerr << "--cuda-block-size cannot be combined with "
                             "--cuda-master-block-size or --cuda-address-block-size."
                          << std::endl;
                return 2;
            }
            if (!parse_cuda_block_size(
                    "--cuda-master-block-size",
                    argv[++index],
                    engine_options.cuda_master_block_size)) return 2;
            separate_cuda_block_size_seen = true;
        } else if (argument == "--cuda-address-block-size" && index + 1 < argc) {
            if (unified_cuda_block_size_seen) {
                std::cerr << "--cuda-block-size cannot be combined with "
                             "--cuda-master-block-size or --cuda-address-block-size."
                          << std::endl;
                return 2;
            }
            if (!parse_cuda_block_size(
                    "--cuda-address-block-size",
                    argv[++index],
                    engine_options.cuda_address_block_size)) return 2;
            separate_cuda_block_size_seen = true;
        } else if (argument == "--server") {
            // Default mode; accepted explicitly for a readable process command line.
        } else {
            std::cerr << "Unknown argument: " << argument << std::endl;
            return 2;
        }
    }

    if (self_test) {
        return run_self_test(engine_options) ? 0 : 1;
    }

    std::string error;
    if (!trx::crypto_self_test(error) || !trx::match_plan_self_test(error)) {
        emit_protocol("ERROR\t" + clean_field(error));
        return 1;
    }

    trx::MnemonicEngine engine(engine_options);
    const auto protocol_emitter = [](const std::string& line) {
        emit_protocol(line);
    };
    if (!engine.initialize(executable_directory(), protocol_emitter, error)) {
        emit_protocol("ERROR\t" + clean_field(error));
        return 1;
    }
    CommandState commands;
    std::thread reader(read_commands, std::ref(commands));
    const char* kernel_mode = engine.cpu_worker_count() == 0
        ? "cuda-bip39"
        : "cuda-bip39+openssl-cpu";
    emit_protocol(
        "READY\t" + clean_field(engine.device_name())
        + "\t" + std::to_string(engine.batch_capacity())
        + "\t" + trx::mnemonic_compute_profile_id(engine.active_profile())
        + "\t" + std::to_string(engine.cpu_worker_count())
        + "\t" + std::to_string(engine.active_batch_size())
        + "\t" + std::to_string(engine.cuda_master_block_size())
        + "\t" + std::to_string(engine.cuda_address_block_size())
        + "\t" + kernel_mode
        + "\t" + std::to_string(engine.cpu_budget())
        + "\t" + clean_field(engine.cpu_budget_source()));

    while (!commands.exit_requested.load(std::memory_order_relaxed)) {
        CommandState::PendingCommand command;
        bool cancelled_before_start = false;
        {
            std::unique_lock<std::mutex> lock(commands.mutex);
            commands.condition.wait(lock, [&] {
                return !commands.pending.empty()
                    || commands.exit_requested.load(std::memory_order_relaxed);
            });
            if (commands.exit_requested.load(std::memory_order_relaxed)) {
                break;
            }
            command = std::move(commands.pending.front());
            commands.pending.pop_front();
            cancelled_before_start = command.cancel_epoch != commands.cancel_epoch;
            if (!cancelled_before_start) {
                // Reset cancellation only when this START has atomically
                // become active. A subsequent STOP cannot be lost, while a
                // START queued after that STOP carries its newer epoch.
                commands.stop_requested.store(false, std::memory_order_relaxed);
            }
        }
        if (cancelled_before_start) {
            // Every accepted START gets a terminal response, even if STOP
            // overtook it before the search thread could dequeue it.
            emit_protocol("STOPPED");
            continue;
        }

        const auto fields = split_tabs(command.line);
        if (fields.size() != 3) {
            emit_protocol("ERROR\tMalformed START command.");
            continue;
        }
        trx::MatchPlan plan;
        if (!trx::MatchPlan::create(fields[1], fields[2], plan, error)) {
            emit_protocol("ERROR\t" + clean_field(error));
            continue;
        }

        emit_protocol("SEARCHING\t" + fields[1] + "\t" + fields[2]);
        trx::MnemonicSearchOutcome outcome;
        if (!engine.search(
                plan,
                commands.stop_requested,
                protocol_emitter,
                outcome,
                error)) {
            emit_protocol("ERROR\t" + clean_field(error));
            // CUDA failures can leave the context unusable. The stdin reader
            // can be blocked in a synchronous pipe read, so terminate
            // explicitly instead of unwinding through a joinable thread.
            std::_Exit(EXIT_FAILURE);
        }
        if (outcome.found) {
            std::ostringstream line;
            line << "RESULT\t" << outcome.address << '\t' << outcome.mnemonic
                 << '\t' << outcome.attempts << '\t'
                 << std::fixed << std::setprecision(3) << outcome.elapsed
                 << '\t' << outcome.source;
            emit_protocol(line.str());
        } else {
            emit_protocol("STOPPED");
        }
    }

    commands.stop_requested.store(true, std::memory_order_relaxed);
    if (reader.joinable()) {
        reader.join();
    }
    return 0;
}
