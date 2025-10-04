#!/bin/bash
# Copyright 2025, Andrew Kozik. <https://github.com/kozik47>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License at <http://www.gnu.org/licenses/> for
# more details.
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

if (( ${BASH_VERSINFO[0]} < 4 )); then
    echo "Error: This script requires Bash version 4 or higher."
    echo "On macOS, install a newer Bash via Homebrew: brew install bash"
    echo "Then run the script with the new Bash: /opt/homebrew/bin/bash ./build_HWFS_CFW.sh"
    exit 1
fi

set -euo pipefail

get_sha256() {
    local file="${1}"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print $1}'
    else
        shasum -a 256 "${file}" | awk '{print $1}'
    fi
}

get_stat_info() {
    local file="${1}"
    stat "${STAT_FLAG}" "${STAT_FORMAT}" "${file}"
}

compute_content_meta_hash() {
    local dir="${1}"
    pushd "${dir}" >/dev/null
    find . \( -type d -o -type f -o -type l \) | sort | while read -r file; do
        if [[ -d "${file}" ]]; then
            content_hash="DIR"
        elif [[ -h "${file}" ]]; then
            content_hash="SYM:$(readlink "${file}")"
        else
            content_hash="$(get_sha256 "${file}")"
        fi
        stat_info="$(get_stat_info "${file}")"
        read -r mtime uid gid perm <<< "${stat_info}"
        echo "${file}:${content_hash}:${mtime}:${uid}:${gid}:${perm}"
    done
    popd >/dev/null
}

show_help() {
    echo "Usage: ${0##*/} [OPTIONS] <INPUT_HWFS>"
    echo ""
    echo "Repackage a reference AUTOKIT HWFS update file with custom patches."
    echo ""
    echo "Options:"
    echo "  -v, --verbose              Enable verbose output"
    echo "  -o, --output <file>        Generated output HWFS file (default: <input>_CFW.hwfs)"
    echo "  -p, --patch-script <file>  Path to patch script (default: patch_U2ACW.sh)"
    echo "  -k, --keep                 Keep working directory after execution"
    echo "  -h, --help                 Show this help message"
    exit 0
}

check_dependencies() {
    local deps="python3 unzip zip tar"
    for dep in ${deps}; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            echo "Error: ${dep} is not installed. Please install it and try again."
            exit 1
        fi
    done
    if ! (command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1); then
        echo "Error: No SHA-256 hashing tool (sha256sum or shasum) is available. Please install one and try again."
        exit 1
    fi
}

parse_arguments() {
    VERBOSE=false
    KEEP=false
    SHOW_HELP=false
    INPUT_SET=false
    OUTPUT_SET=false
    INPUT_HWFS=""
    OUTPUT_HWFS=""
    PATCH_SCRIPT="${SCRIPT_DIR}/patch_U2ACW.sh"

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -k|--keep)
                KEEP=true
                shift
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            -o|--output)
                if [[ -z "${2}" ]]; then
                    echo "Error: --output requires a file argument."
                    exit 1
                fi
                OUTPUT_HWFS="${2}"
                OUTPUT_SET=true
                shift 2
                ;;
            -p|--patch-script)
                if [[ -z "${2}" ]]; then
                    echo "Error: --patch-script requires a file argument."
                    exit 1
                fi
                PATCH_SCRIPT="$(realpath "${2}")"
                shift 2
                ;;
            -*)
                echo "Error: Unknown option ${1}"
                show_help
                exit 1
                ;;
            *)
                if [[ ${INPUT_SET} == true ]]; then
                    echo "Error: Too many positional arguments."
                    show_help
                    exit 1
                fi
                INPUT_SET=true
                INPUT_HWFS="${1}"
                if [[ ${OUTPUT_SET} == false ]]; then
                    OUTPUT_HWFS="$(pwd)/$(basename "${INPUT_HWFS%.*}")_CFW.hwfs"
                fi
                shift
                ;;
        esac
    done

    if [[ "${SHOW_HELP}" == true ]]; then
        show_help
    fi

    if [[ "${SHOW_HELP}" == false ]]; then
        if [[ ${INPUT_SET} == false ]]; then
            echo "Error: No input file specified. Please provide the input HWFS file as a positional argument."
            show_help
            exit 1
        fi

        if [[ ! -f "${INPUT_HWFS}" ]]; then
            echo "Error: Input file '${INPUT_HWFS}' does not exist."
            exit 1
        fi

        if [[ ! -f "${PATCH_SCRIPT}" ]]; then
            echo "Error: Patch script '${PATCH_SCRIPT}' does not exist."
            exit 1
        fi
    fi

    if [[ "${VERBOSE}" == true ]]; then
        TAR_VFLAG=(-v)
        UNZIP_VFLAG=() # unzip is verbose by default
        ZIP_VFLAG=(-v)
        PS_VFLAG=(-v)
        UHMI_VFLAG=(-v)
    else
        TAR_VFLAG=()
        UNZIP_VFLAG=(-q) # quiet mode
        ZIP_VFLAG=()
        PS_VFLAG=()
        UHMI_VFLAG=()
    fi
}

setup_work_dir() {
    WORK_DIR="$(mktemp -d)"
    if [[ "${KEEP}" != true ]]; then
        trap "rm -rf \"${WORK_DIR}\"" EXIT INT TERM
    fi
    echo "Created working directory: ${WORK_DIR}"
    UNZIP_DIR="${WORK_DIR}/unzip"
    ORI_ZIP="${WORK_DIR}/$(basename "${INPUT_HWFS%.*}").zip"
    GEN_ZIP="${WORK_DIR}/$(basename "${INPUT_HWFS%.*}")_CFW.zip"
    GEN_HWFS="${WORK_DIR}/$(basename "${INPUT_HWFS%.*}")_CFW.hwfs"
}

decrypt_top_level() {
    echo "Decrypting reference firmware: ${INPUT_HWFS} to ${ORI_ZIP}"
    run "${SCRIPT_DIR}/../FirmwareHWFS.sh" decrypt "${INPUT_HWFS}" "${ORI_ZIP}"
}

unzip_contents() {
    echo "Unzipping decrypted firmware to ${UNZIP_DIR}"
    mkdir -p "${UNZIP_DIR}"
    run unzip "${UNZIP_VFLAG[@]}" -o -d "${UNZIP_DIR}" "${ORI_ZIP}"
    local files_count="$(find "${UNZIP_DIR}" -type f | wc -l | awk '{print $1}')"
    local total_size="$(du -sh "${UNZIP_DIR}" | awk '{print $1}')"
    echo "Unzipped ${files_count} files totaling ${total_size}"
}

backup_module_info() {
    echo "Backing up original ModuleInfo.json"
    cp "${UNZIP_DIR}/ModuleInfo.json" "${UNZIP_DIR}/ModuleInfo_original.json"
}

compute_original_hashes() {
    pushd "${UNZIP_DIR}" >/dev/null
    echo "Computing hashes for original ZIP contents..."
    for file in *; do
        if [[ -f "${file}" ]]; then
            vecho "Computing hash for ${file}"
            original_hashes["${file}"]="$(get_sha256 "${file}")"
        fi
    done
    popd >/dev/null
}

decrypt_and_extract_nested() {
    pushd "${UNZIP_DIR}" >/dev/null
    echo "Processing nested HWFS files..."
    local nested_count=0
    for hwfs_file in *.hwfs; do
        if [[ -f "${hwfs_file}" ]]; then
            ((nested_count+=1))
            local base_name="${hwfs_file%.hwfs}"
            local tar_gz="${base_name}.tar.gz"
            local extract_dir="${base_name}"
            vecho "Decrypting nested HWFS: ${hwfs_file} to ${tar_gz}"
            run "${SCRIPT_DIR}/../FirmwareHWFS.sh" decrypt "${hwfs_file}" "${tar_gz}"
            vecho "Extracting: ${tar_gz} to ${extract_dir}/"
            mkdir -p "${extract_dir}"
            run tar "${TAR_VFLAG[@]}" -p -zxf "${tar_gz}" -C "${extract_dir}"
        fi
    done
    echo "Decrypted and extracted ${nested_count} nested HWFS files"
    popd >/dev/null
}

compute_original_content_hashes() {
    pushd "${UNZIP_DIR}" >/dev/null
    echo "Computing meta hashes for original HWFS contents..."
    for hwfs_file in *.hwfs; do
        if [[ -f "${hwfs_file}" ]]; then
            local base_name="${hwfs_file%.hwfs}"
            local extract_dir="${base_name}"
            vecho "Computing meta hashes for content in ${extract_dir}/"
            original_content_hashes["${hwfs_file}"]="$(compute_content_meta_hash "${extract_dir}")"
        fi
    done
    popd >/dev/null
}

apply_modifications() {
    pushd "${UNZIP_DIR}" >/dev/null
    echo "Applying patch script: ${PATCH_SCRIPT}"
    run "${PATCH_SCRIPT}" "${PS_VFLAG[@]}"
    popd >/dev/null
}

create_generated_zip() {
    cp "${ORI_ZIP}" "${GEN_ZIP}"
}

repack_changed_hwfs() {
    pushd "${UNZIP_DIR}" >/dev/null
    local changed_count=0
    for hwfs_file in *.hwfs; do
        if [[ -f "${hwfs_file}" ]]; then
            local base_name="${hwfs_file%.hwfs}"
            local tar_gz="${base_name}.tar.gz"
            local extract_dir="${base_name}"
            local new_content_hash
            new_content_hash="$(compute_content_meta_hash "${extract_dir}")"
            if [[ "${original_content_hashes["${hwfs_file}"]}" == "${new_content_hash}" ]]; then
                vecho "No changes detected in ${hwfs_file}."
                if [[ "${KEEP}" != true ]]; then
                    rm -f "${tar_gz}"
                fi
            else
                ((changed_count+=1))
                echo "Changes detected in ${hwfs_file}; updating in ZIP."
                local orig_gzip_mtime="$(python3 -c "$(cat <<EOF
import struct
with open('${tar_gz}', 'rb') as f:
    f.seek(4)
    mtime_bytes = f.read(4)
    mtime = struct.unpack('<I', mtime_bytes)[0]
    print(mtime)
EOF
)")"
                python3 -c "$(cat <<EOF
import tarfile, os
orig = tarfile.open('${tar_gz}', 'r:gz')
members = orig.getmembers()
original_names = {m.name for m in members}
new_tar = tarfile.open('temp.tar', 'w', format=tarfile.GNU_FORMAT)
for ti in members:
    path = os.path.join('${extract_dir}', ti.name.lstrip('./'))
    if os.path.exists(path):
        if ti.isdir():
            stat = os.stat(path)
            ti.mtime = stat.st_mtime
            ti.mode = stat.st_mode
            ti.uid = stat.st_uid
            ti.gid = stat.st_gid
            new_tar.addfile(ti)
        elif ti.type == b'2':  # Symlink
            stat = os.lstat(path)
            ti.mtime = stat.st_mtime
            ti.size = 0
            ti.mode = stat.st_mode
            ti.uid = stat.st_uid
            ti.gid = stat.st_gid
            new_tar.addfile(ti)
        else:
            with open(path, 'rb') as f:
                stat = os.stat(path)
                ti.mtime = stat.st_mtime
                ti.size = stat.st_size
                ti.mode = stat.st_mode
                ti.uid = stat.st_uid
                ti.gid = stat.st_gid
                new_tar.addfile(ti, fileobj=f)
orig.close()
for root, dirs, files in os.walk('${extract_dir}'):
    for file in files:
        full_path = os.path.join(root, file)
        rel_path = os.path.relpath(full_path, '${extract_dir}')
        arcname = './' + rel_path.replace(os.sep, '/')
        if arcname not in original_names:
            new_tar.add(full_path, arcname=arcname)
    for d in dirs:
        full_path = os.path.join(root, d)
        rel_path = os.path.relpath(full_path, '${extract_dir}')
        arcname = './' + rel_path.replace(os.sep, '/')
        if arcname not in original_names:
            ti = tarfile.TarInfo(arcname)
            stat = os.stat(full_path)
            ti.mtime = stat.st_mtime
            ti.size = 0
            ti.mode = stat.st_mode
            ti.uid = stat.st_uid
            ti.gid = stat.st_gid
            ti.type = tarfile.DIRTYPE
            new_tar.addfile(ti)
new_tar.close()
EOF
)"
                touch -d "@${orig_gzip_mtime}" "temp.tar"
                vecho "Deflating temp.tar to ${tar_gz}"
                SOURCE_DATE_EPOCH="${orig_gzip_mtime}" gzip -c < "temp.tar" > "${tar_gz}"
                rm "temp.tar"
                local new_hwfs="${base_name}_new.hwfs"
                run "${SCRIPT_DIR}/../FirmwareHWFS.sh" encrypt "${tar_gz}" "${new_hwfs}"
                mv "${hwfs_file}" "${hwfs_file}.bak"
                mv "${new_hwfs}" "${hwfs_file}"
                local stat_info="$(get_stat_info "${hwfs_file}.bak")"
                local perm
                read -r _ _ _ perm <<< "${stat_info}"
                chmod "${perm}" "${hwfs_file}"
                run zip "${ZIP_VFLAG[@]}" -u "../$(basename "${GEN_ZIP}")" "${hwfs_file}"
                if [[ "${KEEP}" != true ]]; then
                    rm "${hwfs_file}.bak" "${tar_gz}"
                fi
            fi
        fi
    done
    if [[ "${VERBOSE}" != true ]] && [[ ${changed_count} -gt 0 ]]; then
        echo "Updated ${changed_count} changed modules in ZIP"
    fi
    popd >/dev/null
}

update_module_info() {
    echo "Updating ModuleInfo.json..."
    set +e
    run "${SCRIPT_DIR}/update_HWFS_ModuleInfo.sh" "${UHMI_VFLAG[@]}" "${UNZIP_DIR}"
    local update_rc=$?
    set -e
    if [[ ${update_rc} -ne 0 ]]; then
        pushd "${UNZIP_DIR}" >/dev/null
        cp "ModuleInfo_original.json" "ModuleInfo.json"
        popd >/dev/null
        echo "Error: ModuleInfo update failed; restored original ModuleInfo.json."
        exit 1
    fi
}

update_generated_zip_if_module_changed() {
    pushd "${UNZIP_DIR}" >/dev/null
    local new_module_hash="$(get_sha256 "ModuleInfo.json")"
    if [[ "${original_hashes["ModuleInfo.json"]}" != "${new_module_hash}" ]]; then
        echo "Changes detected in ModuleInfo.json; updating in ZIP."
        run zip -u "../$(basename "${GEN_ZIP}")" "ModuleInfo.json"
    else
        vecho "No changes in ModuleInfo.json after update."
    fi
    popd >/dev/null
}

cleanup_module_backup() {
    pushd "${UNZIP_DIR}" >/dev/null
    if [[ "${KEEP}" != true ]]; then
        echo "Cleaning up original ModuleInfo.json backup"
        rm "ModuleInfo_original.json"
    else
        echo "Original ModuleInfo.json backup kept"
    fi
    popd >/dev/null
}

encrypt_generated_zip() {
    echo "Encrypting generated ZIP to ${GEN_HWFS}"
    run "${SCRIPT_DIR}/../FirmwareHWFS.sh" encrypt "${GEN_ZIP}" "${GEN_HWFS}"
}

copy_final_output() {
    cp "${GEN_HWFS}" "${OUTPUT_HWFS}"
    echo "Custom firmware built: ${OUTPUT_HWFS}"
    if [[ "${KEEP}" == true ]]; then
        echo "Working directory kept: ${WORK_DIR}"
    fi
}

main() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    . "${SCRIPT_DIR}/shared.sh"

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        STAT_FLAG="-f"
        STAT_FORMAT="%m %u %g %OLp"
    else
        STAT_FLAG="-c"
        STAT_FORMAT="%Y %u %g %a"
    fi

    declare -A original_hashes
    declare -A original_content_hashes

    check_dependencies
    parse_arguments "$@"

    setup_work_dir
    decrypt_top_level
    unzip_contents
    backup_module_info
    compute_original_hashes
    decrypt_and_extract_nested
    compute_original_content_hashes
    apply_modifications
    create_generated_zip
    repack_changed_hwfs
    update_module_info
    update_generated_zip_if_module_changed
    cleanup_module_backup
    encrypt_generated_zip
    copy_final_output
}

main "$@"
