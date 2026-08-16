#pragma once

#include "crypto.hpp"

#include <string>

namespace trx {

bool validate_public_key(const PublicKey& input, std::string& error);
bool add_public_tweak(
    const PublicKey& base,
    const Scalar& tweak,
    PublicKey& output,
    std::string& error);
bool public_crypto_self_test(std::string& error);

}  // namespace trx
