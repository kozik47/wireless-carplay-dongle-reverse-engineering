#!/bin/bash
# Copyright 2025, Andrew Kozik. <https://github.com/kozik47>

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License at <http://www.gnu.org/licenses/> for
# more details.

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

set -euo pipefail

check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is not installed. Please install it and try again." 1>&2
        exit 1
    fi
}

parse_arguments() {
    VERBOSE=false
    DIR=""

    # Parse command line options
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                echo "Error: Unknown option ${1}"
                exit 1
                ;;
            *)
                DIR="${1}"
                break
                ;;
        esac
    done

    # Check for input arguments
    if [[ -z "${DIR}" ]]; then
        echo "Usage: ${0} [-v | --verbose] <directory>"
        exit 1
    fi

    if [[ "${VERBOSE}" == true ]]; then
        echo "Using directory ${DIR}" 1>&2
    fi

    # Verify directory exists
    if [[ ! -d "${DIR}" ]]; then
        echo "Error: Directory ${DIR} does not exist."
        exit 1
    fi

    INPUT_FILE="${DIR}/ModuleInfo.json"

    # Verify input file exists
    if [[ ! -f "${INPUT_FILE}" ]]; then
        echo "Error: Input file ${INPUT_FILE} does not exist."
        exit 1
    fi

    if [[ "${VERBOSE}" == true ]]; then
        echo "Parsing ${INPUT_FILE}" 1>&2
    fi
}

compute_file_info() {
    local file_path="${1}"
    local md5_new
    local size_new

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        md5_new="$(md5 -q "${file_path}")"
        size_new="$(stat -f %z "${file_path}")"
    else
        md5_new="$(md5sum "${file_path}" | awk '{print $1}')"
        size_new="$(stat -c %s "${file_path}")"
    fi

    echo "${md5_new} ${size_new}"
}

process_module() {
    local fname="${1}"
    local input_file="${2}"
    local verbose="${3}"
    local original_md5="${4}"
    local original_size="${5}"
    local md5_new
    local size_new

    read md5_new size_new <<< "$(compute_file_info "${DIR}/${fname}")"

    local md5_changed="$( [[ "${md5_new}" == "${original_md5}" ]] && echo false || echo true )"
    local size_changed="$( [[ "${size_new}" == "${original_size}" ]] && echo false || echo true )"
    local any_changed="$( [[ "${md5_changed}" == true || "${size_changed}" == true ]] && echo true || echo false )"

    if [[ "${any_changed}" == true ]] || [[ "${verbose}" == true ]]; then
        if [[ "${any_changed}" == true ]]; then
            echo "module: ${fname} (changed)" 1>&2
        else
            echo "module: ${fname}" 1>&2
        fi

        if [[ "${md5_changed}" == true ]]; then
            echo "  md5:  ${md5_new} (changed)" 1>&2
        else
            echo "  md5:  ${md5_new}" 1>&2
        fi

        if [[ "${size_changed}" == true ]]; then
            echo "  size: ${size_new} (changed)" 1>&2
        else
            echo "  size: ${size_new}" 1>&2
        fi
    fi

    echo "${md5_new} ${size_new}"
}

update_json() {
    local input_file="${1}"
    local verbose="${2}"
    local updates_file="${3}"

    local updates_content="$(cat "${updates_file}")"
    local compact_json="$(jq -c --argjson updates "${updates_content}" \
      '.ModuleInfo |= map( .fullName as $fn | . + ($updates[$fn] // {}) )' \
      "${input_file}")"

    local spaced_json="$(printf "%s" "${compact_json}" | sed 's/:/: /g; s/,/, /g; s/, { /,{/g')"

    if [[ "${verbose}" == true ]]; then
        echo "Generating updated JSON" 1>&2
    fi

    local temp_json="ModuleInfo_temp.json"
    printf "%s" "${spaced_json}" > "${temp_json}"

    local original_content="$(< "${input_file}")"
    local new_content="$(< "${temp_json}")"

    if [[ "${original_content}" != "${new_content}" ]]; then
        mv "${temp_json}" "${input_file}"
        echo "JSON update completed. ModuleInfo.json updated in ${DIR}"
    else
        rm "${temp_json}"
        echo "No changes to ModuleInfo.json in ${DIR}"
    fi
}

main() {
    check_dependencies
    parse_arguments "$@"

    local updates_file="$(mktemp)"
    echo '{}' > "${updates_file}"

    if [[ "${VERBOSE}" == true ]]; then
        echo "Processing modules" 1>&2
    fi

    local fullnames="$(jq -r '.ModuleInfo[].fullName' "${INPUT_FILE}")"

    while read -r fname; do
        local original_md5="$(jq -r --arg fn "${fname}" '.ModuleInfo[] | select(.fullName == $fn) | .md5' "${INPUT_FILE}")"
        local original_size="$(jq -r --arg fn "${fname}" '.ModuleInfo[] | select(.fullName == $fn) | .size' "${INPUT_FILE}")"

        local md5_new
        local size_new
        read md5_new size_new <<< "$(process_module "${fname}" "${INPUT_FILE}" "${VERBOSE}" "${original_md5}" "${original_size}")"

        jq --arg fname "${fname}" --arg md5 "${md5_new}" --argjson size "${size_new}" \
          '.[$fname] = {md5: $md5, size: $size}' \
          "${updates_file}" > "${updates_file}.tmp" && mv "${updates_file}.tmp" "${updates_file}"
    done <<< "${fullnames}"

    update_json "${INPUT_FILE}" "${VERBOSE}" "${updates_file}"

    # Cleanup
    rm "${updates_file}"
}

main "$@"
