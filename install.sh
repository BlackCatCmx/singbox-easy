#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_REPO="BlackCatCmx/singbox-easy"
readonly PROJECT_REF_DEFAULT="main"
readonly INSTALL_DIR="/etc/singbox-easy"
readonly CORE_BIN="${INSTALL_DIR}/bin/sing-box"
readonly MANAGER_BIN="/usr/local/bin/sb"
readonly SERVICE_FILE="/etc/systemd/system/singbox-easy.service"

project_ref="${SINGBOX_EASY_REF:-$PROJECT_REF_DEFAULT}"
create_default_profile=1
profile_protocol='reality'
profile_protocols_raw=''
profile_protocol_list=()
protocol_argument=''
profile_name='default'
profile_port=''
reality_port=''
hy2_port=''
shadowsocks_port=''
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
  --protocols LIST         Multiple protocols, e.g. reality,hysteria2
  --name NAME              Initial profile name (default: default)
  --port PORT              Initial profile listen port (default: random free port)
  --reality-port PORT      Reality port for multi-protocol installation
  --hy2-port PORT          Hysteria2 port for multi-protocol installation
  --ss-port PORT           Shadowsocks port for multi-protocol installation
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
            [[ -z $protocol_argument ]] || die "use only one of --protocol and --protocols"
            profile_protocol=$2
            protocol_argument='single'
            profile_option_set=1
            shift 2
            ;;
        --protocols)
            (($# >= 2)) || die "--protocols requires a value"
            [[ -z $protocol_argument ]] || die "use only one of --protocol and --protocols"
            profile_protocols_raw=$2
            protocol_argument='multiple'
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
        --reality-port)
            (($# >= 2)) || die "--reality-port requires a value"
            reality_port=$2
            profile_option_set=1
            shift 2
            ;;
        --hy2-port)
            (($# >= 2)) || die "--hy2-port requires a value"
            hy2_port=$2
            profile_option_set=1
            shift 2
            ;;
        --ss-port | --shadowsocks-port)
            (($# >= 2)) || die "$1 requires a value"
            shadowsocks_port=$2
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

normalize_installer_protocol() {
    case "${1,,}" in
    reality | vless | vless-reality | vless_reality) printf 'reality\n' ;;
    hysteria2 | hysteria | hy2) printf 'hysteria2\n' ;;
    shadowsocks | shadow | ss | ss2022) printf 'shadowsocks\n' ;;
    *) die "unsupported protocol: $1" ;;
    esac
}

normalize_installer_port() {
    [[ $1 =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)) || {
        die "port must be between 1 and 65535: $1"
    }
    printf '%s\n' "$((10#$1))"
}

validate_profile_options() {
    ((create_default_profile)) || return

    local raw_protocols protocol normalized seen=' '
    local -a requested_protocols
    if [[ -n $profile_protocols_raw ]]; then
        raw_protocols=${profile_protocols_raw//+/,}
        if [[ ${raw_protocols,,} == both ]]; then
            raw_protocols='reality,hysteria2'
        fi
        IFS=',' read -r -a requested_protocols <<<"$raw_protocols"
    else
        requested_protocols=("$profile_protocol")
    fi
    ((${#requested_protocols[@]})) || die "--protocols cannot be empty"
    for protocol in "${requested_protocols[@]}"; do
        [[ -n $protocol ]] || die "--protocols contains an empty value"
        normalized=$(normalize_installer_protocol "$protocol")
        [[ $seen != *" $normalized "* ]] || die "duplicate protocol: $normalized"
        profile_protocol_list+=("$normalized")
        seen+="$normalized "
    done

    [[ $profile_name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "invalid profile name: $profile_name"
    if ((${#profile_protocol_list[@]} > 1)); then
        [[ -z $profile_port ]] || die "use protocol-specific ports with --protocols"
        ((${#profile_name} <= 26)) || die "multi-protocol name must not exceed 26 characters"
    fi
    [[ -z $profile_address || $profile_address != *['/?#@']* ]] || die "invalid public address: $profile_address"

    [[ -z $profile_port ]] || profile_port=$(normalize_installer_port "$profile_port")
    [[ -z $reality_port ]] || reality_port=$(normalize_installer_port "$reality_port")
    [[ -z $hy2_port ]] || hy2_port=$(normalize_installer_port "$hy2_port")
    [[ -z $shadowsocks_port ]] || shadowsocks_port=$(normalize_installer_port "$shadowsocks_port")

    local selected=" ${profile_protocol_list[*]} "
    [[ -z $reality_port || $selected == *' reality '* ]] || die "--reality-port requires Reality"
    [[ -z $hy2_port || $selected == *' hysteria2 '* ]] || die "--hy2-port requires Hysteria2"
    [[ -z $shadowsocks_port || $selected == *' shadowsocks '* ]] || die "--ss-port requires Shadowsocks"

    if [[ -n $profile_sni ]]; then
        [[ $selected == *' reality '* ]] || die "--sni requires Reality"
        [[ $profile_sni =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $profile_sni == *.* ]] || {
            die "invalid SNI domain: $profile_sni"
        }
    fi

    if [[ -n $hy2_port_range ]]; then
        [[ $selected == *' hysteria2 '* ]] || die "--hy2-port-range requires Hysteria2"
        hy2_port_range=${hy2_port_range/-/:}
        [[ $hy2_port_range =~ ^([0-9]+):([0-9]+)$ ]] || die "port range must use START:END"
        local range_start=${BASH_REMATCH[1]} range_end=${BASH_REMATCH[2]}
        ((1 <= 10#$range_start && 10#$range_start < 10#$range_end && 10#$range_end <= 65535)) || {
            die "invalid ascending Hysteria2 port range"
        }
        range_start=$((10#$range_start))
        range_end=$((10#$range_end))
        [[ -z $hy2_port || $hy2_port == "$range_start" ]] || {
            die "--hy2-port must equal the Hysteria2 range start: $range_start"
        }
        if ((${#profile_protocol_list[@]} == 1)); then
            [[ -z $profile_port || $profile_port == "$range_start" ]] || {
                die "--port must equal the Hysteria2 range start: $range_start"
            }
        fi
        hy2_port=$range_start
        hy2_port_range="${range_start}:${range_end}"
    fi

    local effective_port specific_port
    local -A used_ports=()
    for protocol in "${profile_protocol_list[@]}"; do
        specific_port=''
        case "$protocol" in
        reality) specific_port=$reality_port ;;
        hysteria2) specific_port=$hy2_port ;;
        shadowsocks) specific_port=$shadowsocks_port ;;
        esac
        effective_port=$specific_port
        if ((${#profile_protocol_list[@]} == 1)) && [[ -n $profile_port ]]; then
            [[ -z $specific_port || $specific_port == "$profile_port" ]] || {
                die "--port conflicts with the protocol-specific port"
            }
            effective_port=$profile_port
        fi
        if [[ -n $effective_port ]]; then
            [[ -z ${used_ports[$effective_port]:-} ]] || die "protocol ports must be different: $effective_port"
            used_ports[$effective_port]=$protocol
        fi
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
        die "singbox-easy is already installed; run 'sb' to manage it"
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
        local protocol initial_name selected_port suffix
        local -a add_args created_names=()
        for protocol in "${profile_protocol_list[@]}"; do
            initial_name=$profile_name
            if ((${#profile_protocol_list[@]} > 1)); then
                case "$protocol" in
                reality) suffix='vless' ;;
                hysteria2) suffix='hy2' ;;
                shadowsocks) suffix='ss' ;;
                esac
                initial_name="${profile_name}-${suffix}"
            fi

            selected_port=$profile_port
            case "$protocol" in
            reality) [[ -z $reality_port ]] || selected_port=$reality_port ;;
            hysteria2) [[ -z $hy2_port ]] || selected_port=$hy2_port ;;
            shadowsocks) [[ -z $shadowsocks_port ]] || selected_port=$shadowsocks_port ;;
            esac

            add_args=(add "$protocol" "$initial_name")
            [[ -z $selected_port ]] || add_args+=(--port "$selected_port")
            [[ -z $profile_address ]] || add_args+=(--address "$profile_address")
            if [[ $protocol == reality && -n $profile_sni ]]; then
                add_args+=(--sni "$profile_sni")
            fi
            if [[ $protocol == hysteria2 && -n $hy2_port_range ]]; then
                add_args+=(--port-range "$hy2_port_range")
            fi
            log "creating the initial ${protocol} profile"
            "$MANAGER_BIN" "${add_args[@]}"
            created_names+=("$initial_name")
        done
    else
        log "no profile was created; the service remains disabled and stopped"
    fi

    log "installation completed"
    "$MANAGER_BIN" status
    if ((create_default_profile)); then
        local created_name
        for created_name in "${created_names[@]}"; do
            "$MANAGER_BIN" show "$created_name"
        done
    else
        printf 'Run sb to open the management menu.\n'
    fi
}

main "$@"
