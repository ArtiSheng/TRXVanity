#include "TRXSecp256k1.h"

#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

#include "secp256k1.h"

static secp256k1_context *trx_context = NULL;
static dispatch_once_t trx_context_once;

static secp256k1_context *trx_get_context(void) {
    dispatch_once(&trx_context_once, ^{
        trx_context = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
        if (trx_context != NULL) {
            uint8_t seed[32];
            arc4random_buf(seed, sizeof(seed));
            (void)secp256k1_context_randomize(trx_context, seed);
            trx_secure_zero(seed, sizeof(seed));
        }
    });
    return trx_context;
}

void trx_secure_zero(void *bytes, uint64_t count) {
    volatile uint8_t *cursor = (volatile uint8_t *)bytes;
    while (count-- > 0) {
        *cursor++ = 0;
    }
}

int trx_secp256k1_verify_secret(const uint8_t private_key[32]) {
    secp256k1_context *context = trx_get_context();
    if (context == NULL || private_key == NULL) {
        return 0;
    }
    return secp256k1_ec_seckey_verify(context, private_key);
}

int trx_secp256k1_public_key(const uint8_t private_key[32],
                            uint8_t public_key_uncompressed[65]) {
    secp256k1_context *context = trx_get_context();
    secp256k1_pubkey public_key;
    size_t output_length = 65;

    if (context == NULL || private_key == NULL || public_key_uncompressed == NULL) {
        return 0;
    }
    if (!secp256k1_ec_pubkey_create(context, &public_key, private_key)) {
        return 0;
    }
    return secp256k1_ec_pubkey_serialize(
        context,
        public_key_uncompressed,
        &output_length,
        &public_key,
        SECP256K1_EC_UNCOMPRESSED
    ) && output_length == 65;
}

int trx_secp256k1_add_u64(const uint8_t private_key[32],
                         uint64_t offset,
                         uint8_t output_private_key[32]) {
    secp256k1_context *context = trx_get_context();
    uint8_t tweak[32] = {0};

    if (context == NULL || private_key == NULL || output_private_key == NULL) {
        return 0;
    }
    memcpy(output_private_key, private_key, 32);
    if (offset == 0) {
        return secp256k1_ec_seckey_verify(context, output_private_key);
    }

    for (int index = 0; index < 8; index++) {
        tweak[31 - index] = (uint8_t)(offset & 0xffU);
        offset >>= 8;
    }
    int success = secp256k1_ec_seckey_tweak_add(context, output_private_key, tweak);
    trx_secure_zero(tweak, sizeof(tweak));
    if (!success) {
        trx_secure_zero(output_private_key, 32);
    }
    return success;
}

int trx_secp256k1_public_key_at_offset(const uint8_t private_key[32],
                                      uint64_t offset,
                                      uint8_t output_private_key[32],
                                      uint8_t public_key_uncompressed[65]) {
    if (!trx_secp256k1_add_u64(private_key, offset, output_private_key)) {
        return 0;
    }
    if (!trx_secp256k1_public_key(output_private_key, public_key_uncompressed)) {
        trx_secure_zero(output_private_key, 32);
        return 0;
    }
    return 1;
}

int trx_secp256k1_linear_combination(const uint8_t base_private_key[32],
                                    const uint8_t step_private_key[32],
                                    uint64_t index,
                                    uint8_t output_private_key[32]) {
    secp256k1_context *context = trx_get_context();
    uint8_t multiplier[32] = {0};
    uint8_t product[32];

    if (context == NULL || base_private_key == NULL || step_private_key == NULL
        || output_private_key == NULL || index == 0) {
        return 0;
    }
    memcpy(product, step_private_key, sizeof(product));
    for (int byte_index = 0; byte_index < 8; byte_index++) {
        multiplier[31 - byte_index] = (uint8_t)(index & 0xffU);
        index >>= 8;
    }
    if (!secp256k1_ec_seckey_tweak_mul(context, product, multiplier)
        || !secp256k1_ec_seckey_tweak_add(context, product, base_private_key)) {
        trx_secure_zero(product, sizeof(product));
        trx_secure_zero(multiplier, sizeof(multiplier));
        trx_secure_zero(output_private_key, 32);
        return 0;
    }
    memcpy(output_private_key, product, 32);
    trx_secure_zero(product, sizeof(product));
    trx_secure_zero(multiplier, sizeof(multiplier));
    return 1;
}

int trx_secp256k1_public_key_at_linear_index(const uint8_t base_private_key[32],
                                             const uint8_t step_private_key[32],
                                             uint64_t index,
                                             uint8_t output_private_key[32],
                                             uint8_t public_key_uncompressed[65]) {
    if (!trx_secp256k1_linear_combination(
            base_private_key,
            step_private_key,
            index,
            output_private_key)) {
        return 0;
    }
    if (!trx_secp256k1_public_key(output_private_key, public_key_uncompressed)) {
        trx_secure_zero(output_private_key, 32);
        return 0;
    }
    return 1;
}
