cmake_minimum_required(VERSION 3.22)

set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS version")
project(ClosureApp VERSION 0.2.4 LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(CLOSURE_ENABLE_UPDATES "Enable Sparkle updates on macOS" ${APPLE})

if(APPLE AND CLOSURE_ENABLE_UPDATES)
    string(CONCAT closure_update_plist
        "<plist version=\"1.0\"><dict>"
        "<key>SUFeedURL</key><string>https://github.com/qar/closureapp/releases/latest/download/appcast.xml</string>"
        "<key>SUPublicEDKey</key><string>t7lbMi9ZNG7+b7xFTu7Y8tREabGeD4iawEwZV1EBM5A=</string>"
        "<key>SUEnableAutomaticChecks</key><true/>"
        "<key>LSMinimumSystemVersion</key><string>11.0</string>"
        "</dict></plist>"
    )
endif()

add_subdirectory(external/JUCE)

juce_add_gui_app(ClosureApp
    PRODUCT_NAME "Closure"
    COMPANY_NAME "QAR"
    BUNDLE_ID "com.qar.closure"
    ICON_BIG "${CMAKE_CURRENT_SOURCE_DIR}/assets/ClosureIcon.png"
    PLIST_TO_MERGE "${closure_update_plist}"
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
        src/audio/AudioFileFormats.h
        src/audio/GaplessPlaylistSource.h
        src/audio/GaplessPlaylistSource.cpp
        src/audio/TrackMetadata.h
        src/audio/TrackMetadata.cpp
        src/audio/TrackMetadataReader.mm
        src/lyrics/LyricsClient.h
        src/lyrics/LyricsClient.cpp
        src/metadata/MusicBrainzClient.h
        src/metadata/MusicBrainzClient.cpp
        src/library/MusicLibrary.h
        src/library/MusicLibrary.cpp
        src/ui/AlbumBrowser.h
        src/ui/AlbumBrowser.cpp
        src/ui/icons/TransportIcons.h
        src/ui/icons/LUCIDE_LICENSE.txt
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

if(APPLE AND CLOSURE_ENABLE_UPDATES)
    include(FetchContent)
    FetchContent_Declare(sparkle
        URL "https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.9.0.tar.xz"
        URL_HASH "SHA256=01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19"
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(sparkle)

    target_sources(ClosureApp PRIVATE src/ui/MacUpdater.h src/ui/MacUpdater.mm)
    target_compile_definitions(ClosureApp PRIVATE CLOSURE_ENABLE_UPDATES=1)
    target_include_directories(ClosureApp PRIVATE "${sparkle_SOURCE_DIR}/Sparkle.framework/Headers")
    target_link_libraries(ClosureApp PRIVATE "${sparkle_SOURCE_DIR}/Sparkle.framework")
    set_property(TARGET ClosureApp APPEND PROPERTY LINK_DEPENDS
        "${sparkle_SOURCE_DIR}/Sparkle.framework/Sparkle")
    set_target_properties(ClosureApp PROPERTIES
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "@executable_path/../Frameworks"
    )

    add_custom_command(TARGET ClosureApp POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory
            "$<TARGET_BUNDLE_DIR:ClosureApp>/Contents/Frameworks"
        COMMAND "${CMAKE_COMMAND}" -E rm -rf
            "$<TARGET_BUNDLE_DIR:ClosureApp>/Contents/Frameworks/Sparkle.framework"
        COMMAND /usr/bin/ditto "${sparkle_SOURCE_DIR}/Sparkle.framework"
            "$<TARGET_BUNDLE_DIR:ClosureApp>/Contents/Frameworks/Sparkle.framework"
        COMMAND "${CMAKE_COMMAND}" -E copy
            "${sparkle_SOURCE_DIR}/LICENSE"
            "$<TARGET_BUNDLE_DIR:ClosureApp>/Contents/Resources/Sparkle-LICENSE.txt"
        VERBATIM
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
            src/audio/AudioFileFormats.h
            src/audio/TrackMetadata.h
            src/audio/TrackMetadata.cpp
            src/audio/TrackMetadataReader.mm
            src/lyrics/LyricsClient.h
            src/lyrics/LyricsClient.cpp
            src/metadata/MusicBrainzClient.h
            src/metadata/MusicBrainzClient.cpp
            src/library/MusicLibrary.h
            src/library/MusicLibrary.cpp
            src/ui/AlbumBrowser.h
            src/ui/AlbumBrowser.cpp
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
            juce::juce_gui_basics
        PUBLIC
            juce::juce_recommended_config_flags
             juce::juce_recommended_warning_flags
    )

    if(APPLE)
        target_link_libraries(ClosureAudioTests PRIVATE "-framework AVFoundation")
    endif()

    add_test(NAME ClosureAudioTests COMMAND ClosureAudioTests)
endif()
