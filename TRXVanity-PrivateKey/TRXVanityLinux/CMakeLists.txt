cmake_minimum_required(VERSION 3.18)

project(TRXVanityLinux VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 90)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(TRXVANITY_SERVER_DEFAULT ON)
else()
    set(TRXVANITY_SERVER_DEFAULT OFF)
endif()
option(TRXVANITY_BUILD_SERVER "Build the NVIDIA OpenCL public-only GPU server" ${TRXVANITY_SERVER_DEFAULT})

get_filename_component(TRXVANITY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(SECP256K1_ROOT "${TRXVANITY_ROOT}/Vendor/secp256k1")

foreach(required_path
        "${SECP256K1_ROOT}/src/secp256k1.c"
        "${SECP256K1_ROOT}/src/precomputed_ecmult.c"
        "${SECP256K1_ROOT}/src/precomputed_ecmult_gen.c")
    if(NOT EXISTS "${required_path}")
        message(FATAL_ERROR "Required current-project source is missing: ${required_path}")
    endif()
endforeach()

add_library(trx_secp256k1 STATIC
    "${SECP256K1_ROOT}/src/secp256k1.c"
    "${SECP256K1_ROOT}/src/precomputed_ecmult.c"
    "${SECP256K1_ROOT}/src/precomputed_ecmult_gen.c")
target_include_directories(trx_secp256k1
    PUBLIC "${SECP256K1_ROOT}/include"
    PRIVATE "${SECP256K1_ROOT}/src")
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(trx_secp256k1 PRIVATE -O3 -ffunction-sections -fdata-sections)
endif()

add_library(trx_common STATIC
    common/crypto.cpp
    common/match_plan.cpp
    common/request.cpp)
target_include_directories(trx_common PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/common")
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(trx_common PRIVATE
        -O3 -Wall -Wextra -Wpedantic -ffunction-sections -fdata-sections)
endif()

if(TRXVANITY_BUILD_SERVER)
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
        message(FATAL_ERROR "The GPU server target currently supports Linux only.")
    endif()
    find_library(TRXVANITY_OPENCL_LIBRARY
        NAMES OpenCL
        HINTS
            /usr/local/cuda/targets/x86_64-linux/lib
            /usr/local/cuda/lib64
            /usr/lib/x86_64-linux-gnu)
    if(NOT TRXVANITY_OPENCL_LIBRARY)
        find_file(TRXVANITY_OPENCL_LIBRARY
            NAMES libOpenCL.so.1
            HINTS
                /usr/local/cuda/targets/x86_64-linux/lib
                /usr/local/cuda/lib64
                /usr/lib/x86_64-linux-gnu
                /usr/lib64
                /usr/lib)
    endif()
    if(NOT TRXVANITY_OPENCL_LIBRARY)
        message(FATAL_ERROR "OpenCL loader not found (expected libOpenCL.so or libOpenCL.so.1)")
    endif()
    set(TRXVANITY_KERNEL_FILES
        "${CMAKE_CURRENT_SOURCE_DIR}/kernels/keccak.cl"
        "${CMAKE_CURRENT_SOURCE_DIR}/kernels/profanity.cl"
        "${CMAKE_CURRENT_SOURCE_DIR}/kernels/tron.cl")
    add_executable(trxvanity-linux-gpu
        server/main.cpp
        server/opencl_engine.cpp
        server/public_crypto.cpp
        server/random.cpp
        third_party/profanity2/precomp.cpp)
    target_include_directories(trxvanity-linux-gpu PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/server"
        "${CMAKE_CURRENT_SOURCE_DIR}/third_party/profanity2")
    target_link_libraries(trxvanity-linux-gpu PRIVATE
        trx_common trx_secp256k1 "${TRXVANITY_OPENCL_LIBRARY}")
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(trxvanity-linux-gpu PRIVATE
            -O3 -Wall -Wextra -Wpedantic -ffunction-sections -fdata-sections)
        target_link_options(trxvanity-linux-gpu PRIVATE -Wl,--gc-sections)
    endif()
    set(TRXVANITY_KERNEL_OUTPUTS)
    foreach(kernel_file IN LISTS TRXVANITY_KERNEL_FILES)
        get_filename_component(kernel_name "${kernel_file}" NAME)
        set(kernel_output "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/kernels/${kernel_name}")
        add_custom_command(
            OUTPUT "${kernel_output}"
            COMMAND "${CMAKE_COMMAND}" -E make_directory
                "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/kernels"
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${kernel_file}" "${kernel_output}"
            DEPENDS "${kernel_file}"
            COMMENT "Copying ${kernel_name}")
        list(APPEND TRXVANITY_KERNEL_OUTPUTS "${kernel_output}")
    endforeach()
    add_custom_target(trxvanity-linux-kernels ALL DEPENDS ${TRXVANITY_KERNEL_OUTPUTS})
    add_dependencies(trxvanity-linux-gpu trxvanity-linux-kernels)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(trxvanity-public-self-test
        tests/public_self_test.cpp
        server/public_crypto.cpp)
    target_include_directories(trxvanity-public-self-test PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/server")
    target_link_libraries(trxvanity-public-self-test PRIVATE
        trx_common trx_secp256k1)
    add_test(NAME public_cpu_self_test
        COMMAND "$<TARGET_FILE:trxvanity-public-self-test>")
    set_tests_properties(public_cpu_self_test PROPERTIES LABELS "cpu")
    if(TARGET trxvanity-linux-gpu)
        add_test(NAME server_gpu_self_test
            COMMAND "$<TARGET_FILE:trxvanity-linux-gpu>"
                --self-test --inverse-multiple 16384)
        set_tests_properties(server_gpu_self_test PROPERTIES LABELS "gpu")
    endif()
endif()
