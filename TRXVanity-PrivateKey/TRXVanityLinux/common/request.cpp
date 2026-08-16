#include "request.hpp"

#include <fstream>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <utility>
#include <unistd.h>

namespace trx {

bool read_split_request(
    const std::filesystem::path& path,
    SplitRequest& output,
    std::string& error) {
    std::error_code size_error;
    const auto file_size = std::filesystem::file_size(path, size_error);
    if (size_error || file_size > 4096) {
        error = "The public request file is unavailable or exceeds 4096 bytes.";
        return false;
    }
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        error = "Unable to open the public request file: " + path.string();
        return false;
    }
    std::string header;
    std::string job_line;
    std::string public_line;
    std::string suffix_line;
    std::string extra;
    if (!std::getline(input, header)
        || !std::getline(input, job_line)
        || !std::getline(input, public_line)
        || !std::getline(input, suffix_line)
        || std::getline(input, extra)) {
        error = "The public request file has an invalid number of lines.";
        return false;
    }
    for (auto* line : {&header, &job_line, &public_line, &suffix_line}) {
        if (!line->empty() && line->back() == '\r') line->pop_back();
    }
    static constexpr char kHeader[] = "TRXVANITY-SPLIT-REQUEST-V1";
    static constexpr char kJobPrefix[] = "JOB_ID=";
    static constexpr char kPublicPrefix[] = "BASE_PUBLIC=";
    static constexpr char kSuffixPrefix[] = "SUFFIX=";
    if (header != kHeader
        || job_line.rfind(kJobPrefix, 0) != 0
        || public_line.rfind(kPublicPrefix, 0) != 0
        || suffix_line.rfind(kSuffixPrefix, 0) != 0) {
        error = "The public request file format is invalid.";
        return false;
    }
    SplitRequest parsed;
    parsed.job_id = job_line.substr(sizeof(kJobPrefix) - 1);
    std::array<std::uint8_t, 16> job_bytes{};
    if (!parse_hex_exact(
            parsed.job_id, job_bytes.data(), job_bytes.size(), error)) {
        error = "Invalid JOB_ID: " + error;
        return false;
    }
    if (!parse_hex_exact(
            public_line.substr(sizeof(kPublicPrefix) - 1),
            parsed.base_public.data(),
            parsed.base_public.size(),
            error)) {
        error = "Invalid BASE_PUBLIC: " + error;
        return false;
    }
    parsed.suffix = suffix_line.substr(sizeof(kSuffixPrefix) - 1);
    if (parsed.suffix.empty()) {
        error = "The public request suffix is empty.";
        return false;
    }
    output = std::move(parsed);
    return true;
}

bool write_split_request(
    const std::filesystem::path& path,
    const SplitRequest& request,
    std::string& error) {
    const std::string content =
        "TRXVANITY-SPLIT-REQUEST-V1\nJOB_ID=" + request.job_id
        + "\nBASE_PUBLIC="
        + hex_upper(request.base_public.data(), request.base_public.size())
        + "\nSUFFIX=" + request.suffix + "\n";
    const int descriptor = open(
        path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (descriptor < 0) {
        error = std::string("Unable to create the public request file: ")
            + std::strerror(errno);
        return false;
    }
    if (fchmod(descriptor, 0644) != 0) {
        error = std::string("Unable to set public request permissions: ")
            + std::strerror(errno);
        close(descriptor);
        unlink(path.c_str());
        return false;
    }
    std::size_t written = 0;
    while (written < content.size()) {
        const auto count = write(
            descriptor, content.data() + written, content.size() - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            error = std::string("Unable to write the public request file: ")
                + std::strerror(errno);
            close(descriptor);
            unlink(path.c_str());
            return false;
        }
        written += static_cast<std::size_t>(count);
    }
    const bool synced = fsync(descriptor) == 0;
    const bool closed = close(descriptor) == 0;
    if (!synced || !closed) {
        error = std::string("Unable to finalize the public request file: ")
            + std::strerror(errno);
        unlink(path.c_str());
        return false;
    }
    return true;
}

}  // namespace trx
