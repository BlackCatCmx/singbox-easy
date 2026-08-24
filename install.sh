#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_REPO="BlackCatCmx/singbox-easy"
readonly PROJECT_REF_DEFAULT="main"
readonly INSTALL_DIR="/etc/singbox-easy"
readonly CORE_BIN="${INSTALL_DIR}/bin/sing-box"
readonly MANAGER_BIN="/usr/local/bin/sbe"
readonly SERVICE_FILE="/etc/systemd/system/singbox-easy.service"

project_ref="${SINGBOX_EASY_REF:-$PROJECT_REF_DEFAULT}"
create_default_profile=1

log() {
    printf '[singbox-easy] %s\n' "$*"
}

die() {
    printf '[singbox-easy] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: install.sh [--ref GIT_REF] [--no-profile]

Options:
  --ref GIT_REF   Install project files from a branch, tag, or commit.
  --no-profile    Do not create the default VLESS-REALITY profile.
  -h, --help      Show this help.
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
        --ref)
            (($# >= 2)) || die "--ref requires a value"
            project_ref=$2
            shift 2
            ;;
        --no-profile)
            create_default_profile=0
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
        esac
    done
}

require_supported_system() {
    [[ ${EUID} -eq 0 ]] || die "run this installer as root"
    [[ -r /etc/os-release ]] || die "cannot identify the operating system"

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
    debian | ubuntu) ;;
    *) die "only Debian and Ubuntu are supported" ;;
    esac

    command -v systemctl >/dev/null || die "systemd is required"
    command -v apt-get >/dev/null || die "apt-get is required"

    case "$(uname -m)" in
    x86_64 | amd64) ;;
    aarch64 | arm64) ;;
    *) die "only AMD64 and ARM64 are supported" ;;
    esac

    [[ ! -e $INSTALL_DIR && ! -e $SERVICE_FILE ]] || {
        die "singbox-easy is already installed; run 'sbe uninstall' first"
    }
}

install_dependencies() {
    log "installing required packages"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl jq openssl tar >/dev/null
}

install_manager() {
    local manager_url
    manager_url="https://raw.githubusercontent.com/${PROJECT_REPO}/${project_ref}/singbox-easy"

    log "installing manager from ${PROJECT_REPO}@${project_ref}"
    curl -fL --retry 3 --retry-delay 1 \
        -H 'Cache-Control: no-cache' \
        "${manager_url}?cache=$(date +%s)" \
        -o "${MANAGER_BIN}.new"
    install -m 0755 "${MANAGER_BIN}.new" "$MANAGER_BIN"
    rm -f "${MANAGER_BIN}.new"
}

initialize_layout() {
    install -d -m 0755 \
        "${INSTALL_DIR}/bin" \
        "${INSTALL_DIR}/conf.d" \
        "${INSTALL_DIR}/state" \
        "${INSTALL_DIR}/tls"

    cat >"${INSTALL_DIR}/config.json" <<'EOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    chmod 0600 "${INSTALL_DIR}/config.json"
}

install_service() {
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=singbox-easy service
Documentation=https://github.com/${PROJECT_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${CORE_BIN} run -c ${INSTALL_DIR}/config.json -C ${INSTALL_DIR}/conf.d
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable singbox-easy.service >/dev/null
}

main() {
    parse_args "$@"
    require_supported_system
    install_dependencies
    initialize_layout
    install_manager

    log "downloading the latest sing-box release"
    "$MANAGER_BIN" update --no-restart
    install_service

    if ((create_default_profile)); then
        log "creating the default VLESS-REALITY profile"
        "$MANAGER_BIN" add reality default
    else
        systemctl start singbox-easy.service
    fi

    log "installation completed"
    "$MANAGER_BIN" status
    if ((create_default_profile)); then
        "$MANAGER_BIN" show default
    else
        printf 'Run: sbe add reality default\n'
    fi
}

main "$@"
