cmake_minimum_required(VERSION 3.22)

project(ClosureCore VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(CLOSURE_CORE_TSAN "Build with ThreadSanitizer" OFF)

add_library(closure_core STATIC
    include/closure/PlaybackEngine.h
    src/AudioOutput.h
    src/AudioOutput.cpp
    src/FrameRing.h
    src/PlaybackEngine.cpp
    src/TrackDecoder.h
    src/TrackDecoder.cpp
)

target_include_directories(closure_core PUBLIC include PRIVATE src)
target_compile_options(closure_core PRIVATE -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion)
target_link_libraries(closure_core PUBLIC "-framework AudioToolbox" "-framework CoreFoundation")

if(CLOSURE_CORE_TSAN)
    target_compile_options(closure_core PUBLIC -fsanitize=thread -g)
    target_link_options(closure_core PUBLIC -fsanitize=thread)
endif()

enable_testing()

add_executable(closure_core_tests tests/PlaybackEngineTests.cpp)
target_link_libraries(closure_core_tests PRIVATE closure_core)
add_test(NAME closure_core_tests COMMAND closure_core_tests)

add_executable(closure-play tools/closure_play.cpp)
target_link_libraries(closure-play PRIVATE closure_core)
