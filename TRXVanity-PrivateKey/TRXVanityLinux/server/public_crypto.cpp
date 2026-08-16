#include "public_crypto.hpp"

#include <secp256k1.h>

namespace trx {
namespace {

struct PublicContext {
    secp256k1_context* value = secp256k1_context_create(SECP256K1_CONTEXT_NONE);

    ~PublicContext() {
        if (value != nullptr) secp256k1_context_destroy(value);
    }
};

secp256k1_context* context() {
    static PublicContext holder;
    return holder.value;
}

bool parse_public(
    const PublicKey& input,
    secp256k1_pubkey& output,
    std::string& error) {
    auto* ctx = context();
    if (ctx == nullptr) {
        error = "Unable to create the secp256k1 public-key context.";
        return false;
    }
    if (input[0] != 0x04
        || secp256k1_ec_pubkey_parse(ctx, &output, input.data(), input.size()) != 1) {
        error = "BASE_PUBLIC is not a valid uncompressed secp256k1 public key.";
        return false;
    }
    return true;
}

}  // namespace

bool validate_public_key(const PublicKey& input, std::string& error) {
    secp256k1_pubkey parsed{};
    return parse_public(input, parsed, error);
}

bool add_public_tweak(
    const PublicKey& base,
    const Scalar& tweak,
    PublicKey& output,
    std::string& error) {
    secp256k1_pubkey parsed{};
    if (!parse_public(base, parsed, error)) return false;
    auto* ctx = context();
    if (secp256k1_ec_pubkey_tweak_add(ctx, &parsed, tweak.data()) != 1) {
        error = "The public GPU search offset is outside the secp256k1 group.";
        return false;
    }
    std::size_t output_size = output.size();
    if (secp256k1_ec_pubkey_serialize(
            ctx,
            output.data(),
            &output_size,
            &parsed,
            SECP256K1_EC_UNCOMPRESSED) != 1
        || output_size != output.size()) {
        secure_zero(output.data(), output.size());
        error = "Unable to serialize the recovered public key.";
        return false;
    }
    return true;
}

bool public_crypto_self_test(std::string& error) {
    static constexpr char kGenerator[] =
        "0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"
        "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8";
    static constexpr char kTwiceGenerator[] =
        "04C6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5"
        "1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A";
    PublicKey generator{};
    if (!parse_hex_exact(kGenerator, generator.data(), generator.size(), error)
        || !validate_public_key(generator, error)) {
        return false;
    }
    std::string generator_address;
    std::array<std::uint8_t, 32> generator_hash{};
    if (!tron_address_from_public_key(
            generator, generator_address, generator_hash, error)
        || generator_address != "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC") {
        error = "TRON public-generator address vector failed.";
        return false;
    }
    Scalar zero{};
    PublicKey unchanged{};
    if (!add_public_tweak(generator, zero, unchanged, error)
        || unchanged != generator) {
        error = "secp256k1 zero public tweak vector failed.";
        return false;
    }
    Scalar one{};
    one.back() = 1;
    PublicKey doubled{};
    if (!add_public_tweak(generator, one, doubled, error)) return false;
    if (hex_upper(doubled.data(), doubled.size()) != kTwiceGenerator) {
        error = "secp256k1 public tweak-add vector failed.";
        return false;
    }
    PublicKey invalid = generator;
    invalid[0] = 0x05;
    if (validate_public_key(invalid, error)) {
        error = "An invalid public-key prefix was accepted.";
        return false;
    }
    Scalar curve_order{};
    if (!parse_hex_exact(
            "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141",
            curve_order.data(),
            curve_order.size(),
            error)) {
        return false;
    }
    PublicKey rejected{};
    if (add_public_tweak(generator, curve_order, rejected, error)) {
        error = "A public tweak equal to the secp256k1 group order was accepted.";
        return false;
    }
    error.clear();
    return true;
}

}  // namespace trx
