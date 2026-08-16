#pragma once

#include <cstddef>
#include <string>

namespace trx {

// The server uses this only for a public GPU walk offset. It is never key material.
bool random_public_bytes(void* output, std::size_t size, std::string& error);

}  // namespace trx
