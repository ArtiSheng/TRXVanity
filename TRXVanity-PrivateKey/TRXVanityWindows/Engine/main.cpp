#include "crypto.hpp"
#include "match_plan.hpp"
#include "opencl_engine.hpp"

#define NOMINMAX
#include <Windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

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

std::wstring executable_directory() {
    std::vector<wchar_t> path(32768, 0);
    const auto length = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0 || length >= path.size()) {
        return std::filesystem::current_path().wstring();
    }
    return std::filesystem::path(std::wstring(path.data(), length)).parent_path().wstring();
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

bool run_self_test(std::size_t inverse_multiple) {
    std::string error;
    if (!trx::crypto_self_test(error)) {
        std::cerr << "CPU crypto self-test failed: " << error << std::endl;
        return false;
    }
    if (!trx::match_plan_self_test(error)) {
        std::cerr << "Match-plan self-test failed: " << error << std::endl;
        return false;
    }

    trx::OpenClEngine engine(inverse_multiple);
    const auto test_emitter = [](const std::string& line) {
        std::cout << line << std::endl;
    };
    if (!engine.initialize(executable_directory(), test_emitter, error)) {
        std::cerr << "GPU initialization self-test failed: " << error << std::endl;
        return false;
    }

    const std::string cases[] = {
        "1",
        "111",
        "1111",
        "Az1",
        "Az",
        "z9",
    };
    std::atomic<bool> stop{false};
    trx::SearchOutcome outcome;
    for (const auto& test_case : cases) {
        trx::MatchPlan plan;
        if (!trx::MatchPlan::create({}, test_case, plan, error)) {
            std::cerr << "GPU match-plan self-test failed: " << error << std::endl;
            return false;
        }
        if (!engine.search(plan, stop, test_emitter, outcome, error)) {
            std::cerr << "GPU hit/recovery self-test failed: " << error << std::endl;
            return false;
        }
        if (!outcome.found
            || !trx::matches(outcome.address, {}, test_case)) {
            std::cerr << "GPU self-test returned an address that missed its pattern." << std::endl;
            return false;
        }
    }
    if (!engine.long_suffix_self_test(test_emitter, error)) {
        std::cerr << "Long-suffix GPU self-test failed: " << error << std::endl;
        return false;
    }
    std::cout << "SELFTEST\tOK\t" << engine.device_name() << '\t'
              << outcome.address << '\t' << outcome.attempts << std::endl;
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    // Best-effort dispatch priority: the heavy work stays on the GPU, while
    // the host thread keeps the inverse/iterate queue continuously fed.
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);

    std::ios::sync_with_stdio(false);

    bool self_test = false;
    // Zero asks the engine to size the GPU batch from compute units and VRAM.
    std::size_t inverse_multiple = 0;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--self-test") {
            self_test = true;
        } else if (argument == "--inverse-multiple" && index + 1 < argc) {
            try {
                inverse_multiple = static_cast<std::size_t>(std::stoull(argv[++index]));
            } catch (...) {
                std::cerr << "Invalid --inverse-multiple value." << std::endl;
                return 2;
            }
        } else if (argument == "--server") {
            // Default mode; accepted explicitly for a readable process command line.
        } else {
            std::cerr << "Unknown argument: " << argument << std::endl;
            return 2;
        }
    }

    if (self_test) {
        return run_self_test(inverse_multiple) ? 0 : 1;
    }

    std::string error;
    if (!trx::crypto_self_test(error) || !trx::match_plan_self_test(error)) {
        emit_protocol("ERROR\t" + clean_field(error));
        return 1;
    }

    trx::OpenClEngine engine(inverse_multiple);
    const auto protocol_emitter = [](const std::string& line) {
        emit_protocol(line);
    };
    if (!engine.initialize(executable_directory(), protocol_emitter, error)) {
        emit_protocol("ERROR\t" + clean_field(error));
        return 1;
    }
    CommandState commands;
    std::thread reader(read_commands, std::ref(commands));
    emit_protocol(
        "READY\t" + clean_field(engine.device_name()) + "\t" + std::to_string(engine.lane_count()));

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
        trx::SearchOutcome outcome;
        if (!engine.search(
                plan,
                commands.stop_requested,
                protocol_emitter,
                outcome,
                error)) {
            emit_protocol("ERROR\t" + clean_field(error));
            // A failed blocking read may occur after the queued GPU kernels
            // advanced their persistent point state.  The host round can no
            // longer be proven synchronized, so this engine instance must not
            // accept another search. The stdin reader can be blocked in a
            // synchronous pipe read, so terminate explicitly instead of
            // unwinding through a still-joinable std::thread.
            ExitProcess(EXIT_FAILURE);
        }
        if (outcome.found) {
            std::ostringstream line;
            line << "RESULT\t" << outcome.address << '\t' << outcome.private_key
                 << '\t' << outcome.attempts << '\t'
                 << std::fixed << std::setprecision(3) << outcome.elapsed;
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
