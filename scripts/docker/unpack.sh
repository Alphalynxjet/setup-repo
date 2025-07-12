#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
source ${SCRIPT_PATH}/inc/functions.sh

# Ensure unzip is available
if ! command -v unzip >/dev/null 2>&1; then
    msg $warn "unzip not found, installing..."
    if [ -f /etc/debian_version ]; then
        sudo apt-get update && sudo apt-get install -y unzip
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y unzip
    fi
fi

TEMP_DIR=$(mktemp -d)
unzip ${1} -d ${TEMP_DIR}
mv ${TEMP_DIR}/*/* ${2}
rm -rf ${TEMP_DIR}
echo