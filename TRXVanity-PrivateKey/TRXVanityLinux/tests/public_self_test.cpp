#include "crypto.hpp"
#include "match_plan.hpp"
#include "public_crypto.hpp"

#include <iostream>
#include <string>

int main() {
    std::string error;
    if (!trx::encoding_self_test(error)
        || !trx::match_plan_self_test(error)
        || !trx::public_crypto_self_test(error)) {
        std::cerr << "Public-only CPU self-test failed: " << error << '\n';
        return 1;
    }
    std::cout << "SELFTEST\tOK\tPUBLIC_ONLY_CPU\n";
    return 0;
}
