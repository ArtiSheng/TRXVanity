#pragma once

#ifndef FASTPBKDF2_H
#define FASTPBKDF2_H

#include <string.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <assert.h>
#include <stdlib.h>
#include <stdint.h>


#ifdef __cplusplus
extern "C" {
#endif



    __device__   void fastpbkdf2_hmac_sha512(const uint8_t* pw, size_t npw,
        const uint8_t* salt, size_t nsalt,
        uint64_t iterations,
        uint8_t* out, size_t nout);

    __device__  void HMAC_SHA512(const uint8_t* key, size_t key_len,
        const uint8_t* data, size_t data_len,
        uint8_t* out);

    __device__ void SHA512(const uint8_t* data, size_t len, uint8_t out[64]);


#ifdef __cplusplus
}
#endif

#endif
