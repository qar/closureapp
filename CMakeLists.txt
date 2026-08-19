cmake_minimum_required(VERSION 3.22)

project(ClosureApp VERSION 0.1.0 LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS version")

add_subdirectory(external/JUCE)

juce_add_gui_app(ClosureApp
    PRODUCT_NAME "Closure"
    COMPANY_NAME "QAR"
    BUNDLE_ID "com.qar.closure"
    NEEDS_WEB_BROWSER FALSE
    NEEDS_CURL FALSE
    DOCUMENT_EXTENSIONS mp3 flac wav aiff aif m4a alac ogg
)

juce_generate_juce_header(ClosureApp)

target_sources(ClosureApp
    PRIVATE
        src/Main.cpp
        src/MainComponent.h
        src/MainComponent.cpp
        src/audio/AudioEngine.h
        src/audio/AudioEngine.cpp
        src/audio/GaplessPlaylistSource.h
        src/audio/GaplessPlaylistSource.cpp
        src/audio/TrackMetadata.h
        src/audio/TrackMetadata.cpp
        src/audio/TrackMetadataReader.mm
        src/ui/GlassLookAndFeel.h
        src/ui/GlassLookAndFeel.cpp
        src/ui/PlayerPanel.h
        src/ui/PlayerPanel.cpp
        src/ui/MacGlassWindow.h
        src/ui/MacGlassWindow.mm
)

target_include_directories(ClosureApp PRIVATE src)

target_compile_definitions(ClosureApp
    PRIVATE
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
        JUCE_APPLICATION_NAME_STRING="$<TARGET_PROPERTY:ClosureApp,JUCE_PRODUCT_NAME>"
        JUCE_APPLICATION_VERSION_STRING="$<TARGET_PROPERTY:ClosureApp,JUCE_VERSION>"
        JUCE_USE_MP3AUDIOFORMAT=1
)

target_link_libraries(ClosureApp
    PRIVATE
        juce::juce_audio_basics
        juce::juce_audio_devices
        juce::juce_audio_formats
        juce::juce_audio_utils
        juce::juce_core
        juce::juce_data_structures
        juce::juce_dsp
        juce::juce_events
        juce::juce_graphics
        juce::juce_gui_basics
        juce::juce_gui_extra
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags
)

if(APPLE)
    target_link_libraries(ClosureApp PRIVATE
        "-framework AppKit"
        "-framework AVFoundation"
    )
endif()

option(CLOSURE_BUILD_TESTS "Build Closure audio tests" OFF)

if(CLOSURE_BUILD_TESTS)
    enable_testing()

    juce_add_console_app(ClosureAudioTests
        PRODUCT_NAME "Closure Audio Tests"
        NEEDS_WEB_BROWSER FALSE
        NEEDS_CURL FALSE
    )

    juce_generate_juce_header(ClosureAudioTests)

    target_sources(ClosureAudioTests
        PRIVATE
            tests/GaplessPlaylistSourceTests.cpp
            src/audio/GaplessPlaylistSource.h
            src/audio/GaplessPlaylistSource.cpp
            src/audio/TrackMetadata.h
            src/audio/TrackMetadata.cpp
    )

    target_include_directories(ClosureAudioTests PRIVATE src)

    target_compile_definitions(ClosureAudioTests
        PRIVATE
            JUCE_WEB_BROWSER=0
            JUCE_USE_CURL=0
            JUCE_USE_MP3AUDIOFORMAT=1
    )

    target_link_libraries(ClosureAudioTests
        PRIVATE
            juce::juce_audio_basics
            juce::juce_audio_devices
            juce::juce_audio_formats
            juce::juce_core
            juce::juce_graphics
        PUBLIC
            juce::juce_recommended_config_flags
            juce::juce_recommended_warning_flags
    )

    add_test(NAME ClosureAudioTests COMMAND ClosureAudioTests)
endif()
