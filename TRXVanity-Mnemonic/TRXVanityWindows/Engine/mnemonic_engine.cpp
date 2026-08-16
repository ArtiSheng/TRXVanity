#include "mnemonic_engine.hpp"

#include "crypto.hpp"
#include "mnemonic_cuda.hpp"
#include "openssl_pbkdf2.hpp"

#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <exception>
#include <iomanip>
#include <limits>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

namespace trx {
namespace {

constexpr std::size_t kMinimumBatchCapacity = 4096;
constexpr std::size_t kMaximumBatchCapacity = 4U * 1024U * 1024U;
constexpr std::size_t kCandidateBytesAcrossSlots = 2U * 64U;

struct ProfileTuning {
    unsigned requested_master_block_size = 0;
    unsigned requested_address_block_size = 0;
    double target_kernel_seconds = 0.25;
    double tuned_lower_seconds = 0.18;
    double tuned_upper_seconds = 0.40;
};

std::size_t round_up_power_of_two(std::size_t value) noexcept {
    std::size_t result = 1;
    while (result < value && result < kMaximumBatchCapacity) {
        result <<= 1U;
    }
    return std::min(result, kMaximumBatchCapacity);
}

std::size_t device_capacity(
    MnemonicComputeProfile profile,
    const CudaMnemonicDeviceInfo& device) noexcept {
    const auto multiprocessors = static_cast<std::size_t>(
        std::max(1, device.multiprocessor_count));
    const std::size_t candidates_per_multiprocessor =
        profile == MnemonicComputeProfile::rtx_5070 ? 4096U : 8192U;
    std::size_t capacity = round_up_power_of_two(
        std::max(
            kMinimumBatchCapacity,
            multiprocessors * candidates_per_multiprocessor));

    // Two CUDA streams each retain one 64-byte BIP32 master per candidate.
    // Keep their combined allocation below one eighth of currently free VRAM
    // so display use and the secp256k1 table always have ample headroom.
    const auto memory_limit = std::max(
        kMinimumBatchCapacity,
        (device.free_memory / 8U) / kCandidateBytesAcrossSlots);
    capacity = std::min(capacity, memory_limit);
    capacity = (capacity / 128U) * 128U;

    return capacity;
}

ProfileTuning profile_tuning(
    MnemonicComputeProfile profile,
    const CudaMnemonicDeviceInfo& device) noexcept {
    ProfileTuning tuning;
    switch (profile) {
    case MnemonicComputeProfile::rtx_5070:
        // Preserve the launch geometry used by the original RTX 5070 build.
        tuning.requested_master_block_size = 256;
        tuning.requested_address_block_size = 256;
        tuning.target_kernel_seconds = 0.25;
        tuning.tuned_lower_seconds = 0.18;
        tuning.tuned_upper_seconds = 0.40;
        break;
    case MnemonicComputeProfile::rtx_4090:
        // Two streams at 98,304 candidates each produce 64 grouped address
        // blocks apiece, exactly covering the 4090's 128 SMs. Larger batches
        // benchmark slower because they reduce cross-stream interleaving.
        tuning.requested_master_block_size = 256;
        tuning.requested_address_block_size = 384;
        tuning.target_kernel_seconds = 0.14;
        tuning.tuned_lower_seconds = 0.09;
        tuning.tuned_upper_seconds = 0.20;
        break;
    case MnemonicComputeProfile::smart:
    default:
        tuning.requested_master_block_size = 0;
        tuning.requested_address_block_size = 0;
        tuning.target_kernel_seconds = device.name.find("RTX 4090")
                != std::string::npos
            ? 0.14
            : 0.25;
        tuning.tuned_lower_seconds = tuning.target_kernel_seconds * 0.68;
        tuning.tuned_upper_seconds = tuning.target_kernel_seconds * 1.45;
        break;
    }
    return tuning;
}

bool validate_profile_device(
    MnemonicComputeProfile profile,
    const CudaMnemonicDeviceInfo& device,
    std::string& error) {
    const char* required_model = nullptr;
    switch (profile) {
    case MnemonicComputeProfile::rtx_5070:
        required_model = "RTX 5070";
        break;
    case MnemonicComputeProfile::rtx_4090:
        required_model = "RTX 4090";
        break;
    case MnemonicComputeProfile::smart:
    default:
        return true;
    }
    if (device.name.find(required_model) != std::string::npos) return true;
    error = std::string("The selected profile requires an NVIDIA ")
        + required_model + "; use the smart profile for " + device.name + '.';
    return false;
}

std::size_t initial_batch(
    const CudaMnemonicDeviceInfo& device,
    unsigned master_block_size,
    unsigned address_block_size,
    unsigned address_candidates_per_thread,
    std::size_t capacity) {
    const auto multiprocessors = static_cast<std::size_t>(
        std::max(1, device.multiprocessor_count));
    const auto master_candidates = static_cast<std::size_t>(
        master_block_size) * 2U;
    // Two independent CUDA streams feed address blocks concurrently, so each
    // stream only needs half of a full-SM wave for the grouped address kernel.
    const auto address_candidates = static_cast<std::size_t>(
        address_block_size)
        * std::max(1U, (address_candidates_per_thread + 1U) / 2U);
    return std::min(
        capacity,
        multiprocessors * std::max(master_candidates, address_candidates));
}

std::size_t rounded_batch(std::size_t value, std::size_t capacity) {
    value = std::max<std::size_t>(128, std::min(value, capacity));
    value = (value / 128) * 128;
    return std::max<std::size_t>(128, value);
}

unsigned default_cpu_workers(MnemonicComputeProfile profile) noexcept {
    const unsigned logical = std::max(1U, std::thread::hardware_concurrency());
    (void)profile;
    return logical;
}

class CpuMnemonicSearch {
public:
    CpuMnemonicSearch(
        const std::vector<std::string>& words,
        const MatchPlan& plan,
        const std::atomic<bool>& external_stop)
        : words_(words), plan_(plan), external_stop_(external_stop) {}

    ~CpuMnemonicSearch() {
        stop_and_join();
        secure_zero(base_.data(), base_.size());
        secure_zero(result_entropy_.data(), result_entropy_.size());
        clear_secret(result_mnemonic_);
    }

    bool start(unsigned worker_count, std::string& error) {
        worker_count_ = worker_count;
        if (worker_count_ == 0) return true;
        if (BCryptGenRandom(
                nullptr,
                base_.data(),
                static_cast<ULONG>(base_.size()),
                BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
            error = "BCryptGenRandom failed while creating CPU BIP39 entropy.";
            return false;
        }
        try {
            threads_.reserve(worker_count_);
            for (unsigned worker = 0; worker < worker_count_; ++worker) {
                threads_.emplace_back(&CpuMnemonicSearch::run, this, worker);
            }
        } catch (const std::exception& exception) {
            stop_and_join();
            error = std::string("Unable to start the CPU mnemonic workers: ")
                + exception.what();
            return false;
        }
        return true;
    }

    void stop_and_join() noexcept {
        stop_.store(true, std::memory_order_relaxed);
        for (auto& thread : threads_) {
            if (thread.joinable()) thread.join();
        }
        threads_.clear();
    }

    std::uint64_t attempts() const noexcept {
        return attempts_.load(std::memory_order_relaxed);
    }

    bool result_ready() const noexcept {
        return result_ready_.load(std::memory_order_acquire);
    }

    bool claimed_result() const noexcept {
        return terminal_.load(std::memory_order_acquire) == 1U;
    }

    bool failed() const noexcept {
        return failed_.load(std::memory_order_acquire);
    }

    bool copy_result(
        Entropy128& entropy,
        std::string& mnemonic,
        std::string& address) {
        if (!result_ready()) return false;
        std::lock_guard<std::mutex> lock(result_mutex_);
        entropy = result_entropy_;
        mnemonic = result_mnemonic_;
        address = result_address_;
        return true;
    }

    std::string failure_message() {
        std::lock_guard<std::mutex> lock(result_mutex_);
        return failure_;
    }

private:
    static void clear_secret(std::string& value) noexcept {
        if (!value.empty()) secure_zero(value.data(), value.size());
        value.clear();
    }

    void run(unsigned worker) noexcept {
        (void)SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
        std::string mnemonic;
        std::string address;
        std::string local_error;
        std::uint64_t candidate = worker;
        while (!stop_.load(std::memory_order_relaxed)
            && !external_stop_.load(std::memory_order_relaxed)) {
            // A worker can claim a match and still be publishing its strings.
            // Once claimed, all peers must stop before they can publish an
            // unrelated failure that would mask the valid result.
            if (terminal_.load(std::memory_order_acquire) != 0U) break;
            auto entropy = entropy_at(base_, candidate);
            local_error.clear();
            if (!derive_mnemonic_candidate(
                    entropy, words_, mnemonic, address, local_error)) {
                unsigned expected = 0;
                if (terminal_.compare_exchange_strong(
                        expected, 2U, std::memory_order_acq_rel)) {
                    {
                        std::lock_guard<std::mutex> lock(result_mutex_);
                        failure_ = local_error.empty()
                            ? "A CPU mnemonic worker failed."
                            : local_error;
                    }
                    failed_.store(true, std::memory_order_release);
                }
                clear_secret(mnemonic);
                secure_zero(entropy.data(), entropy.size());
                stop_.store(true, std::memory_order_relaxed);
                break;
            }
            attempts_.fetch_add(1, std::memory_order_relaxed);
            if (matches(address, plan_.prefix, plan_.suffix)) {
                unsigned expected = 0;
                if (terminal_.compare_exchange_strong(
                        expected, 1U, std::memory_order_acq_rel)) {
                    {
                        std::lock_guard<std::mutex> lock(result_mutex_);
                        result_entropy_ = entropy;
                        result_mnemonic_ = mnemonic;
                        result_address_ = address;
                    }
                    result_ready_.store(true, std::memory_order_release);
                    stop_.store(true, std::memory_order_relaxed);
                }
                clear_secret(mnemonic);
                secure_zero(entropy.data(), entropy.size());
                break;
            }
            clear_secret(mnemonic);
            secure_zero(entropy.data(), entropy.size());
            if (candidate
                > std::numeric_limits<std::uint64_t>::max() - worker_count_) {
                break;
            }
            candidate += worker_count_;
        }
        clear_secret(mnemonic);
    }

    const std::vector<std::string>& words_;
    const MatchPlan& plan_;
    const std::atomic<bool>& external_stop_;
    Entropy128 base_{};
    Entropy128 result_entropy_{};
    unsigned worker_count_ = 0;
    std::atomic<bool> stop_{false};
    // 0 = running, 1 = a result owns publication, 2 = a failure owns it.
    std::atomic<unsigned> terminal_{0};
    std::atomic<bool> result_ready_{false};
    std::atomic<bool> failed_{false};
    std::atomic<std::uint64_t> attempts_{0};
    std::mutex result_mutex_;
    std::string result_mnemonic_;
    std::string result_address_;
    std::string failure_;
    std::vector<std::thread> threads_;
};

}  // namespace

struct MnemonicEngine::Impl {
    explicit Impl(MnemonicEngineOptions selected_options)
        : options(selected_options) {}

    MnemonicEngineOptions options;
    std::vector<std::string> words;
    std::string device;
    std::size_t capacity = 0;
    std::size_t batch_size = 0;
    unsigned cpu_workers = 0;
    unsigned master_block_size = 256;
    unsigned address_block_size = 256;
    double target_kernel_seconds = 0.25;
    double tuned_lower_seconds = 0.18;
    double tuned_upper_seconds = 0.40;
    bool initialized = false;
    bool tuned = false;
};

bool parse_mnemonic_compute_profile(
    const std::string& value,
    MnemonicComputeProfile& profile) noexcept {
    if (value == "rtx4090") {
        profile = MnemonicComputeProfile::rtx_4090;
        return true;
    }
    if (value == "rtx5070") {
        profile = MnemonicComputeProfile::rtx_5070;
        return true;
    }
    if (value == "smart") {
        profile = MnemonicComputeProfile::smart;
        return true;
    }
    return false;
}

const char* mnemonic_compute_profile_id(
    MnemonicComputeProfile profile) noexcept {
    switch (profile) {
    case MnemonicComputeProfile::rtx_5070:
        return "rtx5070";
    case MnemonicComputeProfile::rtx_4090:
        return "rtx4090";
    case MnemonicComputeProfile::smart:
    default:
        return "smart";
    }
}

MnemonicEngine::MnemonicEngine(MnemonicEngineOptions options)
    : impl_(std::make_unique<Impl>(options)) {}

MnemonicEngine::~MnemonicEngine() {
    if (impl_) {
        cuda_mnemonic_shutdown();
        openssl_pbkdf2_shutdown();
        impl_->initialized = false;
    }
}

bool MnemonicEngine::initialize(
    const std::wstring& executable_directory,
    const ProtocolEmitter& emit,
    std::string& error) {
    if (impl_->initialized) return true;
    emit("INIT\t5\tLoading the BIP39 English dictionary");
    const auto wordlist = std::filesystem::path(executable_directory)
        / L"bip39-english.txt";
    if (!load_bip39_english_words(wordlist, impl_->words, error)) {
        return false;
    }
    emit("INIT\t12\tLoading the OpenSSL CPU PBKDF2 accelerator");
    if (!openssl_pbkdf2_initialize(executable_directory, error)) {
        return false;
    }
    if (!mnemonic_self_test(impl_->words, error)) {
        return false;
    }

    CudaMnemonicDeviceInfo device_info;
    if (!cuda_mnemonic_query_device(device_info, error)) {
        return false;
    }
    if (!validate_profile_device(impl_->options.profile, device_info, error)) {
        return false;
    }
    const auto tuning = profile_tuning(impl_->options.profile, device_info);
    impl_->target_kernel_seconds = tuning.target_kernel_seconds;
    impl_->tuned_lower_seconds = tuning.tuned_lower_seconds;
    impl_->tuned_upper_seconds = tuning.tuned_upper_seconds;
    const auto safe_capacity = device_capacity(impl_->options.profile, device_info);
    if (impl_->options.batch_capacity > safe_capacity) {
        std::ostringstream message;
        message << "The requested CUDA batch capacity exceeds the safe limit of "
                << safe_capacity << " candidates for " << device_info.name << '.';
        error = message.str();
        return false;
    }
    impl_->capacity = impl_->options.batch_capacity == 0
        ? safe_capacity
        : rounded_batch(impl_->options.batch_capacity, safe_capacity);
    impl_->cpu_workers = impl_->options.cpu_workers
        == std::numeric_limits<unsigned>::max()
        ? default_cpu_workers(impl_->options.profile)
        : impl_->options.cpu_workers;

    emit("INIT\t25\tInitializing the CUDA BIP39 kernel");
    const auto requested_master_block_size =
        impl_->options.cuda_block_size == 0
        ? tuning.requested_master_block_size
        : impl_->options.cuda_block_size;
    const auto requested_address_block_size =
        impl_->options.cuda_block_size == 0
        ? tuning.requested_address_block_size
        : impl_->options.cuda_block_size;
    if (!cuda_mnemonic_initialize(
            wordlist,
            impl_->capacity,
            requested_master_block_size,
            requested_address_block_size,
            impl_->device,
            error)) {
        return false;
    }
    impl_->master_block_size = cuda_mnemonic_master_block_size();
    impl_->address_block_size = cuda_mnemonic_address_block_size();
    impl_->batch_size = rounded_batch(
        initial_batch(
            device_info,
            impl_->master_block_size,
            impl_->address_block_size,
            cuda_mnemonic_address_candidates_per_thread(),
            impl_->capacity),
        impl_->capacity);

    emit("INIT\t70\tCross-checking CUDA against the TronLink derivation vector");
    Entropy128 zero{};
    std::uint8_t* gpu_master = nullptr;
    double gpu_seconds = 0;
    if (!cuda_mnemonic_derive_batch(
            zero, 0, 1, gpu_master, gpu_seconds, error)) {
        cuda_mnemonic_shutdown();
        return false;
    }
    std::string mnemonic;
    if (!verify_mnemonic_candidate(
            zero,
            impl_->words,
            gpu_master,
            "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH",
            mnemonic,
            error)) {
        cuda_mnemonic_clear_host(1);
        cuda_mnemonic_shutdown();
        return false;
    }
    cuda_mnemonic_clear_host(1);

    const std::string vector_address = "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH";
    MatchPlan vector_plan;
    if (!MatchPlan::create(
            {},
            vector_address.substr(vector_address.size() - 10),
            vector_plan,
            error)
        || !cuda_mnemonic_launch_search_batch(
            0,
            zero,
            0,
            1,
            vector_plan.suffix_modulus,
            vector_plan.suffix_remainder,
            error)) {
        cuda_mnemonic_shutdown();
        return false;
    }
    std::uint32_t vector_winner = std::numeric_limits<std::uint32_t>::max();
    std::uint8_t* vector_master = nullptr;
    if (!cuda_mnemonic_wait_search_batch(
            0,
            vector_winner,
            vector_master,
            gpu_seconds,
            error)
        || vector_winner != 0
        || vector_master == nullptr) {
        if (error.empty()) {
            error = "The full CUDA TronLink derivation vector did not match.";
        }
        cuda_mnemonic_clear_host(1);
        cuda_mnemonic_shutdown();
        return false;
    }
    if (!verify_mnemonic_candidate(
            zero,
            impl_->words,
            vector_master,
            vector_address,
            mnemonic,
            error)) {
        cuda_mnemonic_clear_host(1);
        cuda_mnemonic_shutdown();
        return false;
    }
    cuda_mnemonic_clear_host(1);

    // Exercise a complete four-candidate address group. Candidate three is
    // independently derived on the CPU, so the optimized CUDA batch inversion
    // is verified for more than the single-lane vector above.
    const auto group_entropy = entropy_at(zero, 3);
    std::string group_mnemonic;
    std::string group_address;
    const auto clear_test_secret = [](std::string& value) noexcept {
        if (!value.empty()) secure_zero(value.data(), value.size());
        value.clear();
    };
    if (!derive_mnemonic_candidate(
            group_entropy,
            impl_->words,
            group_mnemonic,
            group_address,
            error)) {
        cuda_mnemonic_shutdown();
        return false;
    }
    MatchPlan group_plan;
    if (!MatchPlan::create(
            {},
            group_address.substr(group_address.size() - 10),
            group_plan,
            error)
        || !cuda_mnemonic_launch_search_batch(
            0,
            zero,
            0,
            4,
            group_plan.suffix_modulus,
            group_plan.suffix_remainder,
            error)) {
        clear_test_secret(group_mnemonic);
        cuda_mnemonic_shutdown();
        return false;
    }
    std::uint32_t group_winner = std::numeric_limits<std::uint32_t>::max();
    std::uint8_t* group_master = nullptr;
    if (!cuda_mnemonic_wait_search_batch(
            0,
            group_winner,
            group_master,
            gpu_seconds,
            error)
        || group_winner != 3
        || group_master == nullptr) {
        if (error.empty()) {
            error = "The four-candidate CUDA address cross-check failed.";
        }
        clear_test_secret(group_mnemonic);
        cuda_mnemonic_clear_host(4);
        cuda_mnemonic_shutdown();
        return false;
    }
    std::string verified_group_mnemonic;
    if (!verify_mnemonic_candidate(
            group_entropy,
            impl_->words,
            group_master,
            group_address,
            verified_group_mnemonic,
            error)) {
        clear_test_secret(group_mnemonic);
        clear_test_secret(verified_group_mnemonic);
        cuda_mnemonic_clear_host(4);
        cuda_mnemonic_shutdown();
        return false;
    }
    clear_test_secret(group_mnemonic);
    clear_test_secret(verified_group_mnemonic);
    cuda_mnemonic_clear_host(4);
    impl_->initialized = true;
    emit("INIT\t100\tCUDA + CPU mnemonic engine ready");
    return true;
}

bool MnemonicEngine::search(
    const MatchPlan& plan,
    const std::atomic<bool>& stop_requested,
    const ProtocolEmitter& emit,
    MnemonicSearchOutcome& outcome,
    std::string& error) {
    outcome = {};
    if (!impl_->initialized) {
        error = "The CUDA mnemonic engine is not initialized.";
        return false;
    }

    Entropy128 random_base{};
    if (BCryptGenRandom(
            nullptr,
            random_base.data(),
            static_cast<ULONG>(random_base.size()),
            BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        error = "BCryptGenRandom failed while creating BIP39 entropy.";
        return false;
    }

    const auto started = std::chrono::steady_clock::now();
    auto last_progress = started;
    double total_gpu_seconds = 0;
    double total_cpu_seconds = 0;
    CpuMnemonicSearch cpu_search(impl_->words, plan, stop_requested);
    if (!cpu_search.start(impl_->cpu_workers, error)) {
        secure_zero(random_base.data(), random_base.size());
        return false;
    }
    struct SlotWork {
        bool active = false;
        std::uint64_t first = 0;
        std::uint32_t count = 0;
    } slots[2];
    std::uint64_t next_first = 0;

    const auto launch_slot = [&](unsigned slot) -> bool {
        const auto count = static_cast<std::uint32_t>(impl_->batch_size);
        if (next_first > std::numeric_limits<std::uint64_t>::max() - count) {
            return true;
        }
        if (!cuda_mnemonic_launch_search_batch(
                slot,
                random_base,
                next_first,
                count,
                plan.suffix_modulus,
                plan.suffix_remainder,
                error)) {
            return false;
        }
        slots[slot].active = true;
        slots[slot].first = next_first;
        slots[slot].count = count;
        next_first += count;
        return true;
    };

    if (!launch_slot(0)
        || (!stop_requested.load(std::memory_order_relaxed) && !launch_slot(1))) {
        if (slots[0].active) {
            std::uint32_t ignored_index = 0;
            std::uint8_t* ignored_master = nullptr;
            double ignored_seconds = 0;
            (void)cuda_mnemonic_wait_search_batch(
                0, ignored_index, ignored_master, ignored_seconds, error);
            cuda_mnemonic_clear_slot(0, slots[0].count);
        }
        secure_zero(random_base.data(), random_base.size());
        return false;
    }

    unsigned current_slot = 0;
    while (slots[0].active || slots[1].active) {
        if (!slots[current_slot].active) {
            current_slot ^= 1U;
            continue;
        }
        const auto work = slots[current_slot];
        std::uint32_t winner = std::numeric_limits<std::uint32_t>::max();
        std::uint8_t* winner_master = nullptr;
        double gpu_seconds = 0;
        if (!cuda_mnemonic_wait_search_batch(
                current_slot,
                winner,
                winner_master,
                gpu_seconds,
                error)) {
            secure_zero(random_base.data(), random_base.size());
            return false;
        }
        total_gpu_seconds += gpu_seconds;
        if (!impl_->tuned && gpu_seconds > 0.0) {
            const auto estimated = static_cast<std::size_t>(std::llround(
                static_cast<double>(work.count)
                * impl_->target_kernel_seconds / gpu_seconds));
            const auto conservative = std::max<std::size_t>(
                work.count / 2,
                std::min<std::size_t>(
                    estimated,
                    static_cast<std::size_t>(work.count) * 4));
            const auto adjusted = rounded_batch(conservative, impl_->capacity);
            impl_->tuned = adjusted == impl_->batch_size
                || (gpu_seconds >= impl_->tuned_lower_seconds
                    && gpu_seconds <= impl_->tuned_upper_seconds)
                || adjusted == impl_->capacity;
            impl_->batch_size = adjusted;
        }

        if (winner < work.count) {
            cpu_search.stop_and_join();
            if (winner_master == nullptr) {
                error = "CUDA reported a winner without its BIP32 master key.";
                secure_zero(random_base.data(), random_base.size());
                return false;
            }
            const auto cpu_started = std::chrono::steady_clock::now();
            std::string winner_address;
            if (!derive_tron_address_from_master(
                    winner_master, winner_address, error)
                || !matches(winner_address, plan.prefix, plan.suffix)) {
                if (error.empty()) {
                    error = "The CPU rejected the CUDA TRON suffix match.";
                }
                secure_zero(random_base.data(), random_base.size());
                return false;
            }
            const auto entropy = entropy_at(random_base, work.first + winner);
            std::string verified_mnemonic;
            if (!verify_mnemonic_candidate(
                    entropy,
                    impl_->words,
                    winner_master,
                    winner_address,
                    verified_mnemonic,
                    error)) {
                if (!verified_mnemonic.empty()) {
                    secure_zero(
                        verified_mnemonic.data(), verified_mnemonic.size());
                }
                secure_zero(random_base.data(), random_base.size());
                return false;
            }
            total_cpu_seconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - cpu_started).count();
            cuda_mnemonic_clear_slot(current_slot, work.count);
            slots[current_slot].active = false;

            const unsigned other_slot = current_slot ^ 1U;
            if (slots[other_slot].active) {
                std::uint32_t discarded_index = 0;
                std::uint8_t* discarded_master = nullptr;
                double discarded_seconds = 0;
                if (!cuda_mnemonic_wait_search_batch(
                        other_slot,
                        discarded_index,
                        discarded_master,
                        discarded_seconds,
                        error)) {
                    secure_zero(random_base.data(), random_base.size());
                    return false;
                }
                cuda_mnemonic_clear_slot(other_slot, slots[other_slot].count);
                slots[other_slot].active = false;
            }
            outcome.found = true;
            outcome.address = std::move(winner_address);
            outcome.mnemonic = std::move(verified_mnemonic);
            outcome.derivation_path = kTronDerivationPath;
            outcome.source = "gpu";
            outcome.attempts += static_cast<std::uint64_t>(winner) + 1;
            outcome.attempts += cpu_search.attempts();
            outcome.elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - started).count();
            secure_zero(random_base.data(), random_base.size());
            return true;
        }

        cuda_mnemonic_clear_slot(current_slot, work.count);
        slots[current_slot].active = false;
        outcome.attempts += work.count;

        if (cpu_search.failed() && !cpu_search.claimed_result()) {
            cpu_search.stop_and_join();
            const unsigned other_slot = current_slot ^ 1U;
            if (slots[other_slot].active) {
                std::uint32_t discarded_index = 0;
                std::uint8_t* discarded_master = nullptr;
                double discarded_seconds = 0;
                if (!cuda_mnemonic_wait_search_batch(
                        other_slot,
                        discarded_index,
                        discarded_master,
                        discarded_seconds,
                        error)) {
                    secure_zero(random_base.data(), random_base.size());
                    return false;
                }
                cuda_mnemonic_clear_slot(other_slot, slots[other_slot].count);
                slots[other_slot].active = false;
            }
            error = cpu_search.failure_message();
            if (error.empty()) error = "A CPU mnemonic worker failed.";
            secure_zero(random_base.data(), random_base.size());
            return false;
        }

        if (cpu_search.result_ready()) {
            cpu_search.stop_and_join();
            Entropy128 cpu_entropy{};
            std::string cpu_mnemonic;
            std::string cpu_address;
            if (!cpu_search.copy_result(
                    cpu_entropy, cpu_mnemonic, cpu_address)) {
                error = "The CPU mnemonic result was lost.";
                secure_zero(random_base.data(), random_base.size());
                return false;
            }
            const auto cpu_started = std::chrono::steady_clock::now();
            if (!matches(cpu_address, plan.prefix, plan.suffix)
                || !verify_cpu_mnemonic_candidate(
                    cpu_entropy,
                    impl_->words,
                    cpu_mnemonic,
                    cpu_address,
                    error)) {
                if (error.empty()) {
                    error = "The reference path rejected the CPU mnemonic match.";
                }
                if (!cpu_mnemonic.empty()) {
                    secure_zero(cpu_mnemonic.data(), cpu_mnemonic.size());
                    cpu_mnemonic.clear();
                }
                secure_zero(cpu_entropy.data(), cpu_entropy.size());
                secure_zero(random_base.data(), random_base.size());
                return false;
            }
            total_cpu_seconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - cpu_started).count();

            const unsigned other_slot = current_slot ^ 1U;
            if (slots[other_slot].active) {
                std::uint32_t discarded_index = 0;
                std::uint8_t* discarded_master = nullptr;
                double discarded_seconds = 0;
                if (!cuda_mnemonic_wait_search_batch(
                        other_slot,
                        discarded_index,
                        discarded_master,
                        discarded_seconds,
                        error)) {
                    if (!cpu_mnemonic.empty()) {
                        secure_zero(cpu_mnemonic.data(), cpu_mnemonic.size());
                    }
                    secure_zero(cpu_entropy.data(), cpu_entropy.size());
                    secure_zero(random_base.data(), random_base.size());
                    return false;
                }
                total_gpu_seconds += discarded_seconds;
                outcome.attempts += slots[other_slot].count;
                cuda_mnemonic_clear_slot(other_slot, slots[other_slot].count);
                slots[other_slot].active = false;
            }

            outcome.found = true;
            outcome.address = std::move(cpu_address);
            outcome.mnemonic = std::move(cpu_mnemonic);
            outcome.derivation_path = kTronDerivationPath;
            outcome.source = "cpu";
            outcome.attempts += cpu_search.attempts();
            outcome.elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - started).count();
            secure_zero(cpu_entropy.data(), cpu_entropy.size());
            secure_zero(random_base.data(), random_base.size());
            return true;
        }

        const auto now = std::chrono::steady_clock::now();
        outcome.elapsed = std::chrono::duration<double>(now - started).count();
        if (now - last_progress >= std::chrono::milliseconds(500)) {
            const auto combined_attempts = outcome.attempts
                + cpu_search.attempts();
            const double speed = static_cast<double>(combined_attempts)
                / std::max(outcome.elapsed, 0.001);
            std::ostringstream line;
            line << "PROGRESS\t" << combined_attempts << '\t'
                 << std::fixed << std::setprecision(3) << speed << '\t'
                 << std::setprecision(3) << outcome.elapsed << '\t'
                 << total_gpu_seconds << '\t' << total_cpu_seconds << '\t'
                 << impl_->batch_size << '\t' << outcome.attempts << '\t'
                 << cpu_search.attempts();
            emit(line.str());
            last_progress = now;
        }

        if (!stop_requested.load(std::memory_order_relaxed)) {
            if (!launch_slot(current_slot)) {
                secure_zero(random_base.data(), random_base.size());
                return false;
            }
            if (!slots[current_slot].active
                && !slots[current_slot ^ 1U].active) {
                if (BCryptGenRandom(
                        nullptr,
                        random_base.data(),
                        static_cast<ULONG>(random_base.size()),
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
                    secure_zero(random_base.data(), random_base.size());
                    error = "BCryptGenRandom failed while rotating BIP39 entropy.";
                    return false;
                }
                next_first = 0;
                if (!launch_slot(current_slot)) {
                    secure_zero(random_base.data(), random_base.size());
                    return false;
                }
            }
        }
        current_slot ^= 1U;
    }

    cpu_search.stop_and_join();
    outcome.attempts += cpu_search.attempts();
    outcome.stopped = true;
    outcome.elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - started).count();
    secure_zero(random_base.data(), random_base.size());
    return true;
}

const std::string& MnemonicEngine::device_name() const noexcept {
    return impl_->device;
}

std::size_t MnemonicEngine::batch_capacity() const noexcept {
    return impl_->capacity;
}

std::size_t MnemonicEngine::active_batch_size() const noexcept {
    return impl_->batch_size;
}

unsigned MnemonicEngine::cpu_worker_count() const noexcept {
    return impl_->cpu_workers;
}

unsigned MnemonicEngine::cuda_master_block_size() const noexcept {
    return impl_->master_block_size;
}

unsigned MnemonicEngine::cuda_address_block_size() const noexcept {
    return impl_->address_block_size;
}

MnemonicComputeProfile MnemonicEngine::active_profile() const noexcept {
    return impl_->options.profile;
}

}  // namespace trx
