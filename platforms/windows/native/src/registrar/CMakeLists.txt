add_executable(RimesRegistrar
    main.cpp
)

target_compile_features(RimesRegistrar PRIVATE cxx_std_20)
target_compile_definitions(RimesRegistrar PRIVATE
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)
target_include_directories(RimesRegistrar PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(RimesRegistrar PRIVATE
    advapi32
    ole32
    oleaut32
    uuid
)

if(MSVC)
    target_compile_options(RimesRegistrar PRIVATE /W4 /WX /permissive- /utf-8)
endif()
