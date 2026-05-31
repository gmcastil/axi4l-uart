if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    builtin printf 'Error: %s\n' "This script must be sourced by a running subshell." >&2
    exit 1
fi

function log_err() {
    local msg
    msg="${1}"
    builtin printf 'Error: %s\n' "${msg}" >&2
}

function log_info() {
    local msg
    msg="${1}"
    builtin printf 'Info: %s\n' "${msg}" >&1
}

if [[ -z "${REPO_DIR}" ]]; then
    log_err "REPO_DIR is not set"
    return 1
fi

export SVUNIT_INSTALL="${REPO_DIR}/extern/svunit"
export PATH="${SVUNIT_INSTALL}/bin:${PATH}"
