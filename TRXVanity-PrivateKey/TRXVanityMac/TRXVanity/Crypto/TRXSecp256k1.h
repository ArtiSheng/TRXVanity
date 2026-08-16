#ifndef TRX_SECP256K1_BRIDGE_H
#define TRX_SECP256K1_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns 1 when `private_key` is a valid secp256k1 scalar.
int trx_secp256k1_verify_secret(const uint8_t private_key[32]);

/// Serializes the public key as 0x04 || X || Y. Returns 1 on success.
int trx_secp256k1_public_key(const uint8_t private_key[32],
                            uint8_t public_key_uncompressed[65]);

/// Computes private_key + offset modulo the secp256k1 group order.
/// Offset zero is accepted. Returns 1 on success and never mutates the input.
int trx_secp256k1_add_u64(const uint8_t private_key[32],
                         uint64_t offset,
                         uint8_t output_private_key[32]);

/// Adds the offset and serializes the resulting public key in one call.
int trx_secp256k1_public_key_at_offset(const uint8_t private_key[32],
                                      uint64_t offset,
                                      uint8_t output_private_key[32],
                                      uint8_t public_key_uncompressed[65]);

/// Computes base + (step * index) modulo the group order. The two input
/// scalars remain CPU-only; callers should expose only the resulting point.
int trx_secp256k1_linear_combination(const uint8_t base_private_key[32],
                                    const uint8_t step_private_key[32],
                                    uint64_t index,
                                    uint8_t output_private_key[32]);

int trx_secp256k1_public_key_at_linear_index(const uint8_t base_private_key[32],
                                             const uint8_t step_private_key[32],
                                             uint64_t index,
                                             uint8_t output_private_key[32],
                                             uint8_t public_key_uncompressed[65]);

/// Best-effort explicit zeroing that the compiler must not optimize away.
void trx_secure_zero(void *bytes, uint64_t count);

#ifdef __cplusplus
}
#endif

#endif
