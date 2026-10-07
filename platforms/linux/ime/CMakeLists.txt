cmake_minimum_required(VERSION 3.16)

project(RIMESLinuxIme VERSION 0.1.0 LANGUAGES C CXX)

option(RIMES_BUILD_FCITX5 "Build the Fcitx5 RIMES addon" ON)
option(RIMES_BUILD_TESTS "Build unit tests and headless E2E hosts" ON)
option(RIMES_BUILD_QT_HOST "Build the Qt E2E host when Qt5 is available" ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_C_STANDARD 11)

include(GNUInstallDirs)
include(CTest)

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
pkg_check_modules(Rime REQUIRED IMPORTED_TARGET rime>=1.7.0)

set(RIMES_BUFFER_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../buffer")
set(RIMES_CAPSULE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../capsule")

function(rimes_harden target)
    target_compile_options(${target} PRIVATE
        -Wall
        -Wextra
        -Wpedantic
        -Werror
        -Wno-missing-field-initializers
    )
endfunction()

add_library(RimesBufferCore STATIC
    "${RIMES_BUFFER_ROOT}/core/buffer_ids.cpp"
    "${RIMES_BUFFER_ROOT}/core/buffer_model.cpp"
    "${RIMES_BUFFER_ROOT}/core/buffer_placement.cpp"
    "${RIMES_BUFFER_ROOT}/core/buffer_process.cpp"
    "${RIMES_BUFFER_ROOT}/core/buffer_protocol.cpp"
    "${RIMES_BUFFER_ROOT}/core/buffer_return.cpp"
)
target_include_directories(RimesBufferCore PUBLIC
    "${RIMES_BUFFER_ROOT}/core"
)
set_target_properties(RimesBufferCore PROPERTIES POSITION_INDEPENDENT_CODE ON)
rimes_harden(RimesBufferCore)

add_library(RimesCapsuleCore STATIC
    "${RIMES_CAPSULE_ROOT}/core/capsule_hash.cpp"
    "${RIMES_CAPSULE_ROOT}/core/capsule_kinds.cpp"
    "${RIMES_CAPSULE_ROOT}/core/capsule_store.cpp"
    "${RIMES_CAPSULE_ROOT}/core/capsule_model.cpp"
    "${RIMES_CAPSULE_ROOT}/core/capsule_protocol.cpp"
    "${RIMES_CAPSULE_ROOT}/core/capsule_clipboard.cpp"
)
target_include_directories(RimesCapsuleCore PUBLIC
    "${RIMES_CAPSULE_ROOT}/core"
    "${RIMES_BUFFER_ROOT}/core"
)
target_link_libraries(RimesCapsuleCore PUBLIC RimesBufferCore)
set_target_properties(RimesCapsuleCore PROPERTIES POSITION_INDEPENDENT_CODE ON)
rimes_harden(RimesCapsuleCore)

add_library(RimesEngine STATIC
    src/engine/rime_engine.cpp
    src/engine/rime_key.cpp
    src/engine/rime_paths.cpp
    src/engine/rime_snapshot.cpp
    src/engine/rime_user_lock.cpp
)
target_include_directories(RimesEngine PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)
target_link_libraries(RimesEngine PUBLIC PkgConfig::Rime Threads::Threads)
set_target_properties(RimesEngine PROPERTIES POSITION_INDEPENDENT_CODE ON)
rimes_harden(RimesEngine)

if(RIMES_BUILD_FCITX5)
    find_package(Gettext REQUIRED)
    find_package(Fcitx5Core REQUIRED)
    find_package(Fcitx5Module REQUIRED COMPONENTS TestFrontend)
    include("${FCITX_INSTALL_CMAKECONFIG_DIR}/Fcitx5Utils/Fcitx5CompilerSettings.cmake")

    add_library(rimes MODULE
        src/fcitx/rimes_candidate.cpp
        src/fcitx/rimes_ime.cpp
        src/fcitx/rimes_state.cpp
        src/buffer/buffer_service.cpp
        src/capsule/capsule_service.cpp
    )
    target_link_libraries(rimes PRIVATE Fcitx5::Core RimesEngine RimesBufferCore RimesCapsuleCore)
    target_compile_definitions(rimes PRIVATE
        RIMES_INSTALL_SHARED_DIR="${CMAKE_INSTALL_FULL_DATADIR}/rimes/data"
    )
    set_target_properties(rimes PROPERTIES
        PREFIX ""
        OUTPUT_NAME "rimes"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
    rimes_harden(rimes)

    configure_file(
        data/rimes-addon.conf.in
        "${CMAKE_BINARY_DIR}/rimes-addon.conf"
        @ONLY
    )
    configure_file(
        data/rimes.conf.in
        "${CMAKE_BINARY_DIR}/rimes.conf"
        COPYONLY
    )
    configure_file(
        data/org.fcitx.Fcitx5.Addon.Rimes.metainfo.xml.in
        "${CMAKE_BINARY_DIR}/org.fcitx.Fcitx5.Addon.Rimes.metainfo.xml"
        @ONLY
    )

    install(TARGETS rimes DESTINATION "${FCITX_INSTALL_ADDONDIR}")
    install(FILES "${CMAKE_BINARY_DIR}/rimes-addon.conf"
            RENAME rimes.conf
            DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
    install(FILES "${CMAKE_BINARY_DIR}/rimes.conf"
            DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
    install(FILES "${CMAKE_BINARY_DIR}/org.fcitx.Fcitx5.Addon.Rimes.metainfo.xml"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/metainfo")
    # Matches Icon=rimes in the Fcitx input-method descriptor and GTK windows.
    install(DIRECTORY data/icons/hicolor
            DESTINATION "${CMAKE_INSTALL_DATADIR}/icons")

    pkg_check_modules(GTK3 gtk+-3.0)
    if(GTK3_FOUND)
        pkg_check_modules(GTK_LAYER_SHELL gtk-layer-shell-0)
        add_executable(rimes-buffer
            "${RIMES_BUFFER_ROOT}/ui/rimes_buffer_app.cpp"
        )
        target_include_directories(rimes-buffer PRIVATE ${GTK3_INCLUDE_DIRS})
        target_link_libraries(rimes-buffer PRIVATE RimesBufferCore ${GTK3_LIBRARIES})
        target_compile_options(rimes-buffer PRIVATE ${GTK3_CFLAGS_OTHER})
        if(GTK_LAYER_SHELL_FOUND)
            target_include_directories(rimes-buffer PRIVATE ${GTK_LAYER_SHELL_INCLUDE_DIRS})
            target_link_libraries(rimes-buffer PRIVATE ${GTK_LAYER_SHELL_LIBRARIES})
            target_compile_options(rimes-buffer PRIVATE ${GTK_LAYER_SHELL_CFLAGS_OTHER})
            target_compile_definitions(rimes-buffer PRIVATE HAVE_GTK_LAYER_SHELL=1)
        endif()
        rimes_harden(rimes-buffer)
        set_target_properties(rimes-buffer PROPERTIES
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
        )
        install(TARGETS rimes-buffer DESTINATION "${CMAKE_INSTALL_LIBEXECDIR}/rimes")
        install(TARGETS rimes-buffer DESTINATION "${CMAKE_INSTALL_BINDIR}")

        add_executable(rimes-capsule
            "${RIMES_CAPSULE_ROOT}/ui/rimes_capsule_app.cpp"
        )
        target_include_directories(rimes-capsule PRIVATE ${GTK3_INCLUDE_DIRS})
        target_link_libraries(rimes-capsule PRIVATE RimesCapsuleCore ${GTK3_LIBRARIES})
        target_compile_options(rimes-capsule PRIVATE ${GTK3_CFLAGS_OTHER})
        if(GTK_LAYER_SHELL_FOUND)
            target_include_directories(rimes-capsule PRIVATE ${GTK_LAYER_SHELL_INCLUDE_DIRS})
            target_link_libraries(rimes-capsule PRIVATE ${GTK_LAYER_SHELL_LIBRARIES})
            target_compile_options(rimes-capsule PRIVATE ${GTK_LAYER_SHELL_CFLAGS_OTHER})
            target_compile_definitions(rimes-capsule PRIVATE HAVE_GTK_LAYER_SHELL=1)
        endif()
        rimes_harden(rimes-capsule)
        set_target_properties(rimes-capsule PROPERTIES
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
        )
        install(TARGETS rimes-capsule DESTINATION "${CMAKE_INSTALL_LIBEXECDIR}/rimes")
        install(TARGETS rimes-capsule DESTINATION "${CMAKE_INSTALL_BINDIR}")
    endif()

    add_executable(rimes-buffer-ctl
        "${RIMES_BUFFER_ROOT}/ctl/rimes_buffer_ctl.cpp"
    )
    target_link_libraries(rimes-buffer-ctl PRIVATE RimesBufferCore)
    rimes_harden(rimes-buffer-ctl)
    set_target_properties(rimes-buffer-ctl PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
    install(TARGETS rimes-buffer-ctl DESTINATION "${CMAKE_INSTALL_BINDIR}")

    add_executable(rimes-capsule-ctl
        "${RIMES_CAPSULE_ROOT}/ctl/rimes_capsule_ctl.cpp"
    )
    target_link_libraries(rimes-capsule-ctl PRIVATE RimesCapsuleCore)
    rimes_harden(rimes-capsule-ctl)
    set_target_properties(rimes-capsule-ctl PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
    install(TARGETS rimes-capsule-ctl DESTINATION "${CMAKE_INSTALL_BINDIR}")
endif()

if(RIMES_BUILD_TESTS)
    add_executable(rimes-key-tests tests/rime_key_tests.cpp)
    target_link_libraries(rimes-key-tests PRIVATE RimesEngine)
    rimes_harden(rimes-key-tests)

    add_executable(rimes-snapshot-tests tests/rime_snapshot_tests.cpp)
    target_link_libraries(rimes-snapshot-tests PRIVATE RimesEngine)
    rimes_harden(rimes-snapshot-tests)

    add_executable(rimes-paths-tests tests/rime_paths_tests.cpp)
    target_link_libraries(rimes-paths-tests PRIVATE RimesEngine)
    rimes_harden(rimes-paths-tests)

    add_executable(rimes-user-lock-tests tests/rime_user_lock_tests.cpp)
    target_link_libraries(rimes-user-lock-tests PRIVATE RimesEngine)
    rimes_harden(rimes-user-lock-tests)
    add_test(NAME RimesUserLock COMMAND rimes-user-lock-tests)

    add_executable(rimes-engine-smoke tests/rime_engine_smoke.cpp)
    target_link_libraries(rimes-engine-smoke PRIVATE RimesEngine)
    rimes_harden(rimes-engine-smoke)

    add_executable(rimes-buffer-model-tests
        "${RIMES_BUFFER_ROOT}/tests/buffer_model_tests.cpp"
    )
    target_link_libraries(rimes-buffer-model-tests PRIVATE RimesBufferCore)
    rimes_harden(rimes-buffer-model-tests)

    add_executable(rimes-buffer-return-tests
        "${RIMES_BUFFER_ROOT}/tests/buffer_return_tests.cpp"
    )
    target_link_libraries(rimes-buffer-return-tests PRIVATE RimesBufferCore)
    rimes_harden(rimes-buffer-return-tests)

    add_executable(rimes-buffer-protocol-tests
        "${RIMES_BUFFER_ROOT}/tests/buffer_protocol_tests.cpp"
    )
    target_link_libraries(rimes-buffer-protocol-tests PRIVATE RimesBufferCore)
    rimes_harden(rimes-buffer-protocol-tests)

    add_executable(rimes-buffer-process-tests
        "${RIMES_BUFFER_ROOT}/tests/buffer_process_tests.cpp"
    )
    target_link_libraries(rimes-buffer-process-tests PRIVATE RimesBufferCore)
    rimes_harden(rimes-buffer-process-tests)

    add_executable(rimes-buffer-placement-tests
        "${RIMES_BUFFER_ROOT}/tests/buffer_placement_tests.cpp"
    )
    target_link_libraries(rimes-buffer-placement-tests PRIVATE RimesBufferCore)
    rimes_harden(rimes-buffer-placement-tests)

    add_test(NAME RimesKey COMMAND rimes-key-tests)
    add_test(NAME RimesSnapshot COMMAND rimes-snapshot-tests)
    add_test(NAME RimesPaths COMMAND rimes-paths-tests)
    add_test(NAME RimesBufferModel COMMAND rimes-buffer-model-tests)
    add_test(NAME RimesBufferReturn COMMAND rimes-buffer-return-tests)
    add_test(NAME RimesBufferProtocol COMMAND rimes-buffer-protocol-tests)
    add_test(NAME RimesBufferProcess COMMAND rimes-buffer-process-tests)
    add_test(NAME RimesBufferPlacement COMMAND rimes-buffer-placement-tests)

    add_executable(rimes-capsule-store-tests
        "${RIMES_CAPSULE_ROOT}/tests/capsule_store_tests.cpp"
    )
    target_link_libraries(rimes-capsule-store-tests PRIVATE RimesCapsuleCore)
    rimes_harden(rimes-capsule-store-tests)

    add_executable(rimes-capsule-model-tests
        "${RIMES_CAPSULE_ROOT}/tests/capsule_model_tests.cpp"
    )
    target_link_libraries(rimes-capsule-model-tests PRIVATE RimesCapsuleCore)
    rimes_harden(rimes-capsule-model-tests)

    add_executable(rimes-capsule-protocol-tests
        "${RIMES_CAPSULE_ROOT}/tests/capsule_protocol_tests.cpp"
    )
    target_link_libraries(rimes-capsule-protocol-tests PRIVATE RimesCapsuleCore)
    rimes_harden(rimes-capsule-protocol-tests)

    add_executable(rimes-capsule-click-tests
        "${RIMES_CAPSULE_ROOT}/tests/capsule_click_tests.cpp"
    )
    target_link_libraries(rimes-capsule-click-tests PRIVATE RimesCapsuleCore)
    rimes_harden(rimes-capsule-click-tests)

    add_executable(rimes-capsule-clipboard-tests
        "${RIMES_CAPSULE_ROOT}/tests/capsule_clipboard_tests.cpp"
    )
    target_link_libraries(rimes-capsule-clipboard-tests PRIVATE RimesCapsuleCore)
    rimes_harden(rimes-capsule-clipboard-tests)

    add_test(NAME RimesCapsuleStore COMMAND rimes-capsule-store-tests)
    add_test(NAME RimesCapsuleModel COMMAND rimes-capsule-model-tests)
    add_test(NAME RimesCapsuleProtocol COMMAND rimes-capsule-protocol-tests)
    add_test(NAME RimesCapsuleClick COMMAND rimes-capsule-click-tests)
    add_test(NAME RimesCapsuleClipboard COMMAND rimes-capsule-clipboard-tests)

    pkg_check_modules(GTK3 gtk+-3.0)
    if(GTK3_FOUND)
        add_executable(rimes-gtk-host tests/e2e/gtk_host.c)
        target_include_directories(rimes-gtk-host PRIVATE ${GTK3_INCLUDE_DIRS})
        target_link_libraries(rimes-gtk-host PRIVATE ${GTK3_LIBRARIES})
        target_compile_options(rimes-gtk-host PRIVATE ${GTK3_CFLAGS_OTHER})
    endif()

    if(RIMES_BUILD_QT_HOST)
        find_package(Qt5 QUIET COMPONENTS Widgets)
        if(Qt5Widgets_FOUND)
            add_executable(rimes-qt-host tests/e2e/qt_host.cpp)
            target_link_libraries(rimes-qt-host PRIVATE Qt5::Widgets)
            set_target_properties(rimes-qt-host PROPERTIES
                AUTOMOC OFF
            )
        endif()
    endif()

    if(RIMES_BUILD_FCITX5)
        add_executable(rimes-fcitx-e2e tests/fcitx_e2e.cpp)
        target_link_libraries(rimes-fcitx-e2e PRIVATE
            Fcitx5::Core
            Fcitx5::Module::TestFrontend
            RimesEngine
        )
        rimes_harden(rimes-fcitx-e2e)

        add_executable(rimes-buffer-fcitx-e2e tests/buffer_fcitx_e2e.cpp)
        target_link_libraries(rimes-buffer-fcitx-e2e PRIVATE
            Fcitx5::Core
            Fcitx5::Module::TestFrontend
            RimesEngine
            RimesBufferCore
        )
        rimes_harden(rimes-buffer-fcitx-e2e)

        add_executable(rimes-buffer-ui-stub tests/buffer_ui_stub.cpp)
        target_link_libraries(rimes-buffer-ui-stub PRIVATE RimesBufferCore)
        rimes_harden(rimes-buffer-ui-stub)
        set_target_properties(rimes-buffer-ui-stub PROPERTIES
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
        )

        add_executable(rimes-buffer-respawn-e2e tests/buffer_respawn_e2e.cpp)
        target_link_libraries(rimes-buffer-respawn-e2e PRIVATE
            Fcitx5::Core
            Fcitx5::Module::TestFrontend
            RimesEngine
            RimesBufferCore
        )
        rimes_harden(rimes-buffer-respawn-e2e)

        add_executable(rimes-capsule-fcitx-e2e tests/capsule_fcitx_e2e.cpp)
        target_link_libraries(rimes-capsule-fcitx-e2e PRIVATE
            Fcitx5::Core
            Fcitx5::Module::TestFrontend
            RimesEngine
            RimesCapsuleCore
        )
        rimes_harden(rimes-capsule-fcitx-e2e)

        add_executable(rimes-capsule-ui-stub tests/capsule_ui_stub.cpp)
        target_link_libraries(rimes-capsule-ui-stub PRIVATE RimesCapsuleCore)
        rimes_harden(rimes-capsule-ui-stub)
        set_target_properties(rimes-capsule-ui-stub PROPERTIES
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
        )

        add_executable(rimes-capsule-respawn-e2e tests/capsule_respawn_e2e.cpp)
        target_link_libraries(rimes-capsule-respawn-e2e PRIVATE
            Fcitx5::Core
            Fcitx5::Module::TestFrontend
            RimesEngine
            RimesCapsuleCore
        )
        rimes_harden(rimes-capsule-respawn-e2e)

        # Layout expected by fcitx::setupTestingEnvironment.
        # setupTestingEnvironment treats each data dir as an fcitx5 data root,
        # so addon/ and inputmethod/ sit directly under test-data/.
        file(MAKE_DIRECTORY
            "${CMAKE_BINARY_DIR}/test-data/addon"
            "${CMAKE_BINARY_DIR}/test-data/inputmethod"
        )
        add_custom_command(TARGET rimes POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy
                "${CMAKE_BINARY_DIR}/rimes-addon.conf"
                "${CMAKE_BINARY_DIR}/test-data/addon/rimes.conf"
            COMMAND "${CMAKE_COMMAND}" -E copy
                "${CMAKE_BINARY_DIR}/rimes.conf"
                "${CMAKE_BINARY_DIR}/test-data/inputmethod/rimes.conf"
        )
    endif()
endif()
