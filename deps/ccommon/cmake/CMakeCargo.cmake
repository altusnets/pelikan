# ccommon - a cache common library.
# Copyright (C) 2019 Twitter, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Get the target that we want to pass to cargo
function(cargo_build_private_get_target TARGET_VAR)
    if(WIN32)
        if(CMAKE_SIZEOF_VOID_P EQUAL 8)
            set(LIB_TARGET "x86_64-pc-windows-msvc")
        else()
            set(LIB_TARGET "i686-pc-windows-msvc")
        endif()
    elseif(ANDROID)
        if(ANDROID_SYSROOT_ABI STREQUAL "x86")
            set(LIB_TARGET "i686-linux-android")
        elseif(ANDROID_SYSROOT_ABI STREQUAL "x86_64")
            set(LIB_TARGET "x86_64-linux-android")
        elseif(ANDROID_SYSROOT_ABI STREQUAL "arm")
            set(LIB_TARGET "arm-linux-androideabi")
        elseif(ANDROID_SYSROOT_ABI STREQUAL "arm64")
            set(LIB_TARGET "aarch64-linux-android")
        endif()
    elseif(IOS)
        set(LIB_TARGET "universal")
    elseif(CMAKE_SYSTEM_NAME STREQUAL Darwin)
        set(LIB_TARGET "x86_64-apple-darwin")
    else()
        if(CMAKE_SIZEOF_VOID_P EQUAL 8)
            set(LIB_TARGET "x86_64-unknown-linux-gnu")
        else()
            set(LIB_TARGET "i686-unknown-linux-gnu")
        endif()
    endif()

    set(${TARGET_VAR} ${LIB_TARGET} PARENT_SCOPE)
endfunction()

# Get whether to build in release or debug mode
function(cargo_build_private_get_build_type TARGET_VAR)
    if(NOT CMAKE_BUILD_TYPE)
        set(${TARGET_VAR} "debug" PARENT_SCOPE)
    elseif(${CMAKE_BUILD_TYPE} STREQUAL "Release")
        set(${TARGET_VAR} "release" PARENT_SCOPE)
    else()
        set(${TARGET_VAR} "debug" PARENT_SCOPE)
    endif()
endfunction()

# Create a set of targets to invoke cargo and pass in
# the required linker flags. This is meant to be run
# in the same directory as the Cargo.toml file for the
# library.
#
# In all cases, the target can be used as if it was defined
# through the add_executable or add_binary. In addition,
# library dependencies will be properly passed through.
#
# Arguments:
#   NAME <lib-name>
#       The library package name as specified in Cargo.toml.
#       This argument is required.
#   TARGET_DIR <dir>
#       Overrides the default directory for the cargo target
#       directory which is ${CMAKE_BINARY_DIR}/target.
#   BIN
#       Indicates that this crate generated a binary and to
#       expose that binary file as a target.
#   STATIC
#       Indicates this target generates a static library that
#       can be consumed by other cmake targets.
#   NO_TEST
#       Disables generation of the test target.
#
# Notes:
#   - If neither BIN or STATIC is defined then it is assumed
#     that the target exports no artifacts (i.e. it is only used
#     by other rust targets within the build)
#   - Build and exported are currently mutually exclusive. If you
#     want to have multiple targets like this then call cargo_build
#     multiple times.
#
# Additional Things:
#   - This also sets up the required cmake properties to delete the
#     target directory when `make clean` or equivalent is run.
#
# How it Works:
#   In general, cmake has a hard time integrating with external build
#   systems within the same directory. However, cmake has extensive
#   support for custom linkers and also allows you to define interface
#   libraries when no artifact is created. Together, we can use these
#   to trick cmake into thinking it is building the executable while
#   actually using cargo to build them. This means that things like
#   linker flags and dependencies should mostly "just work" (hopefully).
#
#   What we have to do depends on what type of library we are compiling:
#       - For pure rust libraries that don't export any C API, we define
#         an interface library. This means that any linker flags are
#         properly passed on to downstream dependencies. In addition, we
#         define a custom target so the library is built.
#       - For static libraries, we define a library that's built using a
#         custom linker language. The custom linker command is really just
#         a `cargo build` in disguise, but one that passes the correct
#         flags in.
#       - For binaries, we define an executable target also using a custom
#         linker language similar to a static library.
#
#   To pass the proper linker flags to the rust process, we have a special
#   target <NAME>.linkflags.txt that echoes the linker flags into a known
#   file. These are then picked up by the import-link-flags crate which
#   uses a build script to pass them to rustc.
function(cargo_build)
    cmake_parse_arguments(
        CARGO
        "BIN;STATIC;NO_TEST"
        "NAME;TARGET_DIR;COPY_TO"
        ""
        ${ARGN}
    )

    string(REPLACE "-" "_" LIB_NAME ${CARGO_NAME})
    if(NOT (DEFINED CARGO_TARGET_DIR))
        set(CARGO_TARGET_DIR ${CMAKE_BINARY_DIR}/target)
    endif()

    if(CARGO_BIN AND CARGO_STATIC)
        message(
            FATAL_ERROR
            "Cannot create a cargo target that has "
            "both a binary and a static library. Use multiple "
            "targets instead."
        )
    endif()

    cargo_build_private_get_target(CRATE_TARGET)
    cargo_build_private_get_build_type(CRATE_BUILD_TYPE)

    # The CONFIGURE_DEPENDS flag will rerun the glob at build time if the
    # the build system supports it.
    file(
        GLOB_RECURSE
        CRATE_SOURCES
        CONFIGURE_DEPENDS
        "*.rs"
    )

    # Clean the target directory when make clean is run
    set_directory_properties(PROPERTIES
        ADDITIONAL_CLEAN_FILES
        ${CARGO_TARGET_DIR}
    )

    if(CARGO_BIN OR CARGO_STATIC)
        set(LINK_FLAGS_FILE $<TARGET_FILE:${CARGO_NAME}>.linkflags.txt)
    else()
        set(LINK_FLAGS_FILE $<TARGET_FILE:${CARGO_NAME}-link-export>)
    endif()

    set(FORWARDED_VARS
        # So that internal invocations of cmake are consistent
        "CMAKE=${CMAKE_COMMAND}"
        # So that build scripts can configure themselves based
        # on whether cmake is driving the build or not
        "CCOMMON_CMAKE_IS_DRIVING_BUILD=1"
        # Needed to configure the correct target directory
        "CARGO_TARGET_DIR=${CARGO_TARGET_DIR}"
    )

    if(CARGO_BIN)
        set(OUTPUT_FILE_NAME ${LIB_NAME}${CMAKE_EXECUTABLE_SUFFIX})
        set(OUTPUT_FILE ${CARGO_TARGET_DIR}/${CRATE_TARGET}/${OUTPUT_FILE_NAME})
    elseif(CARGO_STATIC)
        set(OUTPUT_FILE_NAME ${CMAKE_STATIC_LIBRARY_PREFIX}${LIB_NAME}${CMAKE_STATIC_LIBRARY_SUFFIX})
        set(OUTPUT_FILE ${CARGO_TARGET_DIR}/${CRATE_TARGET}/${OUTPUT_FILE_NAME})
    endif()

    if(IOS)
        # Since we're going through cargo rustc to pass linker flags
        # this won't work. The previous build script used cargo lipo
        # here. However, the likelyhood of someone wanting to use
        # a library for cache servers on IOS is low at this time so
        # this is OK.
        message(FATAL_ERROR "Compiling for IOS is not supported")
    endif()

    # Arguments to cargo
    set(CRATE_ARGS "")
    list(APPEND CRATE_ARGS "--target" ${CRATE_TARGET})

    if(CARGO_BIN)
        list(APPEND CRATE_ARGS "--bin" ${CRATE_TARGET})
    elseif(CARGO_STATIC)
        list(APPEND CRATE_ARGS "--lib")
    else()
        list(APPEND CRATE_ARGS "--lib")
    endif()

    if(${CRATE_BUILD_TYPE} STREQUAL "release")
        list(APPEND CRATE_ARGS "--release")
    endif()

    # The following is a hack. It takes advantage of the fact that
    # cmake allows us to define arbitrary linker languages in order
    # to invoke cargo as our linker command. To do this, we define
    # a custom language specific to only our target that also takes
    # in the required environment variables we want to set and the
    # output file generated by cargo.
    #
    # The upside of this hack is that it allows libraries and binaries
    # generated by cargo to be used as normal cmake targets. This
    # means that stuff like target_link_libraries works properly.
    #
    # Extra Note: The variables that look like <VAR_NAME> in the string
    #   below are called expansion variables by the community wiki. They
    #   don't seem to be documented anywhere in the official docs but
    #   are hopefully stable.
    #
    # Another Note: Since these are required to be global variables we
    #   push them in the cache as hidden variables.
    #
    # The inspiration for this hack came from this SO answer
    # https://stackoverflow.com/questions/34165365/retrieve-all-link-flags-in-cmake
    #
    # "Docs" for the expansion rules can be found here
    # https://gitlab.kitware.com/cmake/community/wikis/doc/cmake/Build-Rules
    set(
        LINK_COMMAND
        "bash -c \""
            "<CMAKE_COMMAND> -E echo_append <LINK_FLAGS> <LINK_LIBRARIES> > <TARGET>.linkflags.txt"
            "&& <CMAKE_COMMAND> -E env ${FORWARDED_VARS} 'CCOMMON_LINK_FLAGS_FILE=<TARGET>.linkflags.txt' cargo build <FLAGS>"
            "&& <CMAKE_COMMAND> -E copy '${OUTPUT_FILE}' <TARGET>"
        "\""
    )

    # TODO(sean): disambiguate this based on bin/lib so that multiple targets in
    #             the same directory don't clash.
    set(CMAKE_${CARGO_NAME}_LINK_EXECUTABLE "${LINK_COMMAND}" CACHE INTERNAL "")
    set(CMAKE_${CARGO_NAME}_CREATE_STATIC_LIBRARY "${LINK_COMMAND}" CACHE INTERNAL "")
    set(CMAKE_${CARGO_NAME}_CREATE_SHARED_LIBRARY "${LINK_COMMAND}" CACHE INTERNAL "")
    set(CMAKE_${CARGO_NAME}_LINK_FLAGS ${CMAKE_C_LINK_FLAGS} CACHE INTERNAL "")
    set(CMAKE_${CARGO_NAME}_LINK_DIRECTORIES ${CMAKE_C_LINK_DIRECTORIES} CACHE INTERNAL "")

    # Needed to build when we have test targets
    set(
        CMAKE_ECHO_LINK_EXECUTABLE
        "bash -c \"<CMAKE_COMMAND> -E echo_append <LINK_FLAGS> <LINK_LIBRARIES> > <TARGET>\""
        CACHE INTERNAL ""
    )
    set(CMAKE_ECHO_LINK_FLAGS ${CMAKE_C_LINK_FLAGS} CACHE INTERNAL "")
    set(CMAKE_ECHO_LINK_DIRECTORIES ${CMAKE_C_LINK_DIRECTORIES} CACHE INTERNAL "")

    # Targets
    if(CARGO_BIN)
        # We are building a binary executable
        add_executable(
            ${CARGO_NAME}
            ${CRATE_SOURCES}
        )

        # Ensure that we use our custom "linker"
        set_target_properties(
            ${CARGO_NAME} PROPERTIES
            LINKER_LANGUAGE ${CARGO_NAME}
        )

        target_compile_options(${CARGO_NAME} PRIVATE ${CRATE_ARGS})
    elseif(CARGO_STATIC)
        # We are building a static library that will be used from C code
        add_library(
            ${CRATE_NAME}
            STATIC
            ${CRATE_SOURCES}
        )

        # Ensure that we use our custom "linker"
        set_target_properties(
            ${CARGO_NAME} PROPERTIES
            LINKER_LANGUAGE ${CARGO_NAME}
        )

        target_compile_options(${CARGO_NAME} PRIVATE ${CRATE_ARGS})
    else()
        # We are building a rust-only library. Define it as a interface library
        add_library(
            ${CARGO_NAME}
            INTERFACE
        )

        # However, we still want to build the library, so define a custom command for that
        add_custom_command(
            # Dummy file to ensure that the command always runs
            OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/DOES_NOT_EXIST
            COMMAND ${CARGO_ENV_COMMAND} ${CARGO_EXECUTABLE} build ${CRATE_ARGS}
            DEPENDS ${CRATE_SOURCES}
            WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
            COMMENT "running cargo for target ${CARGO_NAME}"
        )

        add_custom_target(
            ${CARGO_NAME}-build
            ALL DEPENDS
            ${CMAKE_CURRENT_BINARY_DIR}/DOES_NOT_EXIST
        )

        add_dependencies(${CARGO_NAME} ${CARGO_NAME}-build)
        add_dependencies(${CARGO_NAME} ${CARGO_NAME}-link-export)

        add_executable(${CARGO_NAME}-link-export Cargo.toml)
        set_target_properties(
            ${CARGO_NAME}-link-export PROPERTIES
            LINKER_LANGUAGE ECHO
            SUFFIX          ".txt"
            TARGET_MESSAGES OFF
        )
        target_link_libraries(${CARGO_NAME}-link-export $<TARGET_PROPERTY:${CARGO_NAME},INTERFACE_LINK_LIBRARIES>)
    endif()

    if(NOT CARGO_NO_TEST)
        add_test(
            NAME ${CARGO_NAME}-test
            COMMAND ${CMAKE_COMMAND} -E env ${FORWARDED_VARS} "CCOMMON_LINK_FLAGS_FILE=${LINK_FLAGS_FILE}" cargo test ${CRATE_ARGS}
            WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        )
    endif()
endfunction()
