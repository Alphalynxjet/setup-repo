#!/bin/bash

export SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")

echo "Select installation type:"
echo "1. Ubuntu"
echo "2. Docker"

# Use AUTO_INSTALL if set, otherwise prompt
if [ -n "$AUTO_INSTALL" ]; then
    if [ "$AUTO_INSTALL" = "ubuntu" ]; then
        choice=1
        echo "Automated selection: Ubuntu (1)"
    else
        choice=2
        echo "Automated selection: Docker (2)"
    fi
else
    read -p "Enter 1 or 2: " choice
fi

case "$choice" in
  1)
    echo "Running Ubuntu prereq script..."
    bash ${SCRIPT_PATH}/ubuntu/prereq.sh
    ;;
  2)
    echo "Running Docker prereq script..."
    bash ${SCRIPT_PATH}/docker/prereq.sh
    ;;
  *)
    echo "Invalid choice. Please enter 1 or 2."
    exit 1
    ;;
esac