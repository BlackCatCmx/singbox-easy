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
profile_protocol='reality'
profile_name='default'
profile_port=''
profile_address=''
profile_sni=''
hy2_port_range=''
profile_option_set=0

log() {
    printf '[singbox-easy] %s\n' "$*"
}

die() {
    printf '[singbox-easy] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --protocol VALUE         reality, hysteria2, or shadowsocks (default: reality)
  --name NAME              Initial profile name (default: default)
  --port PORT              Initial profile listen port (default: random free port)
  --address ADDRESS        Public address written to the share URL
  --sni DOMAIN             Reality handshake domain (default: www.cloudflare.com)
  --hy2-port-range RANGE   Hysteria2 UDP hopping range, e.g. 20000:30000;
                           the range start is the listen/fallback port
  --ref GIT_REF            Install project files from a branch, tag, or commit
  --no-profile             Install without creating an initial profile
  -h, --help               Show this help
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
        --protocol)
            (($# >= 2)) || die "--protocol requires a value"
            profile_protocol=$2
            profile_option_set=1
            shift 2
            ;;
        --name)
            (($# >= 2)) || die "--name requires a value"
            profile_name=$2
            profile_option_set=1
            shift 2
            ;;
        --port)
            (($# >= 2)) || die "--port requires a value"
            profile_port=$2
            profile_option_set=1
            shift 2
            ;;
        --address)
            (($# >= 2)) || die "--address requires a value"
            profile_address=$2
            profile_option_set=1
            shift 2
            ;;
        --sni)
            (($# >= 2)) || die "--sni requires a value"
            profile_sni=$2
            profile_option_set=1
            shift 2
            ;;
        --hy2-port-range | --port-range)
            (($# >= 2)) || die "$1 requires a value"
            hy2_port_range=$2
            profile_option_set=1
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

    if ((create_default_profile == 0 && profile_option_set)); then
        die "--no-profile cannot be combined with initial profile options"
    fi
}

validate_profile_options() {
    ((create_default_profile)) || return

    case "${profile_protocol,,}" in
    reality | vless | vless-reality | vless_reality) profile_protocol='reality' ;;
    hysteria2 | hysteria | hy2) profile_protocol='hysteria2' ;;
    shadowsocks | shadow | ss | ss2022) profile_protocol='shadowsocks' ;;
    *) die "unsupported protocol: $profile_protocol" ;;
    esac

    [[ $profile_name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "invalid profile name: $profile_name"
    if [[ -n $profile_port ]]; then
        [[ $profile_port =~ ^[0-9]+$ ]] && ((1 <= 10#$profile_port && 10#$profile_port <= 65535)) || {
            die "port must be between 1 and 65535"
        }
        profile_port=$((10#$profile_port))
    fi
    [[ -z $profile_address || $profile_address != *['/?#@']* ]] || die "invalid public address: $profile_address"

    if [[ -n $profile_sni ]]; then
        [[ $profile_protocol == reality ]] || die "--sni is only supported by Reality"
        [[ $profile_sni =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $profile_sni == *.* ]] || {
            die "invalid SNI domain: $profile_sni"
        }
    fi

    if [[ -n $hy2_port_range ]]; then
        [[ $profile_protocol == hysteria2 ]] || die "--hy2-port-range requires Hysteria2"
        hy2_port_range=${hy2_port_range/-/:}
        [[ $hy2_port_range =~ ^([0-9]+):([0-9]+)$ ]] || die "port range must use START:END"
        local range_start=${BASH_REMATCH[1]} range_end=${BASH_REMATCH[2]}
        ((1 <= 10#$range_start && 10#$range_start < 10#$range_end && 10#$range_end <= 65535)) || {
            die "invalid ascending Hysteria2 port range"
        }
        range_start=$((10#$range_start))
        range_end=$((10#$range_end))
        [[ -z $profile_port || $profile_port == "$range_start" ]] || {
            die "--port must equal the Hysteria2 range start: $range_start"
        }
        profile_port=$range_start
        hy2_port_range="${range_start}:${range_end}"
    fi
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
        ca-certificates curl iptables jq openssl tar >/dev/null
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
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=${CORE_BIN} run -c ${INSTALL_DIR}/config.json -C ${INSTALL_DIR}/conf.d
ExecStartPre=${MANAGER_BIN} firewall-add
ExecStopPost=${MANAGER_BIN} firewall-remove
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}/state

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

main() {
    parse_args "$@"
    validate_profile_options
    require_supported_system
    install_dependencies
    initialize_layout
    install_manager

    log "downloading the latest sing-box release"
    "$MANAGER_BIN" update --no-restart
    install_service

    if ((create_default_profile)); then
        local add_args=(add "$profile_protocol" "$profile_name")
        [[ -z $profile_port ]] || add_args+=(--port "$profile_port")
        [[ -z $profile_address ]] || add_args+=(--address "$profile_address")
        [[ -z $profile_sni ]] || add_args+=(--sni "$profile_sni")
        [[ -z $hy2_port_range ]] || add_args+=(--port-range "$hy2_port_range")
        log "creating the initial ${profile_protocol} profile"
        "$MANAGER_BIN" "${add_args[@]}"
    else
        log "no profile was created; the service remains disabled and stopped"
    fi

    log "installation completed"
    "$MANAGER_BIN" status
    if ((create_default_profile)); then
        "$MANAGER_BIN" show "$profile_name"
    else
        printf 'Run: sbe add reality default\n'
    fi
}

main "$@"
