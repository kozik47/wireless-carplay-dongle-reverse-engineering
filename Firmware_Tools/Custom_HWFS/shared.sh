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

# Shared helper runner function
run() {
    if [ "$VERBOSE" = true ]; then
        echo "+ $*"
        "$@" 2>&1 | awk '{print "  " $0}'
        local status="${PIPESTATUS[0]}"
        if [ "$status" -ne 0 ]; then
            exit "$status"
        fi
    else
        "$@" >/dev/null 2>&1
    fi
}

# Verbose echo function
vecho() {
    if [ "$VERBOSE" = true ]; then
        echo "$@"
    fi
}
