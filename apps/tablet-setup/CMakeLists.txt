cmake_minimum_required(VERSION 3.30)
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION" PLANK_RELEASE_VERSION)
if(NOT PLANK_RELEASE_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "VERSION must contain Major.Minor.Ancillary")
endif()
project(PlankTabletSetup VERSION "${PLANK_RELEASE_VERSION}" LANGUAGES C Swift)
add_compile_definitions("$<$<COMPILE_LANGUAGE:C>:PLTR_SOFTWARE_VERSION=\"${PROJECT_VERSION}\">")
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
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayTestTransport.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayTabletTest.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayBackgroundRefresh.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayBluetooth.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayBLEConnection.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayL2CAPStream.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayTCPConnection.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayScanner.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayDiscovery.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/TabletReadings.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/TabletManagement.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/DrawingHandoff.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/DrawingRegistrationRequest.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/DrawingEnrollment.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/DrawingRegistrationReceipt.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayNetworkSettings.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayWifi.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayPairingClient.swift"
    "${RELAY_ROOT}/apple/RelaySetupKit/RelayConnectionLabels.swift")
target_link_libraries(RelaySetupKit PUBLIC CRelayProtocol
    "-framework Foundation" "-framework Security" "-framework Combine"
    "-framework CoreBluetooth" "-framework Network")
target_compile_options(RelaySetupKit PRIVATE -strict-concurrency=complete)
target_compile_options(RelaySetupKit PRIVATE "$<$<CONFIG:Debug>:-enable-testing>")
option(PLANK_ENABLE_TRANSPORT_TESTING "Temporary strict Bluetooth test selector" ON)
if(PLANK_ENABLE_TRANSPORT_TESTING)
    target_compile_options(RelaySetupKit PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:-DPLANK_TRANSPORT_TESTING>")
endif()
set_target_properties(CRelayProtocol RelaySetupKit PROPERTIES
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS "YES"
    XCODE_ATTRIBUTE_SKIP_INSTALL "YES")

add_executable(PlankTabletSetup MACOSX_BUNDLE
    Sources/TabletSetupApp.swift Sources/TabletSetupView.swift Sources/TabletReadingsView.swift Sources/RelayNetworkSettingsView.swift Sources/RelayWifiView.swift Sources/RelayTestTransportView.swift)
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

set(PLANK_SETUP_VERSION "${PROJECT_VERSION}-main")
set(PLANK_SETUP_BUILD_NUMBER "1" CACHE STRING "Monotonically increasing TestFlight build number")
if(NOT PLANK_SETUP_BUILD_NUMBER MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "PLANK_SETUP_BUILD_NUMBER must be a positive integer")
endif()
set(PLANK_DEVELOPMENT_TEAM "" CACHE STRING "Optional Apple development team; never hardcoded")
set(PLANK_SETUP_BUNDLE_ID "la.instinctual.PLANK.AVPrelay" CACHE STRING
    "Setup app identity; use TabletSetup only to update an existing development installation")
if(NOT PLANK_SETUP_BUNDLE_ID STREQUAL "la.instinctual.PLANK.AVPrelay" AND
   NOT PLANK_SETUP_BUNDLE_ID STREQUAL "la.instinctual.PLANK.TabletSetup")
    message(FATAL_ERROR "Unsupported PLANK_SETUP_BUNDLE_ID")
endif()
configure_file(DrawingRegistration.entitlements.in
    "${CMAKE_CURRENT_BINARY_DIR}/DrawingRegistration.entitlements" @ONLY)
set_target_properties(PlankTabletSetup PROPERTIES
    OUTPUT_NAME "PLANK AVP Relay Setup"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${PLANK_SETUP_BUNDLE_ID}"
    XCODE_ATTRIBUTE_PRODUCT_NAME "PLANK AVP Relay Setup"
    XCODE_ATTRIBUTE_MARKETING_VERSION "${PROJECT_VERSION}"
    XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "${PLANK_SETUP_BUILD_NUMBER}"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_BINARY_DIR}/DrawingRegistration.entitlements"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_SKIP_INSTALL "NO"
    XCODE_ATTRIBUTE_INSTALL_PATH "/Applications"
    XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT "dwarf-with-dsym"
    XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS "YES"
    XCODE_ATTRIBUTE_SWIFT_STRICT_CONCURRENCY "complete"
    XCODE_ATTRIBUTE_INFOPLIST_KEY_UIApplicationSceneManifest_Generation "YES"
    XCODE_ATTRIBUTE_INFOPLIST_KEY_UILaunchScreen_Generation "YES")
if(CMAKE_SYSTEM_NAME STREQUAL "visionOS")
    set(GENERATED_ASSETS "${CMAKE_CURRENT_BINARY_DIR}/generated/Assets.xcassets")
    file(COPY "${CMAKE_CURRENT_SOURCE_DIR}/Assets.xcassets/" DESTINATION "${GENERATED_ASSETS}")
    # visionOS layered icons require raster layers. Retain readable SVG source
    # and rasterize through the build Mac's native AppKit without new tools.
    execute_process(COMMAND xcrun --sdk macosx swift
        "${RELAY_ROOT}/scripts/render-tablet-setup-icon.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Artwork" "${GENERATED_ASSETS}"
        COMMAND_ERROR_IS_FATAL ANY)
    set_source_files_properties("${GENERATED_ASSETS}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
    target_sources(PlankTabletSetup PRIVATE "${GENERATED_ASSETS}")
    set_target_properties(PlankTabletSetup PROPERTIES
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "7"
        XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE "YES"
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon")
endif()
if(PLANK_DEVELOPMENT_TEAM)
    set_target_properties(PlankTabletSetup PROPERTIES
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${PLANK_DEVELOPMENT_TEAM}"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    enable_testing()
    add_executable(setup-preview Sources/PreviewMain.swift Sources/TabletSetupView.swift Sources/TabletReadingsView.swift Sources/RelayNetworkSettingsView.swift Sources/RelayWifiView.swift Sources/RelayTestTransportView.swift)
    target_include_directories(setup-preview PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(setup-preview PRIVATE RelaySetupKit "-framework SwiftUI" "-framework AppKit")
    add_executable(setup-state-tests
        "${RELAY_ROOT}/apple/RelaySetupKit/SetupState.swift"
        "${RELAY_ROOT}/apple/Tests/SetupStateTests.swift")
    target_link_libraries(setup-state-tests PRIVATE "-framework Foundation")
    add_test(NAME setup-state-tests COMMAND setup-state-tests)
    add_executable(relay-discovery-tests
        "${RELAY_ROOT}/apple/RelaySetupKit/RelayDiscovery.swift"
        "${RELAY_ROOT}/apple/Tests/RelayDiscoveryTests.swift")
    target_link_libraries(relay-discovery-tests PRIVATE "-framework Foundation")
    add_test(NAME relay-discovery-tests COMMAND relay-discovery-tests)
    add_executable(relay-connection-tests "${RELAY_ROOT}/apple/Tests/RelayConnectionTests.swift")
    target_include_directories(relay-connection-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-connection-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-connection-tests COMMAND relay-connection-tests)
    add_executable(relay-diagnostic-tests "${RELAY_ROOT}/apple/Tests/RelayDiagnosticTests.swift")
    target_include_directories(relay-diagnostic-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-diagnostic-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-diagnostic-tests COMMAND relay-diagnostic-tests)
    set_tests_properties(relay-diagnostic-tests PROPERTIES TIMEOUT 30)

    add_executable(relay-l2cap-stream-tests "${RELAY_ROOT}/apple/Tests/RelayL2CAPStreamTests.swift")
    target_include_directories(relay-l2cap-stream-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-l2cap-stream-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-l2cap-stream-tests COMMAND relay-l2cap-stream-tests)
    add_library(ManagementPeer STATIC "${RELAY_ROOT}/apple/Tests/ManagementPeer/ManagementPeer.c")
    target_include_directories(ManagementPeer PUBLIC "${RELAY_ROOT}/apple/Tests/ManagementPeer")
    target_link_libraries(ManagementPeer PUBLIC CRelayProtocol)
    add_executable(relay-management-tests "${RELAY_ROOT}/apple/Tests/RelayManagementTests.swift")
    target_include_directories(relay-management-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-management-tests PRIVATE RelaySetupKit ManagementPeer)
    add_test(NAME relay-management-tests COMMAND relay-management-tests)
    add_executable(relay-network-tests "${RELAY_ROOT}/apple/Tests/RelayNetworkTests.swift")
    target_include_directories(relay-network-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-network-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-network-tests COMMAND relay-network-tests)
    add_executable(relay-test-transport-tests "${RELAY_ROOT}/apple/Tests/RelayTestTransportTests.swift")
    target_include_directories(relay-test-transport-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-test-transport-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-test-transport-tests COMMAND relay-test-transport-tests)
    add_executable(relay-tablet-test-tests "${RELAY_ROOT}/apple/Tests/RelayTabletTestTests.swift")
    target_compile_options(relay-tablet-test-tests PRIVATE -parse-as-library)
    target_link_libraries(relay-tablet-test-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-tablet-test-tests COMMAND relay-tablet-test-tests)
    add_executable(relay-transport-scope-tests "${RELAY_ROOT}/apple/Tests/RelayTransportScopeTests.swift")
    target_include_directories(relay-transport-scope-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-transport-scope-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-transport-scope-tests COMMAND relay-transport-scope-tests)
    add_executable(relay-key-store-tests "${RELAY_ROOT}/apple/Tests/RelayKeyStoreTests.swift")
    target_include_directories(relay-key-store-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-key-store-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-key-store-tests COMMAND relay-key-store-tests)
    add_executable(tablet-readings-tests "${RELAY_ROOT}/apple/Tests/TabletReadingsTests.swift")
    target_include_directories(tablet-readings-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(tablet-readings-tests PRIVATE RelaySetupKit)
    add_test(NAME tablet-readings-tests COMMAND tablet-readings-tests)
    add_executable(tablet-management-tests "${RELAY_ROOT}/apple/Tests/TabletManagementTests.swift")
    target_include_directories(tablet-management-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(tablet-management-tests PRIVATE RelaySetupKit)
    add_test(NAME tablet-management-tests COMMAND tablet-management-tests)
    # plank-drawing-handoff-v1+r3. Vectors are loaded from the shared fixture
    # files, never embedded, so a contract revision breaks this test.
    add_executable(drawing-registration-tests "${RELAY_ROOT}/apple/Tests/DrawingRegistrationTests.swift")
    target_include_directories(drawing-registration-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(drawing-registration-tests PRIVATE RelaySetupKit)
    add_test(NAME drawing-registration-tests COMMAND drawing-registration-tests)
    set_tests_properties(drawing-registration-tests PROPERTIES ENVIRONMENT
        "PLANK_HANDOFF_FIXTURES=${RELAY_ROOT}/tests/fixtures/plank-drawing-handoff-v1")
    add_executable(drawing-handoff-tests "${RELAY_ROOT}/apple/Tests/DrawingHandoffTests.swift")
    target_include_directories(drawing-handoff-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(drawing-handoff-tests PRIVATE RelaySetupKit "-framework CryptoKit")
    add_test(NAME drawing-handoff-tests COMMAND drawing-handoff-tests)
    set_tests_properties(drawing-handoff-tests PROPERTIES ENVIRONMENT
        "PLANK_HANDOFF_FIXTURES=${RELAY_ROOT}/tests/fixtures/plank-drawing-handoff-v1")
    add_executable(drawing-transport-handoff-tests "${RELAY_ROOT}/apple/Tests/DrawingTransportHandoffTests.swift")
    target_include_directories(drawing-transport-handoff-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(drawing-transport-handoff-tests PRIVATE RelaySetupKit)
    add_test(NAME drawing-transport-handoff-tests COMMAND drawing-transport-handoff-tests)
    add_executable(relay-connection-labels-tests "${RELAY_ROOT}/apple/Tests/RelayConnectionLabelsTests.swift")
    target_include_directories(relay-connection-labels-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-connection-labels-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-connection-labels-tests COMMAND relay-connection-labels-tests)
    add_executable(relay-network-settings-tests "${RELAY_ROOT}/apple/Tests/RelayNetworkSettingsTests.swift")
    target_include_directories(relay-network-settings-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-network-settings-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-network-settings-tests COMMAND relay-network-settings-tests)
    add_executable(relay-background-refresh-tests "${RELAY_ROOT}/apple/Tests/RelayBackgroundRefreshTests.swift")
    target_include_directories(relay-background-refresh-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-background-refresh-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-background-refresh-tests COMMAND relay-background-refresh-tests)
    add_executable(relay-wifi-tests "${RELAY_ROOT}/apple/Tests/RelayWifiTests.swift")
    target_include_directories(relay-wifi-tests PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(relay-wifi-tests PRIVATE RelaySetupKit)
    add_test(NAME relay-wifi-tests COMMAND relay-wifi-tests)
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
