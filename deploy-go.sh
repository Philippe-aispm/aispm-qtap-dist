#!/usr/bin/env bash

#
#            ••••••••••
#       ••••••••••••••••••••
#     ••••••••••••••••••••••••
#   ••••••••••••••••••••••••••••
#  ••••••••••••••••••••••••••••••
# ••••••••••••••••••••••••••••••••
# ••••••••••••••••••••••••••••••••
#  ••••••••••••••••   •••••••••••
#   •••••••••••••••••   ••••••••
#     •••••••••••••••••   ••••
#       ••••••••••••••••••••
#            ••••••••••      *
#
#    AISPM Qtap Semantic Layer (Go)
#    One-Line Installer — No Python Required
#
# Remote one-liner (installs as systemd service):
#   curl -fsSL https://raw.githubusercontent.com/Philippe-aispm/aispm-qtap-dist/master/deploy-go.sh | \
#     sudo AISPM_VERSION=v1.7.2-go TENANT_ID=my-tenant bash
#
# Interactive mode (first install — register qtap):
#   curl -fsSL https://raw.githubusercontent.com/Philippe-aispm/aispm-qtap-dist/master/deploy-go.sh | \
#     sudo AISPM_VERSION=v1.7.2-go MODE=interactive TOKEN=<token> bash
#
# From extracted tarball (offline):
#   cd aispm-qtap && sudo bash deploy-go.sh
#

set -euo pipefail

# ============================================================================
# Configuration Variables
# ============================================================================

AISPM_VERSION=${AISPM_VERSION:-v1.7.2-go}    # AISPM semantic layer version (GitHub release tag)
QTAP_VERSION=${VERSION:-latest}
INSTALL_DIR=${INSTALL_DIR:-/opt/aispm-qtap}
RUN_MODE=${MODE:-service}                   # "service" (default) or "interactive"
QTAP_TOKEN=${TOKEN:-}                       # Qtap registration token
TENANT_ID=${TENANT_ID:-}                   # Tenant identifier for multi-tenant deployments
BINARY_NAME="aispm-qtap-processor"

# GitHub release URL for the Go tarball (override with GO_BINARY_URL if self-hosting)
GITHUB_REPO="Philippe-aispm/aispm-qtap-dist"
GO_BINARY_URL=${GO_BINARY_URL:-"https://github.com/${GITHUB_REPO}/releases/download/${AISPM_VERSION}/aispm-qtap-go-${AISPM_VERSION}.tar.gz"}

# ============================================================================
# Terminal Colors & Formatting
# ============================================================================

if [ -t 1 ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    PURPLE=$'\033[0;35m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    INVERT=$'\033[7m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' BOLD='' DIM='' INVERT='' NC=''
fi

CHECK_MARK="✓"
CROSS_MARK="✗"
WARN_MARK="!"
INFO_MARK="ℹ"
ARROW="→"

# ============================================================================
# Helper Functions
# ============================================================================

banner() {
    echo ""
    echo "${PURPLE}           ••••••••••            ${NC}"
    echo "${PURPLE}      ••••••••••••••••••••       ${NC}"
    echo "${PURPLE}    ••••••••••••••••••••••••     ${NC}"
    echo "${PURPLE}  ••••••••••••••••••••••••••••   ${NC}"
    echo "${PURPLE} ••••••••••••••••••••••••••••••  ${NC}"
    echo "${PURPLE}•••••••••••••••••••••••••••••••• ${NC}"
    echo "${PURPLE}•••••••••••••••••••••••••••••••• ${NC}"
    echo "${PURPLE} ••••••••••••••••   •••••••••••  ${NC}"
    echo "${PURPLE}  •••••••••••••••••   ••••••••   ${NC}"
    echo "${PURPLE}    •••••••••••••••••   ••••     ${NC}"
    echo "${PURPLE}      ••••••••••••••••••••       ${NC}"
    echo "${PURPLE}           ••••••••••      ${BOLD}*${NC}"
    echo ""
    echo "${BOLD}${PURPLE}   AISPM Qtap Semantic Layer (Go)${NC}"
    echo "${DIM}   One-Line Deployment Script${NC}"
    echo ""
}

action() {
    printf "${PURPLE}${ARROW} %s${NC}\n" "$*"
}

success() {
    printf "${GREEN}${CHECK_MARK} %s${NC}\n" "$*"
}

warn() {
    printf "${YELLOW}${WARN_MARK} %s${NC}\n" "$*" >&2
}

error() {
    printf "${RED}${CROSS_MARK} %s${NC}\n" "$*" >&2
    exit 1
}

info() {
    printf "${BLUE}${INFO_MARK} %s${NC}\n" "$*"
}

# ============================================================================
# Preflight Checks
# ============================================================================

check_os() {
    action "Checking operating system"

    case "$(uname -s)" in
        Linux*Microsoft*)
            error "Windows/WSL is not supported"
            ;;
        Linux*)
            success "Linux detected"
            ;;
        *)
            error "Unsupported OS: $(uname -s)"
            ;;
    esac
}

check_arch() {
    action "Checking architecture"

    case "$(uname -m)" in
        x86_64)
            ARCH="amd64"
            success "Architecture: ${ARCH}"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            success "Architecture: ${ARCH}"
            ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            ;;
    esac
}

check_root() {
    action "Checking privileges"

    if [ "$(id -u)" != "0" ]; then
        error "This script must be run as root. Please use: sudo bash deploy-go.sh"
    fi

    success "Running with root privileges"
}

check_kernel() {
    action "Checking kernel version"

    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1-2)

    if awk -v ver="$kernel_version" 'BEGIN{exit(!(ver >= 5.10))}'; then
        success "Kernel version: ${kernel_version} (>= 5.10 required)"
    else
        error "Kernel version ${kernel_version} is too old. Minimum required: 5.10"
    fi
}

check_bpf_capabilities() {
    action "Checking eBPF capabilities"

    # Check kernel lockdown
    local lockdown_file="/sys/kernel/security/lockdown"
    if [[ -f "$lockdown_file" ]]; then
        local lockdown_mode
        lockdown_mode=$(grep -o '\[\w\+\]' "$lockdown_file" | sed 's/\[\(.*\)\]/\1/' || echo "unknown")

        case "$lockdown_mode" in
            none)
                success "Kernel lockdown: none (optimal)"
                ;;
            integrity)
                warn "Kernel lockdown: integrity (some features may be restricted)"
                info "See: https://docs.qpoint.io/qtap/troubleshooting/linux-kernel-lockdown-for-ebpf-applications"
                ;;
            confidentiality)
                error "Kernel lockdown: confidentiality (unsupported). Please disable lockdown mode."
                ;;
            *)
                warn "Kernel lockdown: ${lockdown_mode} (unknown)"
                ;;
        esac
    else
        warn "Kernel lockdown file not found"
    fi

    # Check cgroups v2
    if mount | grep -q "cgroup2"; then
        success "Cgroups v2 enabled"
    else
        warn "Cgroups v2 not detected (may be required for some features)"
    fi
}

check_network() {
    action "Checking network connectivity"

    if ! curl -s --connect-timeout 5 https://downloads.qpoint.io >/dev/null 2>&1; then
        warn "Cannot reach downloads.qpoint.io (network check)"
    else
        success "Network connectivity verified"
    fi
}

# ============================================================================
# Qtap Installation
# ============================================================================

install_qtap() {
    action "Installing Qtap [${BOLD}${QTAP_VERSION}${NC}]"

    local tmpdir
    if ! tmpdir=$(mktemp -d); then
        error "Failed to create temporary directory"
    fi

    cd "$tmpdir"
    trap "rm -rf '$tmpdir'" EXIT INT

    local download_url
    download_url="https://downloads.qpoint.io/qpoint/qtap-${QTAP_VERSION}-linux-${ARCH}.tgz"

    if ! curl -fsSL "$download_url" > qtap.tgz; then
        error "Failed to download Qtap from ${download_url}"
    fi

    tar -xzf qtap.tgz
    mv qtap-* /usr/local/bin/qtap
    chmod +x /usr/local/bin/qtap

    local qtap_version
    qtap_version=$(/usr/local/bin/qtap --version 2>/dev/null || echo "unknown")
    success "Qtap installed: ${qtap_version} at /usr/local/bin/qtap"
}

# ============================================================================
# Go Processor Installation
# ============================================================================

install_go_processor() {
    action "Installing AISPM Semantic Layer (Go)"

    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/config"
    mkdir -p "$INSTALL_DIR/logs"
    chmod 777 "$INSTALL_DIR/logs"
    touch "$INSTALL_DIR/logs/unmatched.jsonl" "$INSTALL_DIR/logs/output.jsonl" "$INSTALL_DIR/logs/error.log" "$INSTALL_DIR/logs/debug.log"
    chmod 666 "$INSTALL_DIR/logs"/*.jsonl "$INSTALL_DIR/logs"/*.log

    # Determine source directory
    local source_dir=""

    # Option 1: Files are in the same directory (extracted tarball)
    if [ -f "${BINARY_NAME}" ] && [ -d "config" ]; then
        source_dir="."
    elif [ -f "$(dirname "$0")/${BINARY_NAME}" ] && [ -d "$(dirname "$0")/config" ]; then
        source_dir="$(dirname "$0")"
    fi

    if [ -n "$source_dir" ]; then
        info "Installing from local files (${source_dir})"

        # Copy binary
        cp "${source_dir}/${BINARY_NAME}" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/${BINARY_NAME}"

        # Copy config files
        cp -r "${source_dir}"/config/* "$INSTALL_DIR/config/"

        # Copy identify_host.sh if present
        if [ -f "${source_dir}/identify_host.sh" ]; then
            cp "${source_dir}/identify_host.sh" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/identify_host.sh"
        fi

        success "Go processor installed to ${INSTALL_DIR}"

    elif [ -n "$GO_BINARY_URL" ]; then
        info "Downloading from ${GO_BINARY_URL}"

        local tmpdir
        tmpdir=$(mktemp -d)

        if ! curl -fsSL "$GO_BINARY_URL" | tar -xz -C "$tmpdir"; then
            rm -rf "$tmpdir"
            error "Failed to download Go binary from ${GO_BINARY_URL}"
        fi

        # Find the extracted directory (aispm-qtap/)
        local extracted_dir="${tmpdir}/aispm-qtap"
        if [ ! -d "$extracted_dir" ]; then
            extracted_dir=$(find "$tmpdir" -maxdepth 1 -type d ! -name "$(basename "$tmpdir")" | head -1)
        fi

        if [ -z "$extracted_dir" ] || [ ! -f "${extracted_dir}/${BINARY_NAME}" ]; then
            rm -rf "$tmpdir"
            error "Downloaded tarball does not contain ${BINARY_NAME}"
        fi

        # Copy binary
        cp "${extracted_dir}/${BINARY_NAME}" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/${BINARY_NAME}"

        # Copy config
        if [ -d "${extracted_dir}/config" ]; then
            cp -r "${extracted_dir}"/config/* "$INSTALL_DIR/config/"
        fi

        # Copy identify_host.sh
        if [ -f "${extracted_dir}/identify_host.sh" ]; then
            cp "${extracted_dir}/identify_host.sh" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/identify_host.sh"
        fi

        rm -rf "$tmpdir"
        success "Go processor downloaded to ${INSTALL_DIR}"

    else
        error "Cannot find Go binary. Either:
  1. Run from extracted tarball directory (contains ${BINARY_NAME})
  2. Set GO_BINARY_URL to the tarball download URL
  3. Create a GitHub release at ${GITHUB_REPO} tagged ${AISPM_VERSION}"
    fi

    # Verify binary runs
    if ! "$INSTALL_DIR/${BINARY_NAME}" --help >/dev/null 2>&1; then
        error "Binary verification failed: ${INSTALL_DIR}/${BINARY_NAME}"
    fi

    # Verify qtap config exists
    if [ ! -f "$INSTALL_DIR/config/qtap-config.yaml" ]; then
        warn "config/qtap-config.yaml not found — qtap may not start correctly"
    fi

    # Set permissions
    chown -R root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    chmod 644 "$INSTALL_DIR/config"/*.yaml 2>/dev/null || true
}

# ============================================================================
# Host Identification
# ============================================================================

identify_host() {
    action "Identifying host environment"

    local host_script="${INSTALL_DIR}/identify_host.sh"
    local host_file="${INSTALL_DIR}/config/host_id.json"

    if [ ! -f "$host_script" ]; then
        warn "identify_host.sh not found, skipping host identification"
        return
    fi

    chmod +x "$host_script"
    if bash "$host_script" --pretty > "$host_file" 2>/dev/null; then
        success "Host identity saved to ${host_file}"
        echo ""
        cat "$host_file"
        echo ""
    else
        warn "Host identification failed (non-critical, continuing)"
    fi
}

# ============================================================================
# Service Configuration
# ============================================================================

create_systemd_service() {
    action "Creating systemd service"

    # Build qtap args for service
    local svc_qtap_args="--config=${INSTALL_DIR}/config/qtap-config.yaml --log-level=info"
    if [ -n "$QTAP_TOKEN" ]; then
        svc_qtap_args="--registration-token=${QTAP_TOKEN} ${svc_qtap_args}"
    fi

    # Build processor args
    local proc_args="-c ${INSTALL_DIR}/config/rules.yaml"
    proc_args="${proc_args} --sni-config ${INSTALL_DIR}/config/sni-classifications.yaml"
    proc_args="${proc_args} --hostfile ${INSTALL_DIR}/config/host_id.json"
    proc_args="${proc_args} --unmatched ${INSTALL_DIR}/logs/unmatched.jsonl"
    if [ -n "$TENANT_ID" ]; then
        proc_args="${proc_args} --tenant-id ${TENANT_ID}"
    fi
    proc_args="${proc_args} -q"

    cat > /etc/systemd/system/aispm-qtap.service <<EOF
[Unit]
Description=AISPM Qtap Semantic Layer (Go)
Documentation=https://github.com/qpoint-io/qtap
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/bin/bash -c 'stdbuf -oL /usr/local/bin/qtap ${svc_qtap_args} 2>&1 | ${INSTALL_DIR}/${BINARY_NAME} ${proc_args} 2>${INSTALL_DIR}/logs/debug.log'
Restart=always
RestartSec=10
StandardOutput=append:${INSTALL_DIR}/logs/output.jsonl
StandardError=append:${INSTALL_DIR}/logs/error.log

# Security hardening
NoNewPrivileges=false
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${INSTALL_DIR}/logs
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_SYS_RESOURCE CAP_NET_ADMIN CAP_BPF CAP_PERFMON

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    success "Systemd service created: aispm-qtap.service"
}

# ============================================================================
# Interactive Mode
# ============================================================================

run_interactive() {
    echo ""
    echo "${BOLD}${INVERT} Running Interactively ${NC}"
    echo ""

    # Build qtap command with optional token
    local qtap_args="--config=${INSTALL_DIR}/config/qtap-config.yaml --log-level=info"
    if [ -n "$QTAP_TOKEN" ]; then
        qtap_args="--registration-token=${QTAP_TOKEN} ${qtap_args}"
        success "Using provided registration token"
    else
        warn "No TOKEN provided. Qtap may exit if not already registered."
        info "Usage: sudo MODE=interactive TOKEN=<your-token> bash deploy-go.sh"
        echo ""
    fi

    info "Qtap is starting in foreground mode. Press Ctrl+C to stop."
    echo ""
    echo "${DIM}  qtap ${qtap_args} | ${BINARY_NAME}${NC}"
    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    cd "$INSTALL_DIR"

    # Disable pipefail for the interactive pipeline so we can report exit status
    set +o pipefail

    stdbuf -oL /usr/local/bin/qtap ${qtap_args} < /dev/null | \
        "${INSTALL_DIR}/${BINARY_NAME}" \
            -c "${INSTALL_DIR}/config/rules.yaml" \
            --sni-config "${INSTALL_DIR}/config/sni-classifications.yaml" \
            --hostfile "${INSTALL_DIR}/config/host_id.json" \
            --unmatched "${INSTALL_DIR}/logs/unmatched.jsonl" \
            ${TENANT_ID:+--tenant-id "$TENANT_ID"} \
            --log-level INFO --format summary

    local exit_code=$?
    echo ""
    echo "────────────────────────────────────────────────────────────────"

    if [ $exit_code -ne 0 ]; then
        warn "Qtap exited with code ${exit_code}"
        echo ""
        info "To troubleshoot, run qtap directly:"
        echo "    sudo /usr/local/bin/qtap ${qtap_args}"
        echo ""
        if [ -z "$QTAP_TOKEN" ]; then
            info "If you haven't registered yet, get a token at https://app.qpoint.io/"
            echo "    Then re-run with: sudo MODE=interactive TOKEN=<token> bash deploy-go.sh"
        fi
    else
        success "Qtap stopped cleanly"
    fi
}

# ============================================================================
# Usage Instructions
# ============================================================================

print_usage() {
    echo ""
    echo "${BOLD}${GREEN}✓ Installation Complete!${NC}"
    echo ""

    # Show what was installed
    local qtap_ver=$(/usr/local/bin/qtap --version 2>/dev/null || echo "unknown")

    echo "${BOLD}${INVERT} Installed Components ${NC}"
    echo ""
    printf "  ${GREEN}✓${NC} Qtap eBPF Agent:    ${BOLD}%s${NC}\n" "$qtap_ver"
    printf "  ${GREEN}✓${NC} Go Processor:       ${BOLD}%s${NC}\n" "${INSTALL_DIR}/${BINARY_NAME}"
    printf "  ${GREEN}✓${NC} Config Directory:   ${BOLD}%s${NC}\n" "${INSTALL_DIR}/config/"
    if [ "$RUN_MODE" = "service" ]; then
        printf "  ${GREEN}✓${NC} Systemd Service:    ${BOLD}aispm-qtap.service${NC}\n"
    fi
    echo ""

    # Build the ready-to-run command
    local qtap_cmd="sudo stdbuf -oL /usr/local/bin/qtap --config=${INSTALL_DIR}/config/qtap-config.yaml --log-level=info"
    if [ -n "$QTAP_TOKEN" ]; then
        qtap_cmd="sudo stdbuf -oL /usr/local/bin/qtap --registration-token=${QTAP_TOKEN} --config=${INSTALL_DIR}/config/qtap-config.yaml --log-level=info"
    fi
    local proc_cmd="${INSTALL_DIR}/${BINARY_NAME} -c ${INSTALL_DIR}/config/rules.yaml --sni-config ${INSTALL_DIR}/config/sni-classifications.yaml --hostfile ${INSTALL_DIR}/config/host_id.json --format summary"

    echo "${BOLD}${INVERT} Run the Agent ${NC}"
    echo ""
    echo "${DIM}Interactive (foreground):${NC}"
    echo ""
    echo "  ${BOLD}${qtap_cmd} \\${NC}"
    echo "  ${BOLD}  | ${proc_cmd}${NC}"
    echo ""

    if [ "$RUN_MODE" = "service" ]; then
        echo "${DIM}As a service:${NC}"
        echo ""
        echo "  ${BOLD}sudo systemctl start aispm-qtap${NC}"
        echo "  ${BOLD}sudo systemctl enable aispm-qtap${NC}"
        echo "  sudo systemctl status aispm-qtap"
        echo ""
    fi

    echo "${DIM}View logs:${NC}"
    echo ""
    echo "  tail -f ${INSTALL_DIR}/logs/output.jsonl     ${DIM}# matched events${NC}"
    echo "  tail -f ${INSTALL_DIR}/logs/unmatched.jsonl   ${DIM}# unmatched traffic${NC}"
    echo "  tail -f ${INSTALL_DIR}/logs/debug.log         ${DIM}# debug logs${NC}"
    echo ""
    echo "${DIM}Config:${NC}"
    echo ""
    echo "  ${INSTALL_DIR}/config/qtap-config.yaml            ${DIM}# Qtap eBPF config${NC}"
    echo "  ${INSTALL_DIR}/config/rules.yaml                  ${DIM}# Semantic layer rules${NC}"
    echo "  ${INSTALL_DIR}/config/sni-classifications.yaml    ${DIM}# SNI classification patterns${NC}"
    echo "  ${INSTALL_DIR}/config/host_id.json                ${DIM}# Host identity${NC}"
    echo ""
}

# ============================================================================
# Main Installation Flow
# ============================================================================

main() {
    banner

    echo "${BOLD}${INVERT} Running Preflight Checks ${NC}"
    echo ""

    check_os
    check_arch
    check_root
    check_kernel
    check_bpf_capabilities
    check_network

    echo ""
    echo "${BOLD}${INVERT} Installing Components ${NC}"
    echo ""

    install_qtap
    install_go_processor
    identify_host

    if [ "$RUN_MODE" = "interactive" ]; then
        print_usage
        run_interactive
    else
        create_systemd_service
        print_usage
    fi
}

# ============================================================================
# Execute
# ============================================================================

main "$@"
