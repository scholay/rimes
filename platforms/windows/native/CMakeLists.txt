cmake_minimum_required(VERSION 3.27)

project(RIMESWindows VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "The native RIMES frontend currently builds on Windows only.")
endif()

option(RIMES_BUILD_TESTS "Build the native Windows foundation tests" ON)
option(RIMES_TSF_DIAGNOSTICS
       "Write privacy-preserving TSF stage codes to the user's temp directory"
       OFF)

include(CTest)

# Keep every runnable artifact together so architecture checks, registration,
# and later packaging never need to guess target-specific subdirectories.
foreach(configuration DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_${configuration}
        "${CMAKE_BINARY_DIR}/$<CONFIG>")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_${configuration}
        "${CMAKE_BINARY_DIR}/$<CONFIG>")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_${configuration}
        "${CMAKE_BINARY_DIR}/$<CONFIG>")
endforeach()

function(rimes_harden_target target)
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_compile_definitions(${target} PRIVATE
        UNICODE
        _UNICODE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        _WIN32_WINNT=0x0A00
        WINVER=0x0A00
    )

    if(MSVC)
        target_compile_options(${target} PRIVATE
            /W4
            /WX
            /permissive-
            /utf-8
            /sdl
            /guard:cf
            /Zc:__cplusplus
            /Zc:inline
            /Zc:preprocessor
        )
        target_link_options(${target} PRIVATE
            /DYNAMICBASE
            /NXCOMPAT
            /guard:cf
        )
        set_property(TARGET ${target} PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
    endif()
endfunction()

# MinGW does not infer its Unicode console CRT startup object from a wmain
# definition. MSVC selects it automatically, so keep this narrowly scoped to
# executable targets whose source entry point is wmain.
function(rimes_use_unicode_console_entrypoint target)
    if(MINGW)
        target_link_options(${target} PRIVATE -municode)
    endif()
endfunction()

add_library(RimesCore STATIC
    src/core/broker_protocol.cpp
)
target_include_directories(RimesCore PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src/core"
)
rimes_harden_target(RimesCore)

add_library(RimesEngine STATIC
    src/engine/rime_engine.cpp
    src/engine/rime_snapshot.cpp
)
target_include_directories(RimesEngine PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src/engine"
)
target_link_libraries(RimesEngine PUBLIC RimesCore)
rimes_harden_target(RimesEngine)

add_executable(RimesBroker
    src/broker/broker_connection.cpp
    src/broker/broker_options.cpp
    src/broker/key_translation.cpp
    src/broker/main.cpp
    src/broker/named_pipe_server.cpp
    src/broker/single_instance.cpp
    src/broker/win32_security.cpp
)
target_include_directories(RimesBroker PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src/broker"
)
target_link_libraries(RimesBroker PRIVATE
    RimesCore
    RimesEngine
    advapi32
)
rimes_harden_target(RimesBroker)
rimes_use_unicode_console_entrypoint(RimesBroker)

add_library(RimesTsf SHARED
    src/tsf/BrokerClient.cpp
    src/tsf/ClassFactory.cpp
    src/tsf/DllMain.cpp
    src/tsf/Exports.cpp
    src/tsf/ModuleState.cpp
    src/tsf/TextService.cpp
    src/tsf/RimesTsf.def
)
target_include_directories(RimesTsf PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src/tsf"
)
target_link_libraries(RimesTsf PRIVATE
    RimesCore
    ole32
    uuid
)
set_target_properties(RimesTsf PROPERTIES
    PREFIX ""
    OUTPUT_NAME "RimesTsf"
)
rimes_harden_target(RimesTsf)
if(RIMES_TSF_DIAGNOSTICS)
    target_sources(RimesTsf PRIVATE src/tsf/Diagnostics.cpp)
    target_compile_definitions(RimesTsf PRIVATE RIMES_TSF_DIAGNOSTICS=1)
endif()
if(MINGW AND CMAKE_SIZEOF_VOID_P EQUAL 4)
    # The .def deliberately publishes undecorated COM entry points. On Win32,
    # MinGW resolves them to the stdcall-decorated implementations; spelling
    # out the supported fixup keeps that intentional alias warning-free.
    target_link_options(RimesTsf PRIVATE
        "LINKER:--enable-stdcall-fixup"
    )
endif()

add_subdirectory(src/registrar)
rimes_harden_target(RimesRegistrar)
rimes_use_unicode_console_entrypoint(RimesRegistrar)

if(RIMES_BUILD_TESTS)
    add_executable(RimesBrokerProtocolTests
        src/core/broker_protocol_tests.cpp
    )
    target_compile_definitions(RimesBrokerProtocolTests PRIVATE
        RIMES_BROKER_PROTOCOL_TEST_MAIN
    )
    target_link_libraries(RimesBrokerProtocolTests PRIVATE RimesCore)
    rimes_harden_target(RimesBrokerProtocolTests)

    add_executable(RimesEngineTests
        src/engine/rime_engine_tests.cpp
    )
    target_link_libraries(RimesEngineTests PRIVATE RimesEngine)
    rimes_harden_target(RimesEngineTests)

    add_executable(RimesEngineSmoke
        src/engine/rime_engine_smoke.cpp
    )
    target_link_libraries(RimesEngineSmoke PRIVATE RimesEngine)
    rimes_harden_target(RimesEngineSmoke)
    rimes_use_unicode_console_entrypoint(RimesEngineSmoke)

    add_executable(RimesBrokerKeyTranslationTests
        src/broker/key_translation.cpp
        src/broker/key_translation_tests.cpp
    )
    target_compile_definitions(RimesBrokerKeyTranslationTests PRIVATE
        RIMES_KEY_TRANSLATION_TEST_MAIN
    )
    target_link_libraries(RimesBrokerKeyTranslationTests PRIVATE RimesCore)
    rimes_harden_target(RimesBrokerKeyTranslationTests)

    add_executable(RimesBrokerOptionsTests
        src/broker/broker_options.cpp
        src/broker/broker_options_tests.cpp
    )
    target_link_libraries(RimesBrokerOptionsTests PRIVATE RimesCore)
    rimes_harden_target(RimesBrokerOptionsTests)
    rimes_use_unicode_console_entrypoint(RimesBrokerOptionsTests)

    # Live end-to-end probe. It deliberately is not a default CTest because it
    # requires an already-running Broker configured with real librime data.
    add_executable(RimesBrokerWireSmoke
        src/broker/wire_smoke.cpp
        src/broker/win32_security.cpp
    )
    target_link_libraries(RimesBrokerWireSmoke PRIVATE
        RimesCore
        advapi32
    )
    rimes_harden_target(RimesBrokerWireSmoke)
    rimes_use_unicode_console_entrypoint(RimesBrokerWireSmoke)

    # Small native edit host used for interactive TSF verification without
    # touching a user's documents or depending on Notepad's process reuse.
    add_executable(RimesTsfTestHost WIN32
        src/test_host/main.cpp
    )
    target_link_libraries(RimesTsfTestHost PRIVATE user32)
    rimes_harden_target(RimesTsfTestHost)

    add_test(NAME RimesBrokerProtocol COMMAND RimesBrokerProtocolTests)
    add_test(NAME RimesEngineUnit COMMAND RimesEngineTests)
    add_test(NAME RimesBrokerKeyTranslation
             COMMAND RimesBrokerKeyTranslationTests)
    add_test(NAME RimesBrokerOptions COMMAND RimesBrokerOptionsTests)
    add_test(NAME RimesRegistrarMetadata COMMAND RimesRegistrar metadata)
    add_test(NAME RimesBrokerEndpoint COMMAND RimesBroker --print-endpoint)

    set_tests_properties(
        RimesBrokerProtocol
        RimesEngineUnit
        RimesBrokerKeyTranslation
        RimesBrokerOptions
        RimesRegistrarMetadata
        RimesBrokerEndpoint
        PROPERTIES TIMEOUT 10
    )
endif()
