cmake_minimum_required(VERSION 3.30)
project(PlankTabletSetup VERSION 0.1.0 LANGUAGES C Swift)
set(CMAKE_XCODE_ATTRIBUTE_SWIFT_VERSION 6.0)
set(CMAKE_OSX_DEPLOYMENT_TARGET 27.0 CACHE STRING "Minimum Apple OS" FORCE)

if(NOT APPLE)
    message(FATAL_ERROR "The setup app requires an Apple SDK; portable tests remain in the root project")
endif()

get_filename_component(RELAY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(PLANK_SODIUM_PREFIX "" CACHE PATH "Pinned libsodium prefix from build-tablet-setup.sh")
if(NOT EXISTS "${PLANK_SODIUM_PREFIX}/include/sodium.h" OR
   NOT EXISTS "${PLANK_SODIUM_PREFIX}/lib/libsodium.a")
    message(FATAL_ERROR "Pinned libsodium is required; run scripts/build-tablet-setup.sh")
endif()
file(STRINGS "${PLANK_SODIUM_PREFIX}/include/sodium/version.h" SODIUM_VERSION_LINE
     REGEX "^#define SODIUM_VERSION_STRING ")
if(NOT SODIUM_VERSION_LINE MATCHES "\"1.0.22\"")
    message(FATAL_ERROR "Expected libsodium 1.0.22")
endif()

add_library(CRelayProtocol STATIC
    "${RELAY_ROOT}/src/protocol.c" "${RELAY_ROOT}/src/session.c"
    "${RELAY_ROOT}/src/noise.c" "${RELAY_ROOT}/src/cpace.c"
    "${RELAY_ROOT}/src/confirm.c" "${RELAY_ROOT}/src/link.c"
    "${RELAY_ROOT}/src/client_pair.c" "${RELAY_ROOT}/src/client_link.c")
target_compile_features(CRelayProtocol PRIVATE c_std_11)
target_include_directories(CRelayProtocol PUBLIC
    "${RELAY_ROOT}/src" "${RELAY_ROOT}/apple/RelayProtocol/include"
    PRIVATE "${PLANK_SODIUM_PREFIX}/include")
target_link_libraries(CRelayProtocol PUBLIC "${PLANK_SODIUM_PREFIX}/lib/libsodium.a")

add_library(RelaySetupKit STATIC
    "${RELAY_ROOT}/apple/RelaySetupKit/SetupState.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/SetupCoordinator.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayPairingClient.swift")
target_link_libraries(RelaySetupKit PUBLIC CRelayProtocol
    "-framework Foundation" "-framework Security" "-framework Network" "-framework Combine")
target_compile_options(RelaySetupKit PRIVATE -strict-concurrency=complete)
set_target_properties(CRelayProtocol RelaySetupKit PROPERTIES
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_SKIP_INSTALL "YES")

add_executable(PlankTabletSetup MACOSX_BUNDLE
    Sources/TabletSetupApp.swift Sources/TabletSetupView.swift)
configure_file("${PLANK_SODIUM_PREFIX}/share/licenses/libsodium/LICENSE"
    "${CMAKE_CURRENT_BINARY_DIR}/libsodium-LICENSE.txt" COPYONLY)
set(APP_LICENSES "${RELAY_ROOT}/LICENSE" "${RELAY_ROOT}/apple/NOTICE.md"
    "${CMAKE_CURRENT_BINARY_DIR}/libsodium-LICENSE.txt")
set_source_files_properties(${APP_LICENSES} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/licenses")
set_source_files_properties(PrivacyInfo.xcprivacy PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
target_sources(PlankTabletSetup PRIVATE ${APP_LICENSES} PrivacyInfo.xcprivacy)
target_include_directories(PlankTabletSetup PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(PlankTabletSetup PRIVATE RelaySetupKit "-framework SwiftUI")
target_compile_options(PlankTabletSetup PRIVATE -strict-concurrency=complete)

set(PLANK_SETUP_VERSION "0.1.0-visionos-tablet-setup" CACHE STRING "Visible prototype version")
set(PLANK_SETUP_BUILD_NUMBER "1" CACHE STRING "Monotonically increasing TestFlight build number")
if(NOT PLANK_SETUP_BUILD_NUMBER MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "PLANK_SETUP_BUILD_NUMBER must be a positive integer")
endif()
set(PLANK_DEVELOPMENT_TEAM "" CACHE STRING "Optional Apple development team; never hardcoded")
set_target_properties(PlankTabletSetup PROPERTIES
    OUTPUT_NAME "PLANK Tablet Setup"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "la.instinctual.PLANK.TabletSetup"
    XCODE_ATTRIBUTE_PRODUCT_NAME "PLANK Tablet Setup"
    XCODE_ATTRIBUTE_MARKETING_VERSION "0.1.0"
    XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "${PLANK_SETUP_BUILD_NUMBER}"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_SKIP_INSTALL "NO"
    XCODE_ATTRIBUTE_INSTALL_PATH "/Applications"
    XCODE_ATTRIBUTE_SWIFT_STRICT_CONCURRENCY "complete"
    XCODE_ATTRIBUTE_INFOPLIST_KEY_UIApplicationSceneManifest_Generation "YES"
    XCODE_ATTRIBUTE_INFOPLIST_KEY_UILaunchScreen_Generation "YES")
if(CMAKE_SYSTEM_NAME STREQUAL "visionOS")
    target_sources(PlankTabletSetup PRIVATE Assets.xcassets)
    set_target_properties(PlankTabletSetup PROPERTIES
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "7"
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon")
endif()
if(PLANK_DEVELOPMENT_TEAM)
    set_target_properties(PlankTabletSetup PROPERTIES
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${PLANK_DEVELOPMENT_TEAM}"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    enable_testing()
    add_executable(setup-preview Sources/PreviewMain.swift Sources/TabletSetupView.swift)
    target_include_directories(setup-preview PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(setup-preview PRIVATE RelaySetupKit "-framework SwiftUI" "-framework AppKit")
    add_executable(pairing-socket-fixture "${RELAY_ROOT}/apple/Tests/pairing_socket_fixture.c"
        "${RELAY_ROOT}/src/pair_wire.c" "${RELAY_ROOT}/src/pairing.c" "${RELAY_ROOT}/src/identity.c")
    target_include_directories(pairing-socket-fixture PRIVATE "${PLANK_SODIUM_PREFIX}/include")
    target_compile_definitions(pairing-socket-fixture PRIVATE _DARWIN_C_SOURCE)
    target_link_libraries(pairing-socket-fixture PRIVATE CRelayProtocol)
    add_executable(setup-network-tests "${RELAY_ROOT}/apple/Tests/PairingNetworkTests.swift")
    target_include_directories(setup-network-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(setup-network-tests PRIVATE RelaySetupKit)
    add_test(NAME setup-network-tests COMMAND setup-network-tests $<TARGET_FILE:pairing-socket-fixture>)
    set_tests_properties(setup-network-tests PROPERTIES TIMEOUT 40)
    add_executable(setup-state-tests
        "${RELAY_ROOT}/apple/RelaySetupKit/SetupState.swift"
        "${RELAY_ROOT}/apple/Tests/SetupStateTests.swift")
    target_link_libraries(setup-state-tests PRIVATE "-framework Foundation")
    add_test(NAME setup-state-tests COMMAND setup-state-tests)
    foreach(test protocol session client_link pair_e2e noise_vector cpace_vector confirm)
        if(test STREQUAL "noise_vector" OR test STREQUAL "cpace_vector")
            # Vector fixtures require a different test-only context layout.
            string(REPLACE "_vector" "" base "${test}")
            add_executable(${test}_test "${RELAY_ROOT}/tests/${test}_test.c"
                "${RELAY_ROOT}/src/${base}.c")
            string(TOUPPER "${base}" upper)
            target_compile_definitions(${test}_test PRIVATE "PLTR_${upper}_TESTING=1")
            target_include_directories(${test}_test PRIVATE "${RELAY_ROOT}/src" "${PLANK_SODIUM_PREFIX}/include")
            target_link_libraries(${test}_test PRIVATE "${PLANK_SODIUM_PREFIX}/lib/libsodium.a")
        elseif(test STREQUAL "pair_e2e")
            add_executable(${test}_test "${RELAY_ROOT}/tests/${test}_test.c"
                "${RELAY_ROOT}/src/pairing.c" "${RELAY_ROOT}/src/pair_wire.c"
                "${RELAY_ROOT}/src/identity.c")
            target_include_directories(${test}_test PRIVATE "${PLANK_SODIUM_PREFIX}/include")
            target_compile_definitions(${test}_test PRIVATE _DARWIN_C_SOURCE)
            target_link_libraries(${test}_test PRIVATE CRelayProtocol)
        else()
            add_executable(${test}_test "${RELAY_ROOT}/tests/${test}_test.c")
            target_include_directories(${test}_test PRIVATE "${PLANK_SODIUM_PREFIX}/include")
            target_link_libraries(${test}_test PRIVATE CRelayProtocol)
        endif()
        add_test(NAME ${test}_test COMMAND ${test}_test)
    endforeach()
endif()
