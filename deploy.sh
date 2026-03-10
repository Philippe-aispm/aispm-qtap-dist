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
#    AISPM Qtap Semantic Layer
#    One-Line Installer
#
# Usage:
#   curl -fsSL https://your-server.com/deploy.sh | sudo bash
#
# Interactive mode (runs in foreground, useful for first install):
#   curl -fsSL https://your-server.com/deploy.sh | sudo MODE=interactive TOKEN=<token> bash
#
# Or with custom version:
#   curl -fsSL https://your-server.com/deploy.sh | sudo VERSION=v1.2.3 bash
#

set -euo pipefail

# ============================================================================
# Configuration Variables
# ============================================================================

QTAP_VERSION=${VERSION:-latest}
INSTALL_DIR=${INSTALL_DIR:-/opt/aispm-qtap}
PYTHON_FILES_URL=${PYTHON_FILES_URL:-}  # Set this to your deployment tarball URL
RUN_MODE=${MODE:-service}               # "service" (default) or "interactive"
QTAP_TOKEN=${TOKEN:-}                   # Qtap registration token
TENANT_ID=${TENANT_ID:-}               # Tenant identifier for multi-tenant deployments

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
    echo "${BOLD}${PURPLE}   AISPM Qtap Semantic Layer${NC}"
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

bold() {
    printf "${BOLD}%s${NC}" "$*"
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
        error "This script must be run as root. Please use: sudo bash"
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

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# Global: resolved Python binary path (set by check_python)
PYTHON_BIN=""

find_best_python() {
    # Try versioned binaries from newest to oldest, then generic python3
    local candidates=("python3.13" "python3.12" "python3.11" "python3.10" "python3")
    for cmd in "${candidates[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local ver
            ver=$("$cmd" --version 2>&1 | awk '{print $2}')
            local major minor
            major=$(echo "$ver" | cut -d. -f1)
            minor=$(echo "$ver" | cut -d. -f2)
            if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
                echo "$cmd"
                return 0
            fi
        fi
    done
    echo ""
    return 1
}

install_python() {
    local pkg_manager
    pkg_manager=$(detect_package_manager)

    info "Installing Python 3.10+ using ${pkg_manager}..."
    echo ""

    case "$pkg_manager" in
        apt)
            action "Updating package lists"
            DEBIAN_FRONTEND=noninteractive apt-get update -qq || error "Failed to update package lists"

            action "Installing Python 3, pip, and required dependencies"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-pip python3-venv python3-dev || \
                error "Failed to install Python via apt-get"
            ;;

        dnf)
            action "Installing Python 3, pip, and required dependencies"
            # Try generic python3 first, but verify it is >= 3.10.
            # Amazon Linux 2023 ships 3.9, RHEL 8 ships 3.6 — both too old.
            dnf install -y python3 python3-pip python3-devel 2>/dev/null || true
            local dnf_py_ver
            dnf_py_ver=$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo "0")
            if [ "$dnf_py_ver" -lt 10 ]; then
                info "System python3 is 3.${dnf_py_ver} (< 3.10), installing python3.11..."
                dnf install -y python3.11 python3.11-pip python3.11-devel || \
                    error "Failed to install Python 3.11 via dnf. Install manually: dnf install python3.11"
            fi
            ;;

        yum)
            action "Installing Python 3, pip, and required dependencies"
            # RHEL/CentOS: try versioned packages (3.11 → 3.10)
            if yum install -y python3.11 python3.11-pip python3.11-devel 2>/dev/null; then
                :
            elif yum install -y python3 python3-pip python3-devel 2>/dev/null; then
                :
            else
                error "Failed to install Python via yum"
            fi
            ;;

        zypper)
            action "Installing Python 3.11 (SLES/openSUSE)"
            # SLES 15: default python3 is 3.6. The Python 3 Module provides python311.
            # Try python311 first (SLES 15 SP4+), then python310, then generic.
            if zypper install -y python311 python311-pip python311-devel 2>/dev/null; then
                info "Installed python311 from Python 3 Module"
            elif zypper install -y python310 python310-pip python310-devel 2>/dev/null; then
                info "Installed python310 from Python 3 Module"
            else
                warn "Versioned Python packages not available, trying generic python3..."
                zypper install -y python3 python3-pip python3-devel || \
                    error "Failed to install Python via zypper. Install python311 manually."
            fi
            ;;

        pacman)
            action "Installing Python 3, pip, and required dependencies"
            pacman -S --noconfirm python python-pip || \
                error "Failed to install Python via pacman"
            ;;

        *)
            error "Unable to detect package manager. Please install Python 3.10+ manually:

    Debian/Ubuntu:  apt-get install python3 python3-pip python3-venv
    RHEL/CentOS:    dnf install python3.11 python3.11-pip python3.11-devel
    Fedora:         dnf install python3 python3-pip python3-devel
    SUSE/SLES:      zypper install python311 python311-pip python311-devel
    Arch:           pacman -S python python-pip
"
            ;;
    esac

    success "Python installation complete"
}

check_python() {
    action "Checking Python installation"

    # First: scan for any existing Python 3.10+ binary
    PYTHON_BIN=$(find_best_python) || true

    if [ -n "$PYTHON_BIN" ]; then
        local python_version
        python_version=$("$PYTHON_BIN" --version 2>&1 | awk '{print $2}')
        success "Python ${python_version} available (${PYTHON_BIN})"
        return
    fi

    # No suitable Python found — need to install
    local current_ver=""
    if command -v python3 >/dev/null 2>&1; then
        current_ver=$(python3 --version 2>&1 | awk '{print $2}')
        echo ""
        printf "${YELLOW}${CROSS_MARK} Python ${current_ver} is too old (minimum required: 3.10)${NC}\n"
        echo ""
        info "Current: Python ${current_ver} ($(command -v python3))"
    else
        echo ""
        printf "${YELLOW}${CROSS_MARK} Python 3 not found on this system${NC}\n"
        echo ""
    fi
    info "Required: Python 3.10 or newer"

    echo ""
    printf "${BOLD}The installer can automatically install Python for you.${NC}\n"
    echo ""

    local pkg_manager
    pkg_manager=$(detect_package_manager)

    if [ "$pkg_manager" != "unknown" ]; then
        printf "This will install: "
        case "$pkg_manager" in
            apt)
                printf "${DIM}python3 python3-pip python3-venv python3-dev${NC}\n"
                ;;
            dnf)
                printf "${DIM}python3 (or python3.11) + pip + devel${NC}\n"
                ;;
            yum)
                printf "${DIM}python3.11 + pip + devel${NC}\n"
                ;;
            zypper)
                printf "${DIM}python311 python311-pip python311-devel${NC}\n"
                ;;
            pacman)
                printf "${DIM}python python-pip${NC}\n"
                ;;
        esac
        echo ""

        # Auto-install if non-interactive, otherwise ask
        if [ -t 0 ]; then
            read -p "Install Python now? (Y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                install_python
            else
                error "Python installation declined. Cannot proceed without Python 3.10+"
            fi
        else
            info "Non-interactive mode: proceeding with automatic Python installation"
            install_python
        fi
    else
        error "Unable to detect package manager. Please install Python 3.10+ manually and re-run this script."
    fi

    # Re-scan after installation
    PYTHON_BIN=$(find_best_python) || true

    if [ -z "$PYTHON_BIN" ]; then
        error "No Python 3.10+ found after installation. Please install manually.

    SLES/openSUSE:  zypper install python311 python311-pip
    RHEL/CentOS 8:  dnf install python3.11 python3.11-pip
    Debian/Ubuntu:  apt-get install python3 python3-pip
"
    fi

    local python_version
    python_version=$("$PYTHON_BIN" --version 2>&1 | awk '{print $2}')
    success "Python ${python_version} available (${PYTHON_BIN})"
}

check_pip() {
    action "Checking pip installation"

    if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
        warn "pip not found for ${PYTHON_BIN}, attempting install"
        echo ""

        # Derive versioned pip package name from python binary
        # python3.11 → python3.11-pip (dnf/yum), python311-pip (zypper)
        local py_ver_dotted py_ver_nodot
        py_ver_dotted=$("$PYTHON_BIN" --version 2>&1 | awk '{print $2}' | cut -d. -f1-2)
        py_ver_nodot=$(echo "$py_ver_dotted" | tr -d '.')

        local pkg_manager
        pkg_manager=$(detect_package_manager)

        case "$pkg_manager" in
            apt)
                DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pip || \
                    error "Failed to install pip via apt-get"
                ;;
            dnf)
                dnf install -y "python${py_ver_dotted}-pip" 2>/dev/null || \
                dnf install -y python3-pip 2>/dev/null || \
                    error "Failed to install pip via dnf"
                ;;
            yum)
                yum install -y "python${py_ver_dotted}-pip" 2>/dev/null || \
                yum install -y python3-pip 2>/dev/null || \
                    error "Failed to install pip via yum"
                ;;
            zypper)
                zypper install -y "python${py_ver_nodot}-pip" 2>/dev/null || \
                zypper install -y python3-pip 2>/dev/null || \
                    error "Failed to install pip via zypper"
                ;;
            pacman)
                pacman -S --noconfirm python-pip >/dev/null 2>&1 || \
                    error "Failed to install pip via pacman"
                ;;
            *)
                error "Unable to install pip automatically. Please install pip for ${PYTHON_BIN} manually."
                ;;
        esac

        # Verify pip installation
        if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
            error "pip installation failed for ${PYTHON_BIN}. Please install manually."
        fi
    fi

    success "pip available ($("$PYTHON_BIN" -m pip --version 2>&1 | awk '{print $1,$2}'))"
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
# Python Semantic Layer Installation
# ============================================================================

install_python_layer() {
    action "Installing AISPM Semantic Layer"

    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/config"
    mkdir -p "$INSTALL_DIR/logs"

    # If files are available locally (installation from same directory)
    if [ -f "processor.py" ] && [ -f "engine.py" ]; then
        info "Installing from local files"

        cp processor.py "$INSTALL_DIR/"
        cp engine.py "$INSTALL_DIR/"
        cp models.py "$INSTALL_DIR/"
        cp constants.py "$INSTALL_DIR/"
        cp protocol_probe.py "$INSTALL_DIR/"
        cp aggregator.py "$INSTALL_DIR/"
        cp identify_host.sh "$INSTALL_DIR/"
        cp requirements.txt "$INSTALL_DIR/"

        # Copy config if exists
        if [ -d "config" ]; then
            cp -r config/* "$INSTALL_DIR/config/"
        fi

        success "Python files installed to ${INSTALL_DIR}"
    elif [ -n "$PYTHON_FILES_URL" ]; then
        info "Downloading from ${PYTHON_FILES_URL}"

        cd "$INSTALL_DIR"
        if ! curl -fsSL "$PYTHON_FILES_URL" | tar -xz --strip-components=1; then
            error "Failed to download Python files from ${PYTHON_FILES_URL}"
        fi

        success "Python files downloaded to ${INSTALL_DIR}"
    else
        error "Cannot find Python files. Either run this script from the source directory or set PYTHON_FILES_URL"
    fi

    # Install Python dependencies
    action "Installing Python dependencies"
    echo ""
    info "Required packages: $(cat "$INSTALL_DIR/requirements.txt" | tr '\n' ' ')"
    info "Using: ${PYTHON_BIN}"
    echo ""

    # Try system package manager first (handles PEP 668 / externally-managed-environment)
    local deps_installed=false
    local pkg_manager
    pkg_manager=$(detect_package_manager)

    # Derive versioned package names
    local py_ver_dotted py_ver_nodot
    py_ver_dotted=$("$PYTHON_BIN" --version 2>&1 | awk '{print $2}' | cut -d. -f1-2)
    py_ver_nodot=$(echo "$py_ver_dotted" | tr -d '.')

    if [ "$pkg_manager" = "apt" ]; then
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-yaml 2>&1 && \
           "$PYTHON_BIN" -c 'import yaml' 2>/dev/null; then
            deps_installed=true
            success "Python dependencies installed via apt"
        fi
    elif [ "$pkg_manager" = "dnf" ] || [ "$pkg_manager" = "yum" ]; then
        # Try versioned package first (python3.11-pyyaml), then generic (python3-pyyaml).
        # On Amazon Linux 2023, python3-pyyaml installs for system python3 (3.9),
        # not for python3.11, so we must try the versioned package first.
        if $pkg_manager install -y "python${py_ver_dotted}-pyyaml" >/dev/null 2>&1 && \
           "$PYTHON_BIN" -c 'import yaml' 2>/dev/null; then
            deps_installed=true
            success "Python dependencies installed via ${pkg_manager} (python${py_ver_dotted}-pyyaml)"
        elif $pkg_manager install -y python3-pyyaml >/dev/null 2>&1 && \
             "$PYTHON_BIN" -c 'import yaml' 2>/dev/null; then
            deps_installed=true
            success "Python dependencies installed via ${pkg_manager}"
        fi
    elif [ "$pkg_manager" = "zypper" ]; then
        # SLES: try versioned package (python311-PyYAML) then generic
        if zypper install -y "python${py_ver_nodot}-PyYAML" 2>/dev/null; then
            deps_installed=true
            success "Python dependencies installed via zypper (python${py_ver_nodot}-PyYAML)"
        elif zypper install -y python3-PyYAML 2>/dev/null; then
            deps_installed=true
            success "Python dependencies installed via zypper"
        fi
    fi

    # Fall back to pip if system packages didn't work
    if [ "$deps_installed" = false ]; then
        if ! "$PYTHON_BIN" -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1; then
            warn "Could not upgrade pip, continuing with current version"
        fi

        if "$PYTHON_BIN" -m pip install -r "$INSTALL_DIR/requirements.txt" 2>/dev/null; then
            success "Python dependencies installed via pip"
        elif "$PYTHON_BIN" -m pip install --break-system-packages -r "$INSTALL_DIR/requirements.txt" 2>/dev/null; then
            success "Python dependencies installed via pip (break-system-packages)"
        else
            error "Failed to install Python dependencies. Check pip and network connectivity."
        fi
    fi

    # Make scripts executable
    chmod +x "$INSTALL_DIR/processor.py"

    # Verify qtap config exists (shipped in tarball at config/qtap-config.yaml)
    if [ ! -f "$INSTALL_DIR/config/qtap-config.yaml" ]; then
        warn "config/qtap-config.yaml not found — qtap may not start correctly"
    fi

    # Set permissions
    chown -R root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    chmod 644 "$INSTALL_DIR"/*.py "$INSTALL_DIR"/*.yaml "$INSTALL_DIR"/*.txt 2>/dev/null || true
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

    cat > /etc/systemd/system/aispm-qtap.service <<EOF
[Unit]
Description=AISPM Qtap Semantic Layer
Documentation=https://github.com/qpoint-io/qtap
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/bin/bash -c 'stdbuf -oL /usr/local/bin/qtap ${svc_qtap_args} 2>&1 | ${PYTHON_BIN} -u ${INSTALL_DIR}/processor.py -c ${INSTALL_DIR}/config/rules.yaml --sni-config ${INSTALL_DIR}/config/sni-classifications.yaml --hostfile ${INSTALL_DIR}/config/host_id.json --unmatched ${INSTALL_DIR}/logs/unmatched.jsonl ${TENANT_ID:+--tenant-id ${TENANT_ID}} --log-level INFO --format summary -q 2>${INSTALL_DIR}/logs/debug.log'
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
        info "Usage: sudo MODE=interactive TOKEN=<your-token> bash deploy.sh"
        echo ""
    fi

    info "Qtap is starting in foreground mode. Press Ctrl+C to stop."
    echo ""
    echo "${DIM}  qtap ${qtap_args} | processor.py${NC}"
    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    cd "$INSTALL_DIR"

    # Disable pipefail for the interactive pipeline so we can report exit status
    set +o pipefail

    # Interactive pipeline:
    #   - qtap stdout (JSON events) → processor stdin
    #   - qtap stderr (status/log msgs) → terminal (visible to user)
    #   - processor stderr (logs) → terminal (visible to user)
    #   - processor stdout (matched records) → terminal (visible to user)
    # Note: service mode uses 2>&1 and 2>debug.log which is correct for
    # non-interactive operation; here we keep streams separate for visibility.
    stdbuf -oL /usr/local/bin/qtap ${qtap_args} < /dev/null | \
        "$PYTHON_BIN" -u "${INSTALL_DIR}/processor.py" -c "${INSTALL_DIR}/config/rules.yaml" \
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
            echo "    Then re-run with: sudo MODE=interactive TOKEN=<token> bash deploy.sh"
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
    local python_ver=$("$PYTHON_BIN" --version 2>&1 | awk '{print $2}')
    local qtap_ver=$(/usr/local/bin/qtap --version 2>/dev/null || echo "unknown")

    echo "${BOLD}${INVERT} Installed Components ${NC}"
    echo ""
    printf "  ${GREEN}✓${NC} Qtap eBPF Agent:    ${BOLD}%s${NC}\n" "$qtap_ver"
    printf "  ${GREEN}✓${NC} Python Runtime:     ${BOLD}%s${NC} (${PYTHON_BIN})\n" "$python_ver"
    printf "  ${GREEN}✓${NC} Semantic Layer:     ${BOLD}%s${NC}\n" "$INSTALL_DIR"
    if [ "$RUN_MODE" = "service" ]; then
        printf "  ${GREEN}✓${NC} Systemd Service:    ${BOLD}aispm-qtap.service${NC}\n"
    fi
    echo ""

    # Build the ready-to-run command
    local qtap_cmd="sudo stdbuf -oL /usr/local/bin/qtap --config=${INSTALL_DIR}/config/qtap-config.yaml --log-level=info"
    if [ -n "$QTAP_TOKEN" ]; then
        qtap_cmd="sudo stdbuf -oL /usr/local/bin/qtap --registration-token=${QTAP_TOKEN} --config=${INSTALL_DIR}/config/qtap-config.yaml --log-level=info"
    fi
    local proc_cmd="${PYTHON_BIN} -u ${INSTALL_DIR}/processor.py -c ${INSTALL_DIR}/config/rules.yaml --sni-config ${INSTALL_DIR}/config/sni-classifications.yaml --hostfile ${INSTALL_DIR}/config/host_id.json --format summary"

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
    check_python
    check_pip
    check_network

    echo ""
    echo "${BOLD}${INVERT} Installing Components ${NC}"
    echo ""

    install_qtap
    install_python_layer
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
