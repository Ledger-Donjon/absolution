# ApplyRedef.cmake — script-mode helper invoked at build time.
#
# Reads a absolution redefinition file and applies objcopy --redefine-syms /
# --globalize-symbol to each listed object file.  All renames for a given
# object file are batched into a single objcopy invocation instead of one
# call per symbol, reducing process-fork overhead to O(unique_objects).
#
# Expected -D variables:
#   REDEF_FILE    — path to the absolution-generated .redef file
#   OBJ_LIST_FILE — path to a text file listing one object-file path per line
#   OBJCOPY       — path to the objcopy (or llvm-objcopy) executable

if(NOT EXISTS "${REDEF_FILE}")
    return()
endif()

if(NOT EXISTS "${OBJ_LIST_FILE}")
    message(FATAL_ERROR "ApplyRedef: object list file not found: ${OBJ_LIST_FILE}")
endif()

file(STRINGS "${OBJ_LIST_FILE}" _obj_paths)

# ── Helper: check if string ends with a given suffix ────────────────────────
function(_ends_with _str _suffix _result)
    string(LENGTH "${_str}" _str_len)
    string(LENGTH "${_suffix}" _suf_len)
    if(_suf_len GREATER _str_len)
        set(${_result} FALSE PARENT_SCOPE)
        return()
    endif()
    math(EXPR _start "${_str_len} - ${_suf_len}")
    string(SUBSTRING "${_str}" ${_start} ${_suf_len} _tail)
    if(_tail STREQUAL "${_suffix}")
        set(${_result} TRUE PARENT_SCOPE)
    else()
        set(${_result} FALSE PARENT_SCOPE)
    endif()
endfunction()

# ── Helper: strip leading "../" sequences ────────────────────────────────────
function(_strip_leading_dotdot _path _result)
    set(_p "${_path}")
    while(_p MATCHES "^\\.\\./")
        string(SUBSTRING "${_p}" 3 -1 _p)
    endwhile()
    set(${_result} "${_p}" PARENT_SCOPE)
endfunction()
# ── Helper: find the object file matching a source path ──────────────────────
function(_find_object_file _src_file _obj_paths _result)
    set(_suffix1 "/${_src_file}.o")

    string(REPLACE "../" "__/" _src_ninja "${_src_file}")
    set(_suffix2 "/${_src_ninja}.o")

    _strip_leading_dotdot("${_src_file}" _src_stripped)
    set(_suffix3 "/${_src_stripped}.o")

    string(REPLACE "../" "__/" _src_stripped_ninja "${_src_stripped}")
    set(_suffix4 "/${_src_stripped_ninja}.o")

    set(_obj "")
    foreach(_candidate ${_obj_paths})
        foreach(_suffix IN ITEMS "${_suffix1}" "${_suffix2}" "${_suffix3}" "${_suffix4}")
            _ends_with("${_candidate}" "${_suffix}" _match)
            if(_match)
                set(_obj "${_candidate}")
                break()
            endif()
        endforeach()
        if(_obj)
            break()
        endif()
        string(FIND "${_candidate}" "/${_src_stripped}.o" _idx)
        if(NOT _idx EQUAL -1)
            set(_obj "${_candidate}")
            break()
        endif()
    endforeach()

    set(${_result} "${_obj}" PARENT_SCOPE)
endfunction()

# ── Pass 1: parse .redef and group rename pairs by object file ───────────────
# _unique_objs        — ordered list of unique object file paths
# _renames_<N>        — interleaved (old new old new …) list for obj index N
# _new_syms_<N>       — list of new symbol names for obj index N (for globalize)
file(STRINGS "${REDEF_FILE}" _lines)

set(_unique_objs "")

foreach(_line ${_lines})
    string(REPLACE " " ";" _parts "${_line}")
    list(LENGTH _parts _len)
    if(NOT _len EQUAL 3)
        continue()
    endif()
    list(GET _parts 0 _src_file)
    list(GET _parts 1 _old_sym)
    list(GET _parts 2 _new_sym)

    if(_src_file MATCHES "\\.(h|hpp|hxx|H)$")
        continue()
    endif()

    _find_object_file("${_src_file}" "${_obj_paths}" _obj)

    if(NOT _obj)
        _strip_leading_dotdot("${_src_file}" _src_stripped)
        string(REPLACE "../" "__/" _src_ninja "${_src_file}")
        string(REPLACE "../" "__/" _src_stripped_ninja "${_src_stripped}")
        message(STATUS "ApplyRedef: searching for object file for source '${_src_file}'")
        message(STATUS "  Suffix patterns tried:")
        message(STATUS "    1. '/${_src_file}.o'")
        message(STATUS "    2. '/${_src_ninja}.o'")
        message(STATUS "    3. '/${_src_stripped}.o'")
        message(STATUS "    4. '/${_src_stripped_ninja}.o'")
        message(STATUS "  Object files in ${OBJ_LIST_FILE}:")
        foreach(_p ${_obj_paths})
            message(STATUS "    ${_p}")
        endforeach()
        message(FATAL_ERROR
            "ApplyRedef: no object file found for source '${_src_file}'.\n"
            "  See suffix patterns above.\n"
            "  Object list file: ${OBJ_LIST_FILE}")
    endif()

    list(FIND _unique_objs "${_obj}" _idx)
    if(_idx EQUAL -1)
        list(LENGTH _unique_objs _idx)
        list(APPEND _unique_objs "${_obj}")
    endif()

    list(APPEND _renames_${_idx} "${_old_sym}" "${_new_sym}")
    list(APPEND _new_syms_${_idx} "${_new_sym}")
endforeach()

# ── Pass 2: one objcopy invocation per object file ───────────────────────────
set(_idx 0)
foreach(_obj ${_unique_objs})
    # Write a --redefine-syms file: one "old new" pair per line.
    set(_syms_file "${_obj}.redefine_syms.tmp")
    set(_syms_content "")

    set(_i 0)
    list(LENGTH _renames_${_idx} _rlen)
    while(_i LESS _rlen)
        list(GET _renames_${_idx} ${_i} _old)
        math(EXPR _i1 "${_i} + 1")
        list(GET _renames_${_idx} ${_i1} _new)
        string(APPEND _syms_content "${_old} ${_new}\n")
        math(EXPR _i "${_i} + 2")
    endwhile()

    file(WRITE "${_syms_file}" "${_syms_content}")

    # Single rename pass for all symbols in this .o
    execute_process(
        COMMAND "${OBJCOPY}" "--redefine-syms=${_syms_file}" "${_obj}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "objcopy --redefine-syms failed for ${_obj}")
    endif()

    # Single globalize pass: build the argument list from _new_syms_<idx>
    set(_globalize_args "")
    foreach(_sym ${_new_syms_${_idx}})
        list(APPEND _globalize_args "--globalize-symbol" "${_sym}")
    endforeach()

    execute_process(
        COMMAND "${OBJCOPY}" ${_globalize_args} "${_obj}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "objcopy --globalize-symbol failed for ${_obj}")
    endif()

    file(REMOVE "${_syms_file}")
    math(EXPR _idx "${_idx} + 1")
endforeach()