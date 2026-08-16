#pragma once

#include "crypto.hpp"

#include <filesystem>
#include <string>

namespace trx {

struct SplitRequest {
    std::string job_id;
    PublicKey base_public{};
    std::string suffix;
};

bool read_split_request(
    const std::filesystem::path& path,
    SplitRequest& output,
    std::string& error);
bool write_split_request(
    const std::filesystem::path& path,
    const SplitRequest& request,
    std::string& error);

}  // namespace trx
