#include "opencl_engine.hpp"
#include "opencl_minimal.hpp"

#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>

#include "third_party/profanity2/precomp.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

namespace trx {
namespace {

constexpr std::size_t kInverseSize = 255;
constexpr std::size_t kInverseLocalWorkSize = 128;
constexpr std::size_t kIterateLocalWorkSize = 256;
constexpr std::size_t kResultSlots = 1;
constexpr std::uint64_t kSixSuffixModulus = 38068692544ULL;       // 58^6
constexpr std::uint64_t kSixSuffixOddModulus = 594823321ULL;      // 29^6
constexpr std::uint64_t kMediumSuffixModulus = 2207984167552ULL;  // 58^7
constexpr std::uint64_t kMediumSuffixOddModulus = 17249876309ULL; // 29^7
constexpr std::uint64_t kLongSuffixModulus = 128063081718016ULL;  // 58^8
constexpr std::uint64_t kLongSuffixOddModulus = 500246412961ULL;  // 29^8
constexpr char kBuildOptions[] =
    "-DPROFANITY_INVERSE_SIZE=255 -DPROFANITY_MAX_SCORE=40 -DTRX_ONLY=1";

std::string cl_error(const std::string& operation, cl_int status) {
    return operation + " failed (OpenCL error " + std::to_string(status) + ").";
}

std::string device_string(cl_device_id device, cl_device_info property) {
    std::size_t size = 0;
    if (clGetDeviceInfo(device, property, 0, nullptr, &size) != CL_SUCCESS || size == 0) {
        return {};
    }
    std::vector<char> value(size, 0);
    if (clGetDeviceInfo(device, property, value.size(), value.data(), nullptr) != CL_SUCCESS) {
        return {};
    }
    return std::string(value.data());
}

bool read_file(const std::filesystem::path& path, std::string& output, std::string& error) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        error = "Unable to read OpenCL kernel: " + path.u8string();
        return false;
    }
    stream.seekg(0, std::ios::end);
    const auto length = stream.tellg();
    stream.seekg(0, std::ios::beg);
    if (length < 0) {
        error = "Unable to measure OpenCL kernel: " + path.u8string();
        return false;
    }
    output.resize(static_cast<std::size_t>(length));
    if (!output.empty()) {
        stream.read(&output[0], static_cast<std::streamsize>(output.size()));
    }
    if (!stream) {
        error = "Unable to load the complete OpenCL kernel: " + path.u8string();
        return false;
    }
    return true;
}

std::uint64_t fnv1a(std::uint64_t hash, const void* bytes, std::size_t size) {
    const auto* cursor = static_cast<const std::uint8_t*>(bytes);
    for (std::size_t i = 0; i < size; ++i) {
        hash ^= cursor[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

std::filesystem::path cache_directory() {
    wchar_t local_app_data[MAX_PATH]{};
    const auto length = GetEnvironmentVariableW(
        L"LOCALAPPDATA", local_app_data, static_cast<DWORD>(std::size(local_app_data)));
    std::filesystem::path result = length > 0 && length < std::size(local_app_data)
        ? std::filesystem::path(local_app_data)
        : std::filesystem::temp_directory_path();
    result /= L"TRXVanity";
    result /= L"OpenCLCache";
    std::error_code ignored;
    std::filesystem::create_directories(result, ignored);
    return result;
}

std::uint64_t read_be64(const std::uint8_t* bytes) {
    std::uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i) {
        value = (value << 8U) | bytes[i];
    }
    return value;
}

void write_be64(std::uint64_t value, std::uint8_t* output) {
    for (int i = 7; i >= 0; --i) {
        output[i] = static_cast<std::uint8_t>(value & 0xffU);
        value >>= 8U;
    }
}

cl_ulong4 public_coordinate(const std::uint8_t* big_endian) {
    cl_ulong4 coordinate{};
    coordinate.s[0] = read_be64(big_endian + 24);
    coordinate.s[1] = read_be64(big_endian + 16);
    coordinate.s[2] = read_be64(big_endian + 8);
    coordinate.s[3] = read_be64(big_endian);
    return coordinate;
}

PrivateKey recovered_tweak(
    const cl_ulong4& initial,
    std::uint64_t round,
    std::uint32_t lane) {
    std::uint64_t limbs[4] = {
        initial.s[0], initial.s[1], initial.s[2], initial.s[3]
    };
    const std::uint64_t previous = limbs[0];
    limbs[0] += round;
    std::uint64_t carry = limbs[0] < previous ? 1 : 0;
    for (unsigned i = 1; i < 4 && carry != 0; ++i) {
        const auto before = limbs[i];
        limbs[i] += carry;
        carry = limbs[i] < before ? 1 : 0;
    }
    limbs[3] += static_cast<std::uint64_t>(lane);

    PrivateKey output{};
    write_be64(limbs[3], output.data());
    write_be64(limbs[2], output.data() + 8);
    write_be64(limbs[1], output.data() + 16);
    write_be64(limbs[0], output.data() + 24);
    secure_zero(limbs, sizeof(limbs));
    return output;
}

template <typename T>
bool set_kernel_value(cl_kernel kernel, cl_uint index, const T& value, std::string& error) {
    const auto status = clSetKernelArg(kernel, index, sizeof(T), &value);
    if (status != CL_SUCCESS) {
        error = cl_error("clSetKernelArg(" + std::to_string(index) + ")", status);
        return false;
    }
    return true;
}

bool set_kernel_buffer(
    cl_kernel kernel,
    cl_uint index,
    cl_mem buffer,
    std::string& error) {
    const auto status = clSetKernelArg(kernel, index, sizeof(buffer), &buffer);
    if (status != CL_SUCCESS) {
        error = cl_error("clSetKernelArg(" + std::to_string(index) + ")", status);
        return false;
    }
    return true;
}

}  // namespace

struct OpenClEngine::Impl {
    explicit Impl(std::size_t inverse_multiple_value)
        : inverse_multiple(inverse_multiple_value) {}

    ~Impl() {
        release();
        secure_zero(base_private.data(), base_private.size());
        secure_zero(&seed, sizeof(seed));
    }

    void release() noexcept {
        for (auto* buffer : {
                 &precomp_buffer, &delta_x_buffer, &inverse_buffer,
                 &lambda_buffer, &result_buffer}) {
            if (*buffer != nullptr) {
                clReleaseMemObject(*buffer);
                *buffer = nullptr;
            }
        }
        if (fused_long_kernel != nullptr) {
            clReleaseKernel(fused_long_kernel);
            fused_long_kernel = nullptr;
        }
        if (fused_medium_kernel != nullptr) {
            clReleaseKernel(fused_medium_kernel);
            fused_medium_kernel = nullptr;
        }
        fused_kernel = nullptr;
        if (six_iterate_kernel != nullptr) {
            clReleaseKernel(six_iterate_kernel);
            six_iterate_kernel = nullptr;
        }
        if (short_iterate_kernel != nullptr) {
            clReleaseKernel(short_iterate_kernel);
            short_iterate_kernel = nullptr;
        }
        iterate_kernel = nullptr;
        if (inverse_kernel != nullptr) {
            clReleaseKernel(inverse_kernel);
            inverse_kernel = nullptr;
        }
        if (init_kernel != nullptr) {
            clReleaseKernel(init_kernel);
            init_kernel = nullptr;
        }
        if (program != nullptr) {
            clReleaseProgram(program);
            program = nullptr;
        }
        if (queue != nullptr) {
            clReleaseCommandQueue(queue);
            queue = nullptr;
        }
        if (context != nullptr) {
            clReleaseContext(context);
            context = nullptr;
        }
        device = nullptr;
    }

    bool choose_device(std::string& error) {
        cl_uint platform_count = 0;
        auto status = clGetPlatformIDs(0, nullptr, &platform_count);
        if (status != CL_SUCCESS || platform_count == 0) {
            error = "No OpenCL platform was exposed by the GPU driver.";
            return false;
        }
        std::vector<cl_platform_id> platforms(platform_count);
        status = clGetPlatformIDs(platform_count, platforms.data(), nullptr);
        if (status != CL_SUCCESS) {
            error = cl_error("clGetPlatformIDs", status);
            return false;
        }

        struct Candidate {
            cl_device_id id;
            int score;
            std::string name;
        };
        std::vector<Candidate> candidates;
        for (const auto platform : platforms) {
            cl_uint count = 0;
            status = clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 0, nullptr, &count);
            if (status == CL_DEVICE_NOT_FOUND || count == 0) {
                continue;
            }
            if (status != CL_SUCCESS) {
                continue;
            }
            std::vector<cl_device_id> devices(count);
            if (clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, count, devices.data(), nullptr)
                != CL_SUCCESS) {
                continue;
            }
            for (const auto candidate : devices) {
                const auto name = device_string(candidate, CL_DEVICE_NAME);
                const auto vendor = device_string(candidate, CL_DEVICE_VENDOR);
                int score = 0;
                if (vendor.find("NVIDIA") != std::string::npos) score += 100;
                candidates.push_back({candidate, score, name});
            }
        }
        if (candidates.empty()) {
            error = "No hardware OpenCL GPU was found. The CPU backend is intentionally disabled.";
            return false;
        }
        const auto selected = std::max_element(
            candidates.begin(), candidates.end(), [](const Candidate& lhs, const Candidate& rhs) {
                return lhs.score < rhs.score;
            });
        device = selected->id;
        device_name = selected->name;
        driver_version = device_string(device, CL_DRIVER_VERSION);
        clGetDeviceInfo(
            device,
            CL_DEVICE_MAX_COMPUTE_UNITS,
            sizeof(compute_units),
            &compute_units,
            nullptr);
        clGetDeviceInfo(
            device,
            CL_DEVICE_GLOBAL_MEM_SIZE,
            sizeof(global_memory),
            &global_memory,
            nullptr);
        clGetDeviceInfo(
            device,
            CL_DEVICE_MAX_MEM_ALLOC_SIZE,
            sizeof(max_allocation),
            &max_allocation,
            nullptr);
        return true;
    }

    bool configure_lanes(bool& automatic, std::string& error) {
        automatic = inverse_multiple == 0;
        if (automatic) {
            constexpr std::size_t kMinimumMultiple = 16384;
            const auto target = std::max<std::uint64_t>(
                kMinimumMultiple,
                static_cast<std::uint64_t>(compute_units) * 4096ULL);
            inverse_multiple = kMinimumMultiple;
            while (inverse_multiple < target
                   && inverse_multiple <= std::numeric_limits<std::size_t>::max() / 2) {
                inverse_multiple *= 2;
            }

            // The three persistent field buffers together may use at most 60%
            // of VRAM. Larger batches measurably improve occupancy on high-end
            // GPUs while still leaving substantial headroom for the desktop.
            auto fits_device = [&](std::size_t multiple) {
                if (multiple > std::numeric_limits<cl_uint>::max() / kInverseSize) {
                    return false;
                }
                const auto lane_count = static_cast<std::uint64_t>(multiple) * kInverseSize;
                const auto scalar_bytes = lane_count * sizeof(mp_number);
                return (max_allocation == 0 || scalar_bytes <= max_allocation)
                    && (global_memory == 0 || scalar_bytes <= global_memory / 5ULL);
            };
            while (inverse_multiple > kInverseLocalWorkSize
                   && !fits_device(inverse_multiple)) {
                inverse_multiple /= 2;
            }
            if (!fits_device(inverse_multiple)) {
                error = "The GPU does not expose enough memory for the minimum search batch.";
                return false;
            }
        }

        if (inverse_multiple == 0
            || inverse_multiple > std::numeric_limits<std::size_t>::max() / kInverseSize) {
            error = "The GPU lane configuration is invalid.";
            return false;
        }
        lanes = kInverseSize * inverse_multiple;
        if (inverse_multiple % kInverseLocalWorkSize != 0
            || lanes % kIterateLocalWorkSize != 0
            || lanes > std::numeric_limits<cl_uint>::max()) {
            error = "The GPU lane configuration is invalid.";
            return false;
        }
        return true;
    }

    bool build_program(
        const std::filesystem::path& executable_directory,
        const ProtocolEmitter& emit,
        std::string& error) {
        const auto kernel_directory = executable_directory / L"kernels";
        std::string keccak;
        std::string profanity;
        std::string tron;
        if (!read_file(kernel_directory / L"keccak.cl", keccak, error)
            || !read_file(kernel_directory / L"profanity.cl", profanity, error)
            || !read_file(kernel_directory / L"tron.cl", tron, error)) {
            return false;
        }
        std::string source;
        source.reserve(keccak.size() + profanity.size() + tron.size() + 3);
        source += keccak;
        source += '\n';
        source += profanity;
        source += '\n';
        source += tron;
        source += '\n';

        std::uint64_t hash = 1469598103934665603ULL;
        hash = fnv1a(hash, source.data(), source.size());
        hash = fnv1a(hash, kBuildOptions, sizeof(kBuildOptions) - 1);
        hash = fnv1a(hash, device_name.data(), device_name.size());
        hash = fnv1a(hash, driver_version.data(), driver_version.size());
        std::ostringstream cache_name;
        cache_name << "trx-opencl-" << std::hex << std::setfill('0') << std::setw(16) << hash << ".bin";
        const auto cache_path = cache_directory() / cache_name.str();

        cl_int status = CL_SUCCESS;
        bool loaded_cache = false;
        std::ifstream cached(cache_path, std::ios::binary);
        if (cached) {
            cached.seekg(0, std::ios::end);
            const auto length = cached.tellg();
            cached.seekg(0, std::ios::beg);
            if (length > 0) {
                std::vector<unsigned char> binary(static_cast<std::size_t>(length));
                cached.read(
                    reinterpret_cast<char*>(binary.data()),
                    static_cast<std::streamsize>(length));
                const unsigned char* binary_pointer = binary.data();
                const std::size_t binary_size = binary.size();
                cl_int binary_status = CL_SUCCESS;
                program = clCreateProgramWithBinary(
                    context,
                    1,
                    &device,
                    &binary_size,
                    &binary_pointer,
                    &binary_status,
                    &status);
                loaded_cache = program != nullptr
                    && status == CL_SUCCESS
                    && binary_status == CL_SUCCESS;
                if (!loaded_cache && program != nullptr) {
                    clReleaseProgram(program);
                    program = nullptr;
                }
            }
        }

        if (!loaded_cache) {
            emit("INIT\t3\tCompiling optimized OpenCL kernels");
            const char* pointer = source.data();
            const std::size_t length = source.size();
            program = clCreateProgramWithSource(context, 1, &pointer, &length, &status);
            if (program == nullptr || status != CL_SUCCESS) {
                error = cl_error("clCreateProgramWithSource", status);
                return false;
            }
        } else {
            emit("INIT\t3\tLoading cached OpenCL kernels");
        }

        status = clBuildProgram(program, 1, &device, kBuildOptions, nullptr, nullptr);
        if (status != CL_SUCCESS) {
            std::size_t log_size = 0;
            clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG, 0, nullptr, &log_size);
            std::vector<char> log(log_size + 1, 0);
            clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG, log_size, log.data(), nullptr);
            error = "OpenCL kernel compilation failed: " + std::string(log.data());
            return false;
        }

        if (!loaded_cache) {
            std::size_t binary_size = 0;
            if (clGetProgramInfo(
                    program, CL_PROGRAM_BINARY_SIZES, sizeof(binary_size), &binary_size, nullptr)
                    == CL_SUCCESS
                && binary_size != 0) {
                std::vector<unsigned char> binary(binary_size);
                unsigned char* binary_pointer = binary.data();
                if (clGetProgramInfo(
                        program,
                        CL_PROGRAM_BINARIES,
                        sizeof(binary_pointer),
                        &binary_pointer,
                        nullptr) == CL_SUCCESS) {
                    std::ofstream output(cache_path, std::ios::binary | std::ios::trunc);
                    output.write(
                        reinterpret_cast<const char*>(binary.data()),
                        static_cast<std::streamsize>(binary.size()));
                }
            }
        }
        return true;
    }

    bool create_buffer(
        cl_mem& output,
        cl_mem_flags flags,
        std::size_t bytes,
        void* host,
        const char* label,
        std::string& error) {
        cl_int status = CL_SUCCESS;
        output = clCreateBuffer(context, flags, std::max<std::size_t>(bytes, 1), host, &status);
        if (output == nullptr || status != CL_SUCCESS) {
            error = cl_error(std::string("clCreateBuffer(") + label + ")", status);
            return false;
        }
        return true;
    }

    bool allocate_buffers(std::string& error) {
        const auto scalar_bytes = lanes * sizeof(mp_number);
        return create_buffer(
                   precomp_buffer,
                   CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
                   sizeof(g_precomp),
                   g_precomp,
                   "precompute table",
                   error)
            && create_buffer(delta_x_buffer, CL_MEM_READ_WRITE, scalar_bytes, nullptr, "delta-x", error)
            && create_buffer(inverse_buffer, CL_MEM_READ_WRITE, scalar_bytes, nullptr, "inverse", error)
            && create_buffer(lambda_buffer, CL_MEM_READ_WRITE, scalar_bytes, nullptr, "lambda", error)
            && create_buffer(
                result_buffer,
                CL_MEM_READ_WRITE,
                kResultSlots * sizeof(result),
                nullptr,
                "result",
                error);
    }

    bool set_static_arguments(const PublicKey& public_key_value, std::string& error) {
        const auto x = public_coordinate(public_key_value.data() + 1);
        const auto y = public_coordinate(public_key_value.data() + 33);

        return set_kernel_buffer(init_kernel, 0, precomp_buffer, error)
            && set_kernel_buffer(init_kernel, 1, delta_x_buffer, error)
            && set_kernel_buffer(init_kernel, 2, lambda_buffer, error)
            && set_kernel_buffer(init_kernel, 3, result_buffer, error)
            && set_kernel_value(init_kernel, 4, seed, error)
            && set_kernel_value(init_kernel, 5, x, error)
            && set_kernel_value(init_kernel, 6, y, error)
            && set_kernel_buffer(inverse_kernel, 0, delta_x_buffer, error)
            && set_kernel_buffer(inverse_kernel, 1, inverse_buffer, error)
            && set_kernel_buffer(short_iterate_kernel, 0, delta_x_buffer, error)
            && set_kernel_buffer(short_iterate_kernel, 1, inverse_buffer, error)
            && set_kernel_buffer(short_iterate_kernel, 2, lambda_buffer, error)
            && set_kernel_buffer(short_iterate_kernel, 3, result_buffer, error)
            && set_kernel_buffer(six_iterate_kernel, 0, delta_x_buffer, error)
            && set_kernel_buffer(six_iterate_kernel, 1, inverse_buffer, error)
            && set_kernel_buffer(six_iterate_kernel, 2, lambda_buffer, error)
            && set_kernel_buffer(six_iterate_kernel, 3, result_buffer, error)
            && set_kernel_buffer(fused_long_kernel, 0, delta_x_buffer, error)
            && set_kernel_buffer(fused_long_kernel, 1, lambda_buffer, error)
            && set_kernel_buffer(fused_long_kernel, 2, result_buffer, error)
            && set_kernel_buffer(fused_medium_kernel, 0, delta_x_buffer, error)
            && set_kernel_buffer(fused_medium_kernel, 1, lambda_buffer, error)
            && set_kernel_buffer(fused_medium_kernel, 2, result_buffer, error);
    }

    bool initialize_points(const ProtocolEmitter& emit, std::string& error) {
        const std::size_t chunk = lanes / 20;
        for (std::size_t index = 0; index < 20; ++index) {
            const std::size_t offset = index * chunk;
            const std::size_t count = index == 19 ? lanes - offset : chunk;
            const auto status = clEnqueueNDRangeKernel(
                queue, init_kernel, 1, &offset, &count, nullptr, 0, nullptr, nullptr);
            if (status != CL_SUCCESS) {
                error = cl_error("GPU point initialization", status);
                return false;
            }
            if (clFinish(queue) != CL_SUCCESS) {
                error = "The GPU failed while initializing public curve points.";
                return false;
            }
            const unsigned percent = 5 + static_cast<unsigned>((index + 1) * 95 / 20);
            emit("INIT\t" + std::to_string(percent)
                + "\tInitializing public GPU lanes");
        }
        return true;
    }

    bool upload_plan(const MatchPlan& plan, std::string& error) {
        const cl_ulong modulus = plan.suffix_modulus;
        const cl_ulong remainder = plan.suffix_remainder;
        fused_iteration = false;
        fused_kernel = nullptr;
        iterate_kernel = short_iterate_kernel;
        if (modulus >= kLongSuffixModulus) {
            fused_iteration = true;
            fused_kernel = fused_long_kernel;
            const cl_ulong target_quotient =
                (plan.suffix_remainder >> 8U) % kLongSuffixOddModulus;
            return set_kernel_value(fused_long_kernel, 3, modulus, error)
                && set_kernel_value(fused_long_kernel, 4, remainder, error)
                && set_kernel_value(fused_long_kernel, 5, target_quotient, error);
        }
        if (modulus >= kMediumSuffixModulus) {
            fused_iteration = true;
            fused_kernel = fused_medium_kernel;
            const cl_ulong target_quotient =
                (plan.suffix_remainder >> 7U) % kMediumSuffixOddModulus;
            return set_kernel_value(fused_kernel, 3, modulus, error)
                && set_kernel_value(fused_kernel, 4, remainder, error)
                && set_kernel_value(fused_kernel, 5, target_quotient, error);
        }
        if (modulus >= kSixSuffixModulus) {
            iterate_kernel = six_iterate_kernel;
            const cl_ulong target_quotient =
                (plan.suffix_remainder >> 6U) % kSixSuffixOddModulus;
            return set_kernel_value(iterate_kernel, 4, modulus, error)
                && set_kernel_value(iterate_kernel, 5, remainder, error)
                && set_kernel_value(iterate_kernel, 6, target_quotient, error);
        }
        const cl_uint probe = plan.suffix_probe_target;
        return set_kernel_value(iterate_kernel, 4, modulus, error)
            && set_kernel_value(iterate_kernel, 5, remainder, error)
            && set_kernel_value(iterate_kernel, 6, probe, error);
    }

    bool recover(
        const result& gpu_result,
        const MatchPlan& plan,
        std::string& address,
        std::string& private_hex,
        std::string& error) {
        // profanity_init advances each lane once while constructing its
        // batch-inversion state. The first dispatched iterate therefore
        // hashes seed + lane + 2, not seed + lane + 1.
        const auto scalar_round = round + 1;
        auto tweak = recovered_tweak(seed, scalar_round, gpu_result.foundId);
        PrivateKey candidate{};
        const bool added = add_tweak(base_private, tweak, candidate, error);
        if (!added) {
            secure_zero(tweak.data(), tweak.size());
            return false;
        }
        PublicKey diagnostic_public{};
        if (!public_key(candidate, diagnostic_public, error)) {
            secure_zero(tweak.data(), tweak.size());
            secure_zero(candidate.data(), candidate.size());
            return false;
        }
        std::array<std::uint8_t, 32> diagnostic_hash{};
        if (!tron_address_from_public_key(
                diagnostic_public, address, diagnostic_hash, error)) {
            secure_zero(diagnostic_public.data(), diagnostic_public.size());
            secure_zero(tweak.data(), tweak.size());
            secure_zero(candidate.data(), candidate.size());
            return false;
        }
        secure_zero(diagnostic_public.data(), diagnostic_public.size());
        if (std::memcmp(
                diagnostic_hash.data() + 12,
                gpu_result.foundHash,
                sizeof(gpu_result.foundHash)) != 0) {
            std::string diagnostic_match = "none";
            auto check_key = [&](const PrivateKey& key, const char* label) {
                PublicKey pub{};
                std::string ignored;
                if (!public_key(key, pub, ignored)) return;
                const auto hash = keccak256(pub.data() + 1, 64);
                secure_zero(pub.data(), pub.size());
                if (std::memcmp(hash.data() + 12, gpu_result.foundHash, 20) == 0) {
                    diagnostic_match = label;
                }
            };
            check_key(tweak, "tweak-without-base");
            for (int delta_round : {-1, 1}) {
                if (delta_round < 0 && scalar_round == 0) continue;
                const auto alternative_round = delta_round < 0
                    ? scalar_round - 1
                    : scalar_round + 1;
                auto alternative_tweak = recovered_tweak(
                    seed, alternative_round, gpu_result.foundId);
                PrivateKey alternative{};
                std::string ignored;
                if (add_tweak(base_private, alternative_tweak, alternative, ignored)) {
                    check_key(alternative, delta_round < 0 ? "round-minus-one" : "round-plus-one");
                }
                secure_zero(alternative_tweak.data(), alternative_tweak.size());
                secure_zero(alternative.data(), alternative.size());
            }
            secure_zero(tweak.data(), tweak.size());
            secure_zero(candidate.data(), candidate.size());
            error = "GPU/CPU public-point recovery mismatch at lane "
                + std::to_string(gpu_result.foundId)
                + ", round " + std::to_string(round)
                + "; GPU hash=" + hex_upper(gpu_result.foundHash, sizeof(gpu_result.foundHash))
                + ", CPU hash=" + hex_upper(diagnostic_hash.data() + 12, 20)
                + ", alternative=" + diagnostic_match + ".";
            return false;
        }
        if (!matches(address, plan.prefix, plan.suffix)) {
            secure_zero(tweak.data(), tweak.size());
            secure_zero(candidate.data(), candidate.size());
            error = "GPU matcher false positive for independently verified address "
                + address + "; no private key was released.";
            return false;
        }
        private_hex = hex_upper(candidate.data(), candidate.size());
        secure_zero(tweak.data(), tweak.size());
        secure_zero(candidate.data(), candidate.size());
        return true;
    }

    std::size_t inverse_multiple;
    std::size_t lanes = 0;
    cl_uint compute_units = 0;
    cl_ulong global_memory = 0;
    cl_ulong max_allocation = 0;
    std::string device_name;
    std::string driver_version;
    std::uint64_t round = 0;
    PrivateKey base_private{};
    cl_ulong4 seed{};

    cl_device_id device = nullptr;
    cl_context context = nullptr;
    cl_command_queue queue = nullptr;
    cl_program program = nullptr;
    cl_kernel init_kernel = nullptr;
    cl_kernel inverse_kernel = nullptr;
    cl_kernel short_iterate_kernel = nullptr;
    cl_kernel six_iterate_kernel = nullptr;
    cl_kernel fused_medium_kernel = nullptr;
    cl_kernel fused_long_kernel = nullptr;
    cl_kernel fused_kernel = nullptr;
    cl_kernel iterate_kernel = nullptr;
    bool fused_iteration = false;
    cl_mem precomp_buffer = nullptr;
    cl_mem delta_x_buffer = nullptr;
    cl_mem inverse_buffer = nullptr;
    cl_mem lambda_buffer = nullptr;
    cl_mem result_buffer = nullptr;
};

OpenClEngine::OpenClEngine(std::size_t inverse_multiple)
    : impl_(std::make_unique<Impl>(inverse_multiple)) {}

OpenClEngine::~OpenClEngine() = default;

bool OpenClEngine::initialize(
    const std::wstring& executable_directory,
    const ProtocolEmitter& emit,
    std::string& error) {
    if (!impl_->choose_device(error)) {
        return false;
    }
    emit("INIT\t1\tSelected " + impl_->device_name);
    bool automatic = false;
    if (!impl_->configure_lanes(automatic, error)) {
        return false;
    }
    if (automatic) {
        emit("INIT\t2\tConfigured " + std::to_string(impl_->lanes) + " GPU lanes");
    }

    cl_int status = CL_SUCCESS;
    impl_->context = clCreateContext(nullptr, 1, &impl_->device, nullptr, nullptr, &status);
    if (impl_->context == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateContext", status);
        return false;
    }
    impl_->queue = clCreateCommandQueue(impl_->context, impl_->device, 0, &status);
    if (impl_->queue == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateCommandQueue", status);
        return false;
    }
    if (!impl_->build_program(std::filesystem::path(executable_directory), emit, error)) {
        return false;
    }

    impl_->init_kernel = clCreateKernel(impl_->program, "profanity_init", &status);
    if (impl_->init_kernel == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateKernel(profanity_init)", status);
        return false;
    }
    impl_->inverse_kernel = clCreateKernel(impl_->program, "profanity_inverse", &status);
    if (impl_->inverse_kernel == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateKernel(profanity_inverse)", status);
        return false;
    }
    impl_->short_iterate_kernel = clCreateKernel(impl_->program, "trx_iterate_short", &status);
    if (impl_->short_iterate_kernel == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateKernel(trx_iterate_short)", status);
        return false;
    }
    impl_->six_iterate_kernel = clCreateKernel(impl_->program, "trx_iterate_six", &status);
    if (impl_->six_iterate_kernel == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateKernel(trx_iterate_six)", status);
        return false;
    }
    impl_->fused_long_kernel = clCreateKernel(
        impl_->program, "trx_inverse_iterate_long", &status);
    if (impl_->fused_long_kernel == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateKernel(trx_inverse_iterate_long)", status);
        return false;
    }
    impl_->fused_medium_kernel = clCreateKernel(
        impl_->program, "trx_inverse_iterate_medium", &status);
    if (impl_->fused_medium_kernel == nullptr || status != CL_SUCCESS) {
        error = cl_error("clCreateKernel(trx_inverse_iterate_medium)", status);
        return false;
    }
    impl_->iterate_kernel = impl_->short_iterate_kernel;
    if (!impl_->allocate_buffers(error)) {
        return false;
    }
    if (!random_private_key(impl_->base_private, error)) {
        return false;
    }
    PublicKey pub{};
    if (!public_key(impl_->base_private, pub, error)) {
        return false;
    }
    if (BCryptGenRandom(
            nullptr,
            reinterpret_cast<PUCHAR>(&impl_->seed),
            static_cast<ULONG>(sizeof(impl_->seed)),
            BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        secure_zero(pub.data(), pub.size());
        error = "BCryptGenRandom failed while creating the public GPU walk offset.";
        return false;
    }
    // Keep the public walk offset below 2^240. Adding a 32-bit lane ID to the
    // high limb can therefore never overflow, and the tweak remains below n.
    impl_->seed.s[3] &= 0x0000FFFFFFFFFFFFULL;

    if (!impl_->set_static_arguments(pub, error)) {
        secure_zero(pub.data(), pub.size());
        return false;
    }
    secure_zero(pub.data(), pub.size());

    result empty{};
    status = clEnqueueWriteBuffer(
        impl_->queue,
        impl_->result_buffer,
        CL_TRUE,
        0,
        sizeof(empty),
        &empty,
        0,
        nullptr,
        nullptr);
    if (status != CL_SUCCESS) {
        error = cl_error("Clearing GPU result memory", status);
        return false;
    }
    if (!impl_->initialize_points(emit, error)) {
        return false;
    }
    return true;
}

bool OpenClEngine::search(
    const MatchPlan& plan,
    const std::atomic<bool>& stop_requested,
    const ProtocolEmitter& emit,
    SearchOutcome& outcome,
    std::string& error,
    std::uint64_t maximum_batches) {
    outcome = {};
    if (!impl_->upload_plan(plan, error)) {
        return false;
    }

    result gpu_result{};
    auto status = clEnqueueWriteBuffer(
        impl_->queue,
        impl_->result_buffer,
        CL_TRUE,
        0,
        sizeof(gpu_result),
        &gpu_result,
        0,
        nullptr,
        nullptr);
    if (status != CL_SUCCESS) {
        error = cl_error("Resetting GPU result memory", status);
        return false;
    }

    const auto started = std::chrono::steady_clock::now();
    auto last_progress = started;
    const std::size_t inverse_global = impl_->inverse_multiple;
    const std::size_t iterate_global = impl_->lanes;
    const std::size_t inverse_local = kInverseLocalWorkSize;
    const std::size_t iterate_local = kIterateLocalWorkSize;
    std::uint64_t dispatched_batches = 0;

    while (!stop_requested.load(std::memory_order_relaxed)) {
        if (impl_->fused_iteration) {
            status = clEnqueueNDRangeKernel(
                impl_->queue,
                impl_->fused_kernel,
                1,
                nullptr,
                &inverse_global,
                &inverse_local,
                0,
                nullptr,
                nullptr);
        } else {
            status = clEnqueueNDRangeKernel(
                impl_->queue,
                impl_->inverse_kernel,
                1,
                nullptr,
                &inverse_global,
                &inverse_local,
                0,
                nullptr,
                nullptr);
            if (status == CL_SUCCESS) {
                status = clEnqueueNDRangeKernel(
                    impl_->queue,
                    impl_->iterate_kernel,
                    1,
                    nullptr,
                    &iterate_global,
                    &iterate_local,
                    0,
                    nullptr,
                    nullptr);
            }
        }
        if (status != CL_SUCCESS) {
            error = cl_error("Dispatching the GPU search kernels", status);
            return false;
        }
        status = clEnqueueReadBuffer(
            impl_->queue,
            impl_->result_buffer,
            CL_TRUE,
            0,
            sizeof(gpu_result),
            &gpu_result,
            0,
            nullptr,
            nullptr);
        if (status != CL_SUCCESS) {
            error = cl_error("Reading the GPU search result", status);
            return false;
        }

        ++impl_->round;
        ++dispatched_batches;
        if (std::numeric_limits<std::uint64_t>::max() - outcome.attempts < impl_->lanes) {
            error = "The displayed attempt counter overflowed.";
            return false;
        }
        outcome.attempts += static_cast<std::uint64_t>(impl_->lanes);
        const auto now = std::chrono::steady_clock::now();
        outcome.elapsed = std::chrono::duration<double>(now - started).count();

        if (gpu_result.found != 0) {
            if (!impl_->recover(
                    gpu_result,
                    plan,
                    outcome.address,
                    outcome.private_key,
                    error)) {
                return false;
            }
            outcome.found = true;
            return true;
        }

        if (maximum_batches != 0 && dispatched_batches >= maximum_batches) {
            outcome.stopped = true;
            return true;
        }

        if (now - last_progress >= std::chrono::milliseconds(180)) {
            const double speed = static_cast<double>(outcome.attempts)
                / std::max(outcome.elapsed, 0.001);
            std::ostringstream line;
            line << "PROGRESS\t" << outcome.attempts << '\t'
                 << std::fixed << std::setprecision(3) << speed << '\t'
                 << std::setprecision(3) << outcome.elapsed;
            emit(line.str());
            last_progress = now;
        }
    }

    outcome.stopped = true;
    outcome.elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - started).count();
    return true;
}

bool OpenClEngine::long_suffix_self_test(
    const ProtocolEmitter& emit,
    std::string& error) {
    static constexpr std::size_t lengths[] = {6, 7, 10};
    std::atomic<bool> stop{false};

    for (const auto length : lengths) {
        if (impl_->round > std::numeric_limits<std::uint64_t>::max() - 2) {
            error = "The GPU walk counter is too close to overflow for self-test.";
            return false;
        }
        auto tweak = recovered_tweak(impl_->seed, impl_->round + 2, 0);
        PrivateKey candidate{};
        if (!add_tweak(impl_->base_private, tweak, candidate, error)) {
            secure_zero(tweak.data(), tweak.size());
            return false;
        }
        std::string expected_address;
        if (!tron_address(candidate, expected_address, error)) {
            secure_zero(tweak.data(), tweak.size());
            secure_zero(candidate.data(), candidate.size());
            return false;
        }
        secure_zero(tweak.data(), tweak.size());
        secure_zero(candidate.data(), candidate.size());

        const auto suffix = expected_address.substr(expected_address.size() - length);
        MatchPlan plan;
        if (!MatchPlan::create({}, suffix, plan, error)) {
            return false;
        }
        SearchOutcome outcome;
        if (!search(plan, stop, emit, outcome, error, 1)) {
            return false;
        }
        const bool valid = outcome.found && matches(outcome.address, {}, suffix);
        if (!outcome.private_key.empty()) {
            secure_zero(&outcome.private_key[0], outcome.private_key.size());
            outcome.private_key.clear();
        }
        if (!valid) {
            error = "The deterministic long-suffix GPU self-test missed its forced candidate.";
            return false;
        }
        emit("SELFTEST_LONG\t" + std::to_string(length) + "\t"
            + std::to_string(outcome.attempts));
    }
    return true;
}

const std::string& OpenClEngine::device_name() const noexcept {
    return impl_->device_name;
}

std::size_t OpenClEngine::lane_count() const noexcept {
    return impl_->lanes;
}

}  // namespace trx
