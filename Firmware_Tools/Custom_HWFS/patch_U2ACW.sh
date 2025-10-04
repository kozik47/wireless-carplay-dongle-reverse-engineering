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

apply_sed_patch() {
    local file="${1}"
    local sed_expr="${2}"

    if [[ ! -f "${file}" ]]; then
        echo "Error: File '${file}' does not exist."
        exit 1
    fi

    cp -p "${file}" "${file}.bak"
    sed "${SED_FLAG}" "${sed_expr}" "${file}"

    if [[ "${VERBOSE}" == true ]]; then
        echo "Diff for '${file}':"
        diff -u "${file}.bak" "${file}" | sed 's/^/  /' || true
        echo ""
    fi

    if cmp -s "${file}" "${file}.bak"; then
        echo "Error: Sed patch did not apply any changes to '${file}'."
        mv "${file}.bak" "${file}"
        exit 1
    fi
    rm "${file}.bak"
    ((PATCH_COUNT+=1))
}

copy_dropbear_bins() {
    vecho "Copying Dropbear binaries to usr/sbin/"
    local bins=(dropbear scp sftp-server)
    for bin in "${bins[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/bins/${bin}" ]]; then
            echo "Error: Binary '${SCRIPT_DIR}/bins/${bin}' does not exist."
            exit 1
        fi
        cp -p "${SCRIPT_DIR}/bins/${bin}" "usr/sbin/"
    done

    vecho "Creating symlink for sftp-server in usr/libexec/"
    mkdir -p -m 775 "usr/libexec"
    ln -sf "../sbin/sftp-server" "usr/libexec/sftp-server"
}

patch_rcS() {
    vecho "Patching rcS to enable Dropbear"
    local file="etc/init.d/rcS"
    apply_sed_patch "${file}" 's/^#dropbear$/dropbear -B/g'
}

patch_udisk_scripts() {
    vecho "Patching udisk scripts for read-write mount options"
    local files=("etc/mdev/udisk_hotplug.sh" "etc/mdev/udisk_insert.sh")
    for file in "${files[@]}"; do
        apply_sed_patch "${file}" 's|^\([[:space:]]*mount /dev/\$MDEV /mnt/UPAN -t vfat -o \)\(utf8=1\)|\1rw,umask=0000,\2|g'
    done
}

patch_profile() {
    vecho "Patching profile for PATH and PS1"
    local file="etc/profile"
    apply_sed_patch "${file}" 's|^\(export PATH=/tmp/bin:\)\($PATH\)$|\1/bin:/usr/bin:/sbin:/usr/sbin:\2|g'
    apply_sed_patch "${file}" "s/^\(PS1='\)\[(\\\t)\\\u@\\\w\]#'$/\1root@192.168.50.2:~# '/g"
}

create_passwd_and_shadow() {
    vecho "Creating minimal passwd and shadow files"
    local passwd_file="etc/passwd"
    local shadow_file="etc/shadow"

    cat <<EOF > "${passwd_file}"
root::0:0:root:/root:/bin/sh
EOF

    cat <<EOF > "${shadow_file}"
root::14610:0:99999:7:::
EOF

    chmod 644 "${passwd_file}" "${shadow_file}"
}

patch_update_box() {
    vecho "Patching update_box.sh to add log copy and custom script execution"
    local file="script/update_box.sh"
    apply_sed_patch "${file}" '/^[[:space:]]*hwfsfile=Auto_Box_Update\.hwfs[[:space:]]*$/N; /^[[:space:]]*hwfsfile=Auto_Box_Update\.hwfs[[:space:]]*\n[[:space:]]*fi[[:space:]]*$/a \
\
if [ -e /tmp/userspace.log ] ; then\
       cp /tmp/userspace.log /mnt/UPAN/userspace.log && sync # Copy logs to USB key\
fi\
if [ -e /mnt/UPAN/U2W.sh ] ; then\
       sed -i "s/\\\\r//g" /mnt/UPAN/U2W.sh && sync # Remove Windows style CR\
       /mnt/UPAN/U2W.sh > /mnt/UPAN/U2W.txt 2>&1 && sync # Execute custom script and save return\
fi'
}

show_help() {
    echo "Usage: ${0##*/} [options]"
    echo ""
    echo "Apply patches to the Common directory."
    echo ""
    echo "Options:"
    echo "  -v, --verbose    Enable verbose output"
    echo "  -h, --help       Show this help message"
    exit 0
}

parse_arguments() {
    VERBOSE=false
    SHOW_HELP=false

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            -*)
                echo "Error: Unknown option ${1}"
                show_help
                exit 1
                ;;
            *)
                echo "Error: Unexpected argument ${1}"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ "${SHOW_HELP}" == true ]]; then
        show_help
    fi
}

main() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    . "${SCRIPT_DIR}/shared.sh"

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        SED_FLAG="-i ''"
    else
        SED_FLAG="-i"
    fi

    parse_arguments "$@"
    local patch_dir="$(find . -maxdepth 1 -type d -name 'Common_[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9][0-9][0-9][0-9]' | head -n1)"

    if [[ ! -d "${patch_dir}" ]]; then
        echo "Error: No matching 'Common_YYYY.MM.DD.HHHH' directory found."
        exit 1
    fi

    vecho "Using patch directory: ${patch_dir}"

    PATCH_COUNT=0

    pushd "${patch_dir}" >/dev/null

    copy_dropbear_bins
    patch_rcS
    patch_udisk_scripts
    patch_profile
    create_passwd_and_shadow
    patch_update_box

    popd >/dev/null

    echo "Applied ${PATCH_COUNT} patches in ${patch_dir}"
}

main "$@"
