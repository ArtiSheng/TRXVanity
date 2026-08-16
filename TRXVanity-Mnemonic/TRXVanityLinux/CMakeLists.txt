cmake_minimum_required(VERSION 3.22)

# CUDA 12.8 is the first production toolkit used by this project for native
# Blackwell GeForce code. Emit both the RTX 5090 cubin and forward-compatible
# PTX unless the caller deliberately overrides the architecture list.
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(
        CMAKE_CUDA_ARCHITECTURES
        "120-real;120-virtual"
        CACHE STRING
        "CUDA architectures (RTX 5090 is sm_120)"
    )
endif()

# These cache values are deliberately compile-time-only A/B controls. Their
# defaults reproduce the production kernel exactly; invalid or impractical
# values fail during configuration rather than producing an unsafe binary.
# Do not expose a global --maxrregcount toggle here: both hot kernels already
# carry function-specific __launch_bounds__, so such a global knob would not
# be a reliable control for this build.
set(
    TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD
    "4"
    CACHE STRING
    "Address-pipeline candidates handled by each CUDA thread (1, 2, 4, or 8)"
)
set_property(
    CACHE TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD
    PROPERTY STRINGS 1 2 4 8
)
if(NOT "${TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD}" MATCHES "^(1|2|4|8)$")
    message(FATAL_ERROR
        "TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD must be one of 1, 2, 4, or 8."
    )
endif()

set(
    TRXVANITY_SECP_WINDOW_BITS
    "16"
    CACHE STRING
    "CUDA secp256k1 precomputation window bits (8 through 20)"
)
set_property(
    CACHE TRXVANITY_SECP_WINDOW_BITS
    PROPERTY STRINGS 8 9 10 11 12 13 14 15 16 17 18 19 20
)
if(NOT "${TRXVANITY_SECP_WINDOW_BITS}"
        MATCHES "^(8|9|10|11|12|13|14|15|16|17|18|19|20)$")
    message(FATAL_ERROR
        "TRXVANITY_SECP_WINDOW_BITS must be an integer from 8 through 20."
    )
endif()

set(
    TRXVANITY_MASTER_MIN_BLOCKS_PER_SM
    "0"
    CACHE STRING
    "Master-kernel launch-bounds occupancy hint (0 preserves default; 2 experiments with two blocks/SM)"
)
set_property(
    CACHE TRXVANITY_MASTER_MIN_BLOCKS_PER_SM
    PROPERTY STRINGS 0 2
)
if(NOT "${TRXVANITY_MASTER_MIN_BLOCKS_PER_SM}" MATCHES "^(0|2)$")
    message(FATAL_ERROR
        "TRXVANITY_MASTER_MIN_BLOCKS_PER_SM must be either 0 or 2."
    )
endif()

set(
    TRXVANITY_MASTER_LOW_SPILL_THREADS
    "0"
    CACHE STRING
    "Near-zero-spill master launch-bounds experiment (0=off, 96=__launch_bounds__(96,4), 128=__launch_bounds__(128,3))"
)
set_property(
    CACHE TRXVANITY_MASTER_LOW_SPILL_THREADS
    PROPERTY STRINGS 0 96 128
)
if(NOT "${TRXVANITY_MASTER_LOW_SPILL_THREADS}" MATCHES "^(0|96|128)$")
    message(FATAL_ERROR
        "TRXVANITY_MASTER_LOW_SPILL_THREADS must be 0, 96, or 128."
    )
endif()
if(NOT "${TRXVANITY_MASTER_LOW_SPILL_THREADS}" STREQUAL "0"
        AND NOT "${TRXVANITY_MASTER_MIN_BLOCKS_PER_SM}" STREQUAL "0")
    message(FATAL_ERROR
        "TRXVANITY_MASTER_LOW_SPILL_THREADS cannot be combined with "
        "TRXVANITY_MASTER_MIN_BLOCKS_PER_SM."
    )
endif()

set(
    TRXVANITY_PBKDF2_DIRECT_WORDS
    "0"
    CACHE STRING
    "PBKDF2-to-BIP32 direct SHA-512 word handoff experiment (0=production baseline, 1=A/B only)"
)
set_property(CACHE TRXVANITY_PBKDF2_DIRECT_WORDS PROPERTY STRINGS 0 1)
if(NOT "${TRXVANITY_PBKDF2_DIRECT_WORDS}" MATCHES "^(0|1)$")
    message(FATAL_ERROR
        "TRXVANITY_PBKDF2_DIRECT_WORDS must be either 0 or 1."
    )
endif()

project(TRXVanityLinux VERSION 1.0.0 LANGUAGES C CXX CUDA)

if(CMAKE_CUDA_COMPILER_VERSION VERSION_LESS 12.8)
    message(FATAL_ERROR
        "CUDA Toolkit 12.8 or newer is required for native sm_120 output; "
        "found ${CMAKE_CUDA_COMPILER_VERSION}."
    )
endif()

if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

find_package(CUDAToolkit 12.8 REQUIRED)
find_package(OpenSSL 3.0 REQUIRED COMPONENTS Crypto)
find_package(Threads REQUIRED)
include(CTest)

set(TRXVANITY_VENDOR_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../Vendor")
set(TRXVANITY_SECP_ROOT "${TRXVANITY_VENDOR_ROOT}/secp256k1")
set(
    TRXVANITY_CUDA_MNEMONIC_ROOT
    "${TRXVANITY_VENDOR_ROOT}/CUDA_Mnemonic_Recovery"
)
set(TRXVANITY_ENGINE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/Engine")
set(
    TRXVANITY_CUDA_TUNING_STAMP
    "${CMAKE_CURRENT_BINARY_DIR}/cuda-tuning-config.txt"
)
file(GENERATE
    OUTPUT "${TRXVANITY_CUDA_TUNING_STAMP}"
    CONTENT "address_candidates_per_thread=${TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD}\nsecp_window_bits=${TRXVANITY_SECP_WINDOW_BITS}\nmaster_min_blocks_per_sm=${TRXVANITY_MASTER_MIN_BLOCKS_PER_SM}\nmaster_low_spill_threads=${TRXVANITY_MASTER_LOW_SPILL_THREADS}\npbkdf2_direct_words=${TRXVANITY_PBKDF2_DIRECT_WORDS}\n"
)

set(TRXVANITY_REQUIRED_VENDOR_FILES
    "${TRXVANITY_SECP_ROOT}/include/secp256k1.h"
    "${TRXVANITY_SECP_ROOT}/src/secp256k1.c"
    "${TRXVANITY_SECP_ROOT}/src/precomputed_ecmult.c"
    "${TRXVANITY_SECP_ROOT}/src/precomputed_ecmult_gen.c"
    "${TRXVANITY_CUDA_MNEMONIC_ROOT}/third_party/fastpbkdf2/pbkdf2_func.cu"
    "${TRXVANITY_CUDA_MNEMONIC_ROOT}/third_party/secp256k1/secp256k1.cu"
    "${TRXVANITY_CUDA_MNEMONIC_ROOT}/assets/wordlists/bip39-en.txt"
)
foreach(required_file IN LISTS TRXVANITY_REQUIRED_VENDOR_FILES)
    if(NOT EXISTS "${required_file}")
        message(FATAL_ERROR "Required workspace dependency is missing: ${required_file}")
    endif()
endforeach()

# Build the exact vendored CPU implementation used by the Windows engine. It
# is intentionally private to this executable and does not use a system
# libsecp256k1 whose configuration could differ.
add_library(trxvanity_secp256k1 STATIC
    "${TRXVANITY_SECP_ROOT}/src/secp256k1.c"
    "${TRXVANITY_SECP_ROOT}/src/precomputed_ecmult.c"
    "${TRXVANITY_SECP_ROOT}/src/precomputed_ecmult_gen.c"
)
target_include_directories(trxvanity_secp256k1
    PUBLIC "${TRXVANITY_SECP_ROOT}/include"
    PRIVATE "${TRXVANITY_SECP_ROOT}/src"
)
target_compile_features(trxvanity_secp256k1 PRIVATE c_std_99)
target_compile_definitions(trxvanity_secp256k1 PRIVATE NDEBUG)
target_compile_options(trxvanity_secp256k1 PRIVATE
    "$<$<COMPILE_LANGUAGE:C>:-O3;-fomit-frame-pointer>"
)

# CMake's normal CUDA architecture machinery cannot express the Windows
# engine's two-stage device-LTO pipeline. Drive these three nvcc invocations
# explicitly so CUDA 12.8 receives code=lto_120 only while compiling and
# code=sm_120 only while device-linking. This also prevents target link options
# from being rewritten as -Xcompiler flags by CMake 3.22.
set(TRXVANITY_CUDA_OBJECT_DIR "${CMAKE_CURRENT_BINARY_DIR}/cuda-objects")
set(
    TRXVANITY_ENGINE_CUDA_OBJECT
    "${TRXVANITY_CUDA_OBJECT_DIR}/mnemonic_cuda.o"
)
set(
    TRXVANITY_SECP_CUDA_OBJECT
    "${TRXVANITY_CUDA_OBJECT_DIR}/mnemonic_cuda_secp256k1.o"
)
set(
    TRXVANITY_CUDA_DEVICE_LINK_OBJECT
    "${TRXVANITY_CUDA_OBJECT_DIR}/mnemonic_cuda_device_link.o"
)

file(GLOB_RECURSE TRXVANITY_CUDA_HEADER_DEPENDENCIES CONFIGURE_DEPENDS
    "${TRXVANITY_ENGINE_ROOT}/*.hpp"
    "${TRXVANITY_CUDA_MNEMONIC_ROOT}/third_party/fastpbkdf2/*"
    "${TRXVANITY_CUDA_MNEMONIC_ROOT}/third_party/secp256k1/*"
)

set(TRXVANITY_ENGINE_CUDA_TUNING_DEFINITIONS
    "-DTRXVANITY_ADDRESS_CANDIDATES_PER_THREAD=${TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD}"
    "-DTRXVANITY_SECP_WINDOW_BITS=${TRXVANITY_SECP_WINDOW_BITS}"
    "-DTRXVANITY_MASTER_MIN_BLOCKS_PER_SM=${TRXVANITY_MASTER_MIN_BLOCKS_PER_SM}"
    "-DTRXVANITY_MASTER_LOW_SPILL_THREADS=${TRXVANITY_MASTER_LOW_SPILL_THREADS}"
    "-DTRXVANITY_PBKDF2_DIRECT_WORDS=${TRXVANITY_PBKDF2_DIRECT_WORDS}"
)

set(TRXVANITY_CUDA_COMPILE_OPTIONS
    --compile
    --std=c++17
    -O3
    --use_fast_math
    --relocatable-device-code=true
    --threads=0
    -DNDEBUG
    "-I${TRXVANITY_ENGINE_ROOT}"
    "-I${TRXVANITY_CUDA_MNEMONIC_ROOT}"
    --generate-code=arch=compute_120,code=lto_120
    --generate-code=arch=compute_120,code=compute_120
)

add_custom_command(
    OUTPUT "${TRXVANITY_ENGINE_CUDA_OBJECT}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${TRXVANITY_CUDA_OBJECT_DIR}"
    COMMAND "${CMAKE_CUDA_COMPILER}"
        ${TRXVANITY_CUDA_COMPILE_OPTIONS}
        ${TRXVANITY_ENGINE_CUDA_TUNING_DEFINITIONS}
        -o "${TRXVANITY_ENGINE_CUDA_OBJECT}"
        "${TRXVANITY_ENGINE_ROOT}/mnemonic_cuda.cu"
    DEPENDS
        "${TRXVANITY_ENGINE_ROOT}/mnemonic_cuda.cu"
        "${TRXVANITY_CUDA_TUNING_STAMP}"
        ${TRXVANITY_CUDA_HEADER_DEPENDENCIES}
    COMMENT "Compiling the RTX 5090 mnemonic CUDA pipeline to lto_120"
    VERBATIM
)

add_custom_command(
    OUTPUT "${TRXVANITY_SECP_CUDA_OBJECT}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${TRXVANITY_CUDA_OBJECT_DIR}"
    COMMAND "${CMAKE_CUDA_COMPILER}"
        ${TRXVANITY_CUDA_COMPILE_OPTIONS}
        -o "${TRXVANITY_SECP_CUDA_OBJECT}"
        "${TRXVANITY_CUDA_MNEMONIC_ROOT}/third_party/secp256k1/secp256k1.cu"
    DEPENDS
        "${TRXVANITY_CUDA_MNEMONIC_ROOT}/third_party/secp256k1/secp256k1.cu"
        ${TRXVANITY_CUDA_HEADER_DEPENDENCIES}
    COMMENT "Compiling the CUDA secp256k1 implementation to lto_120"
    VERBATIM
)

add_custom_command(
    OUTPUT "${TRXVANITY_CUDA_DEVICE_LINK_OBJECT}"
    COMMAND "${CMAKE_CUDA_COMPILER}"
        --device-link
        --dlink-time-opt
        --relocatable-ptx
        -o "${TRXVANITY_CUDA_DEVICE_LINK_OBJECT}"
        "${TRXVANITY_ENGINE_CUDA_OBJECT}"
        "${TRXVANITY_SECP_CUDA_OBJECT}"
        --generate-code=arch=compute_120,code=sm_120
        --generate-code=arch=compute_120,code=compute_120
    DEPENDS
        "${TRXVANITY_ENGINE_CUDA_OBJECT}"
        "${TRXVANITY_SECP_CUDA_OBJECT}"
    COMMENT "Device-linking lto_120 into sm_120 plus compute_120 PTX"
    VERBATIM
)

set_source_files_properties(
    "${TRXVANITY_ENGINE_CUDA_OBJECT}"
    "${TRXVANITY_SECP_CUDA_OBJECT}"
    "${TRXVANITY_CUDA_DEVICE_LINK_OBJECT}"
    PROPERTIES GENERATED TRUE EXTERNAL_OBJECT TRUE
)

add_executable(trxvanity-gpu
    "${TRXVANITY_ENGINE_ROOT}/cpu_budget.cpp"
    "${TRXVANITY_ENGINE_ROOT}/crypto.cpp"
    "${TRXVANITY_ENGINE_ROOT}/main.cpp"
    "${TRXVANITY_ENGINE_ROOT}/match_plan.cpp"
    "${TRXVANITY_ENGINE_ROOT}/mnemonic.cpp"
    "${TRXVANITY_ENGINE_ROOT}/mnemonic_engine.cpp"
    "${TRXVANITY_ENGINE_ROOT}/openssl_pbkdf2.cpp"
    "${TRXVANITY_ENGINE_CUDA_OBJECT}"
    "${TRXVANITY_SECP_CUDA_OBJECT}"
    "${TRXVANITY_CUDA_DEVICE_LINK_OBJECT}"
)
target_include_directories(trxvanity-gpu PRIVATE
    "${TRXVANITY_ENGINE_ROOT}"
    "${TRXVANITY_SECP_ROOT}/include"
    "${TRXVANITY_CUDA_MNEMONIC_ROOT}"
)
target_compile_features(trxvanity-gpu PRIVATE cxx_std_17)
target_compile_definitions(trxvanity-gpu PRIVATE NDEBUG)
target_compile_options(trxvanity-gpu PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX>:-O3;-Wall;-Wextra;-Wpedantic;-fomit-frame-pointer>"
)

find_library(
    TRXVANITY_CUDA_DEVICE_RUNTIME
    NAMES cudadevrt
    PATHS "${CUDAToolkit_LIBRARY_DIR}"
    NO_DEFAULT_PATH
)
if(NOT TRXVANITY_CUDA_DEVICE_RUNTIME)
    message(FATAL_ERROR
        "CUDA device runtime libcudadevrt.a was not found in "
        "${CUDAToolkit_LIBRARY_DIR}."
    )
endif()

target_link_libraries(trxvanity-gpu PRIVATE
    trxvanity_secp256k1
    OpenSSL::Crypto
    Threads::Threads
    "${TRXVANITY_CUDA_DEVICE_RUNTIME}"
    CUDA::cudart_static
)

set_target_properties(trxvanity-gpu PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED YES
    CXX_EXTENSIONS NO
    OUTPUT_NAME "trxvanity-gpu"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)

add_custom_command(TARGET trxvanity-gpu POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${TRXVANITY_CUDA_MNEMONIC_ROOT}/assets/wordlists/bip39-en.txt"
        "$<TARGET_FILE_DIR:trxvanity-gpu>/bip39-english.txt"
    COMMENT "Copying the BIP39 English word list beside trxvanity-gpu"
)

if(BUILD_TESTING)
    add_executable(trxvanity_cpu_budget_test
        "${TRXVANITY_ENGINE_ROOT}/cpu_budget.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/cpu_budget_test.cpp"
    )
    target_include_directories(
        trxvanity_cpu_budget_test PRIVATE "${TRXVANITY_ENGINE_ROOT}"
    )
    target_compile_features(trxvanity_cpu_budget_test PRIVATE cxx_std_17)
    target_compile_options(trxvanity_cpu_budget_test PRIVATE
        -O3 -Wall -Wextra -Wpedantic
    )
    add_test(NAME cpu_budget COMMAND trxvanity_cpu_budget_test)
endif()

message(STATUS
    "CUDA targets: lto_120 -> sm_120 + compute_120 PTX"
)
message(STATUS
    "CUDA tuning: address candidates/thread="
    "${TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD}, secp window bits="
    "${TRXVANITY_SECP_WINDOW_BITS}, master min blocks/SM="
    "${TRXVANITY_MASTER_MIN_BLOCKS_PER_SM}"
)
message(STATUS
    "CUDA PBKDF2 experiments: low-spill threads="
    "${TRXVANITY_MASTER_LOW_SPILL_THREADS}, direct words="
    "${TRXVANITY_PBKDF2_DIRECT_WORDS}"
)
message(STATUS "Runtime output: ${CMAKE_BINARY_DIR}/trxvanity-gpu")
