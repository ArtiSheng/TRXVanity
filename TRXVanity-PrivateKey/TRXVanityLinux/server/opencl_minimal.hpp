#pragma once

// Minimal OpenCL 1.2 host ABI used by the Windows GPU engine. The NVIDIA
// display driver supplies OpenCL.dll; keeping the small ABI declaration here
// avoids making end users install the multi-gigabyte CUDA Toolkit.

#include <cstddef>
#include <cstdint>

#if defined(_WIN32)
#define CL_API_CALL __stdcall
#define CL_CALLBACK __stdcall
#else
#define CL_API_CALL
#define CL_CALLBACK
#endif

using cl_int = std::int32_t;
using cl_uint = std::uint32_t;
using cl_uchar = std::uint8_t;
using cl_ulong = std::uint64_t;
using cl_bool = cl_uint;
using cl_bitfield = cl_ulong;
using cl_device_type = cl_bitfield;
using cl_mem_flags = cl_bitfield;
using cl_command_queue_properties = cl_bitfield;
using cl_device_info = cl_uint;
using cl_program_info = cl_uint;
using cl_program_build_info = cl_uint;
using cl_context_properties = std::intptr_t;

struct _cl_platform_id;
struct _cl_device_id;
struct _cl_context;
struct _cl_command_queue;
struct _cl_mem;
struct _cl_program;
struct _cl_kernel;
struct _cl_event;

using cl_platform_id = _cl_platform_id*;
using cl_device_id = _cl_device_id*;
using cl_context = _cl_context*;
using cl_command_queue = _cl_command_queue*;
using cl_mem = _cl_mem*;
using cl_program = _cl_program*;
using cl_kernel = _cl_kernel*;
using cl_event = _cl_event*;

struct alignas(32) cl_ulong4 {
    cl_ulong s[4];
};

constexpr cl_int CL_SUCCESS = 0;
constexpr cl_int CL_DEVICE_NOT_FOUND = -1;
constexpr cl_bool CL_TRUE = 1;
constexpr cl_device_type CL_DEVICE_TYPE_GPU = 1ULL << 2U;
constexpr cl_device_info CL_DEVICE_MAX_COMPUTE_UNITS = 0x1002;
constexpr cl_device_info CL_DEVICE_MAX_MEM_ALLOC_SIZE = 0x1010;
constexpr cl_device_info CL_DEVICE_GLOBAL_MEM_SIZE = 0x101F;
constexpr cl_device_info CL_DEVICE_NAME = 0x102B;
constexpr cl_device_info CL_DEVICE_VENDOR = 0x102C;
constexpr cl_device_info CL_DRIVER_VERSION = 0x102D;
constexpr cl_mem_flags CL_MEM_READ_WRITE = 1ULL << 0U;
constexpr cl_mem_flags CL_MEM_READ_ONLY = 1ULL << 2U;
constexpr cl_mem_flags CL_MEM_COPY_HOST_PTR = 1ULL << 5U;
constexpr cl_program_info CL_PROGRAM_BINARY_SIZES = 0x1165;
constexpr cl_program_info CL_PROGRAM_BINARIES = 0x1166;
constexpr cl_program_build_info CL_PROGRAM_BUILD_LOG = 0x1183;

extern "C" {

cl_int CL_API_CALL clGetPlatformIDs(
    cl_uint num_entries,
    cl_platform_id* platforms,
    cl_uint* num_platforms);

cl_int CL_API_CALL clGetDeviceIDs(
    cl_platform_id platform,
    cl_device_type device_type,
    cl_uint num_entries,
    cl_device_id* devices,
    cl_uint* num_devices);

cl_int CL_API_CALL clGetDeviceInfo(
    cl_device_id device,
    cl_device_info param_name,
    std::size_t param_value_size,
    void* param_value,
    std::size_t* param_value_size_ret);

cl_context CL_API_CALL clCreateContext(
    const cl_context_properties* properties,
    cl_uint num_devices,
    const cl_device_id* devices,
    void (CL_CALLBACK* notify)(const char*, const void*, std::size_t, void*),
    void* user_data,
    cl_int* errcode_ret);

cl_int CL_API_CALL clReleaseContext(cl_context context);

cl_command_queue CL_API_CALL clCreateCommandQueue(
    cl_context context,
    cl_device_id device,
    cl_command_queue_properties properties,
    cl_int* errcode_ret);

cl_int CL_API_CALL clReleaseCommandQueue(cl_command_queue command_queue);

cl_mem CL_API_CALL clCreateBuffer(
    cl_context context,
    cl_mem_flags flags,
    std::size_t size,
    void* host_ptr,
    cl_int* errcode_ret);

cl_int CL_API_CALL clReleaseMemObject(cl_mem memobj);

cl_program CL_API_CALL clCreateProgramWithSource(
    cl_context context,
    cl_uint count,
    const char** strings,
    const std::size_t* lengths,
    cl_int* errcode_ret);

cl_program CL_API_CALL clCreateProgramWithBinary(
    cl_context context,
    cl_uint num_devices,
    const cl_device_id* device_list,
    const std::size_t* lengths,
    const unsigned char** binaries,
    cl_int* binary_status,
    cl_int* errcode_ret);

cl_int CL_API_CALL clBuildProgram(
    cl_program program,
    cl_uint num_devices,
    const cl_device_id* device_list,
    const char* options,
    void (CL_CALLBACK* notify)(cl_program, void*),
    void* user_data);

cl_int CL_API_CALL clGetProgramBuildInfo(
    cl_program program,
    cl_device_id device,
    cl_program_build_info param_name,
    std::size_t param_value_size,
    void* param_value,
    std::size_t* param_value_size_ret);

cl_int CL_API_CALL clGetProgramInfo(
    cl_program program,
    cl_program_info param_name,
    std::size_t param_value_size,
    void* param_value,
    std::size_t* param_value_size_ret);

cl_int CL_API_CALL clReleaseProgram(cl_program program);

cl_kernel CL_API_CALL clCreateKernel(
    cl_program program,
    const char* kernel_name,
    cl_int* errcode_ret);

cl_int CL_API_CALL clReleaseKernel(cl_kernel kernel);

cl_int CL_API_CALL clSetKernelArg(
    cl_kernel kernel,
    cl_uint arg_index,
    std::size_t arg_size,
    const void* arg_value);

cl_int CL_API_CALL clEnqueueNDRangeKernel(
    cl_command_queue command_queue,
    cl_kernel kernel,
    cl_uint work_dim,
    const std::size_t* global_work_offset,
    const std::size_t* global_work_size,
    const std::size_t* local_work_size,
    cl_uint num_events_in_wait_list,
    const cl_event* event_wait_list,
    cl_event* event);

cl_int CL_API_CALL clEnqueueWriteBuffer(
    cl_command_queue command_queue,
    cl_mem buffer,
    cl_bool blocking_write,
    std::size_t offset,
    std::size_t size,
    const void* ptr,
    cl_uint num_events_in_wait_list,
    const cl_event* event_wait_list,
    cl_event* event);

cl_int CL_API_CALL clEnqueueReadBuffer(
    cl_command_queue command_queue,
    cl_mem buffer,
    cl_bool blocking_read,
    std::size_t offset,
    std::size_t size,
    void* ptr,
    cl_uint num_events_in_wait_list,
    const cl_event* event_wait_list,
    cl_event* event);

cl_int CL_API_CALL clFinish(cl_command_queue command_queue);

}  // extern "C"
