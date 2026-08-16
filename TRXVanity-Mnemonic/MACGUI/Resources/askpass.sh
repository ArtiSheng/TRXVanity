#!/bin/sh
if [ -z "${TRX_SSH_PASSWORD+x}" ]; then
    exit 1
fi
printf '%s\n' "${TRX_SSH_PASSWORD}"
