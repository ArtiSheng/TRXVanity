#include "random.hpp"

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace trx {

bool random_public_bytes(void* output, std::size_t size, std::string& error) {
    const int descriptor = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        error = std::string("Unable to open /dev/urandom: ") + std::strerror(errno);
        return false;
    }
    auto* cursor = static_cast<std::uint8_t*>(output);
    std::size_t remaining = size;
    while (remaining != 0) {
        const auto received = read(descriptor, cursor, remaining);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) {
            error = received == 0
                ? "Unexpected end of /dev/urandom."
                : std::string("Unable to read /dev/urandom: ") + std::strerror(errno);
            close(descriptor);
            return false;
        }
        cursor += static_cast<std::size_t>(received);
        remaining -= static_cast<std::size_t>(received);
    }
    if (close(descriptor) != 0) {
        error = std::string("Unable to close /dev/urandom: ") + std::strerror(errno);
        return false;
    }
    return true;
}

}  // namespace trx
