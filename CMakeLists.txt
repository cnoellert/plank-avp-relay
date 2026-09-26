cmake_minimum_required(VERSION 3.20)
project(plank_tablet_relay LANGUAGES C CXX)

enable_testing()
add_library(plank_relay_protocol STATIC src/protocol.c)
target_include_directories(plank_relay_protocol PUBLIC src)
target_compile_features(plank_relay_protocol PUBLIC c_std_11)

add_executable(protocol_test tests/protocol_test.c)
target_link_libraries(protocol_test PRIVATE plank_relay_protocol)
add_test(NAME protocol_test COMMAND protocol_test)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # A vendored source change must be made in the Client and pinned again.
    set(PLANK_CLIENT_VENDOR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/plank-client")
    file(SHA256 "${PLANK_CLIENT_VENDOR}/linuxrawwacom.cpp" WORKER_CPP_SHA256)
    file(SHA256 "${PLANK_CLIENT_VENDOR}/linuxrawwacom.h" WORKER_H_SHA256)
    file(SHA256 "${PLANK_CLIENT_VENDOR}/plank.h" PLANK_H_SHA256)
    if(NOT WORKER_CPP_SHA256 STREQUAL
            "518f2ee58eb83c10347ed1a983a0202feb688c4356b47fa9a8eda75398841939" OR
       NOT WORKER_H_SHA256 STREQUAL
            "561d74872a80720f9cd2120ef80130791d0075494a85ab00fd2ecd0edd669f30" OR
       NOT PLANK_H_SHA256 STREQUAL
            "b6a197da614ec5becc812b73d1d8e0ac5861cea22805f8443690b71ee16c8392")
        message(FATAL_ERROR "Vendored PLANK Client worker differs from its pinned snapshot")
    endif()

    find_package(PkgConfig REQUIRED)
    pkg_check_modules(UDEV REQUIRED IMPORTED_TARGET libudev)
    pkg_check_modules(SODIUM QUIET IMPORTED_TARGET "libsodium>=1.0.19")
    find_package(Threads REQUIRED)
    add_library(plank_wacom_worker STATIC "${PLANK_CLIENT_VENDOR}/linuxrawwacom.cpp")
    target_include_directories(plank_wacom_worker PUBLIC "${PLANK_CLIENT_VENDOR}")
    target_compile_features(plank_wacom_worker PUBLIC cxx_std_17)
    target_link_libraries(plank_wacom_worker PUBLIC PkgConfig::UDEV Threads::Threads)

    if(SODIUM_FOUND)
        add_library(plank_relay_noise STATIC src/noise.c)
        target_include_directories(plank_relay_noise PUBLIC src)
        target_compile_features(plank_relay_noise PUBLIC c_std_11)
        target_link_libraries(plank_relay_noise PUBLIC PkgConfig::SODIUM)

        add_executable(noise_vector_test tests/noise_vector_test.c src/noise.c)
        target_include_directories(noise_vector_test PRIVATE src)
        target_compile_definitions(noise_vector_test PRIVATE PLTR_NOISE_TESTING=1)
        target_link_libraries(noise_vector_test PRIVATE PkgConfig::SODIUM)
        add_test(NAME noise_vector_test COMMAND noise_vector_test)
    else()
        message(STATUS "Noise tests disabled: libsodium 1.0.19 or newer not found")
    endif()
endif()
