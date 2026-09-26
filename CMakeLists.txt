cmake_minimum_required(VERSION 3.20)
project(plank_tablet_relay LANGUAGES C)

enable_testing()
add_library(plank_relay_protocol STATIC src/protocol.c)
target_include_directories(plank_relay_protocol PUBLIC src)
target_compile_features(plank_relay_protocol PUBLIC c_std_11)

add_executable(protocol_test tests/protocol_test.c)
target_link_libraries(protocol_test PRIVATE plank_relay_protocol)
add_test(NAME protocol_test COMMAND protocol_test)
