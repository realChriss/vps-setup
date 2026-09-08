#!/usr/bin/env bash

set -Eeuo pipefail

readonly ZSHRC="/root/.zshrc"
readonly OMZ_DIR="/root/.oh-my-zsh"
readonly OMZ_CUSTOM="${OMZ_DIR}/custom"
readonly BLOCK_START="# >>> vps-setup >>>"
readonly BLOCK_END="# <<< vps-setup <<<"
readonly OMZ_PLUGINS="git docker docker-compose zsh-autosuggestions zsh-syntax-highlighting"

# Purging Ubuntu Pro takes the ubuntu-minimal / ubuntu-server metapackages with it,
# which makes everything they pulled in look auto-removable. These must never be
# removed by that purge or by the autoremove at the end — losing openssh-server or
# cloud-init on a VPS means losing the VPS.
readonly PROTECTED_PKGS="\
openssh-server openssh-client openssh-sftp-server sudo systemd systemd-sysv systemd-resolved \
dbus cloud-init netplan.io ifupdown rsyslog cron apt dpkg bash coreutils util-linux mount \
login passwd e2fsprogs initramfs-tools grub-common grub-pc grub-efi-amd64 grub2-common \
iproute2 iputils-ping ca-certificates curl git zsh unzip tar"

DO_DEBLOAT=true
NEW_HOSTNAME=""

WARNINGS=()
LOG=""
SPIN_PID=""

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    FANCY=true
    C_RESET=$'\033[0m';        C_B=$'\033[1m';            C_DIM=$'\033[2m'
    C_PINK=$'\033[38;5;211m';  C_MAUVE=$'\033[38;5;141m'; C_CYAN=$'\033[38;5;116m'
    C_MINT=$'\033[38;5;114m';  C_PEACH=$'\033[38;5;216m'; C_ROSE=$'\033[38;5;210m'
    C_GREY=$'\033[38;5;245m'
else
    FANCY=false
    C_RESET=""; C_B=""; C_DIM=""; C_PINK=""; C_MAUVE=""; C_CYAN=""
    C_MINT=""; C_PEACH=""; C_ROSE=""; C_GREY=""
fi

if [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" == *[Uu][Tt][Ff]* ]]; then
    S_OK="✔"; S_ERR="✖"; S_WARN="▲"; S_SKIP="·"; S_NO="✗"
    S_ARROW="❯"; S_STAR="✦"; S_PIPE="│"; S_TIP="›"
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    RULE="────────────────────────────────────────"
    BOX_TL="╭"; BOX_TR="╮"; BOX_BL="╰"; BOX_BR="╯"; BOX_H="─"; BOX_V="│"
else
    S_OK="+"; S_ERR="x"; S_WARN="!"; S_SKIP="-"; S_NO="x"
    S_ARROW=">"; S_STAR="*"; S_PIPE="|"; S_TIP=">"
    SPIN=('|' '/' '-' '\')
    RULE="----------------------------------------"
    BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"
fi

journal() {
    [[ -n "$LOG" ]] || return 0
    printf '%s\n' "$*" | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >> "$LOG" 2>/dev/null || true
}

step() {
    printf '\n  %s%s%s %s%s%s\n' "$C_MAUVE" "$S_ARROW" "$C_RESET" "$C_B" "$*" "$C_RESET"
    journal "== $*"
}
ok()   { printf '    %s%s%s %s\n' "$C_MINT" "$S_OK" "$C_RESET" "$*"; journal "  ok   $*"; }
skip() { printf '    %s%s %s%s\n' "$C_DIM" "$S_SKIP" "$*" "$C_RESET"; journal "  skip $*"; }
warn() { printf '    %s%s%s %s\n' "$C_PEACH" "$S_WARN" "$C_RESET" "$*"; journal "  warn $*"; WARNINGS+=("$*"); }
bad()  { printf '    %s%s%s %s\n' "$C_ROSE" "$S_ERR" "$C_RESET" "$*"; journal "  FAIL $*"; }
note() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; journal "  .    $*"; }

die() {
    spin_stop
    printf '\n  %s%s  %s%s\n' "$C_ROSE" "$S_ERR" "$*" "$C_RESET" >&2
    [[ -n "$LOG" ]] && printf '  %slog: %s%s\n\n' "$C_DIM" "$LOG" "$C_RESET" >&2
    exit 1
}

on_error() {
    local rc=$1 line=$2
    spin_stop
    printf '\n  %s%s  stopped at line %s (exit %s)%s\n' "$C_ROSE" "$S_ERR" "$line" "$rc" "$C_RESET" >&2
    [[ -n "$LOG" ]] && printf '  %slog: %s%s\n\n' "$C_DIM" "$LOG" "$C_RESET" >&2
    exit "$rc"
}
trap 'on_error $? $LINENO' ERR
trap 'spin_stop; [[ "$FANCY" == true ]] && printf "\033[?25h" || true' EXIT

spin_start() {
    [[ "$FANCY" == true ]] || { printf '    %s%s %s…%s\n' "$C_DIM" "$S_SKIP" "$*" "$C_RESET"; return 0; }
    local msg="$1"
    printf '\033[?25l'
    (
        local i=0
        while :; do
            printf '\r    %s%s%s %s%s%s' "$C_CYAN" "${SPIN[i++ % ${#SPIN[@]}]}" "$C_RESET" "$C_GREY" "$msg" "$C_RESET"
            sleep 0.08
        done
    ) &
    SPIN_PID=$!
}

spin_stop() {
    [[ -n "$SPIN_PID" ]] || return 0
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
    printf '\r\033[2K\033[?25h'
}

fmt_dur() {
    local s=$1
    if (( s < 60 )); then printf '%ds' "$s"; else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}

# Everything noisy goes through here: output lands in the log, the shell only
# gets a tick, a cross, and on failure the lines that actually explain it.
run() {
    local msg="$1"; shift
    local t0=$SECONDS rc=0 out
    out="$(mktemp "${TMPDIR:-/tmp}/vps-setup.XXXXXX")"

    spin_start "$msg"
    "$@" >"$out" 2>&1 </dev/null || rc=$?
    spin_stop

    if [[ -n "$LOG" ]]; then
        { printf '\n----- %s (exit %s) -----\n' "$msg" "$rc"; cat "$out"; } >> "$LOG" 2>/dev/null || true
    fi

    if [[ $rc -eq 0 ]]; then
        printf '    %s%s%s %-44s %s%s%s\n' \
            "$C_MINT" "$S_OK" "$C_RESET" "$msg" "$C_DIM" "$(fmt_dur $((SECONDS - t0)))" "$C_RESET"
        journal "  ok   $msg"
    else
        bad "$msg  (exit $rc)"
        show_why "$out"
    fi

    rm -f "$out"
    return "$rc"
}

show_why() {
    local line
    while IFS= read -r line; do
        printf '      %s%s%s %s%s%s\n' "$C_ROSE" "$S_PIPE" "$C_RESET" "$C_DIM" "$line" "$C_RESET"
        journal "       | $line"
    done < <(
        grep -vE '^[[:space:]]*$' "$1" \
        | grep -viE '^(get:|hit:|ign:|reading |building |selecting |preparing |unpacking |setting up |processing triggers|extracting |\(reading database)' \
        | tail -n 8
    )
}

# Reads from /dev/tty so `curl … | bash` still gets answers from the keyboard.
ask() {
    local prompt="$1" default="$2" reply=""
    if [[ -r /dev/tty ]]; then
        read -r -p "$prompt" reply < /dev/tty || reply=""
    elif [[ -t 0 ]]; then
        read -r -p "$prompt" reply || reply=""
    else
        die "no terminal to ask on — run this script from an interactive shell"
    fi
    printf '%s\n' "${reply:-$default}"
}

confirm() {
    local prompt="$1" default="${2:-y}" hint="Y/n" answer=""
    [[ "${default,,}" == "n" ]] && hint="y/N"
    while true; do
        answer="$(ask "$(printf '    %s%s%s %s %s[%s] %s' \
            "$C_PINK" "$S_TIP" "$C_RESET" "$prompt" "$C_DIM" "$hint" "$C_RESET")" "$default")"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     printf '      %sy or n, cutie%s\n' "$C_DIM" "$C_RESET" >&2 ;;
        esac
    done
}

valid_hostname() {
    local h="$1" label
    [[ ${#h} -le 253 ]] || return 1
    [[ "$h" != *".."* ]] || return 1
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
    while IFS= read -r label; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    done < <(tr '.' '\n' <<< "$h")
    return 0
}

have_systemd() { [[ -d /run/systemd/system ]]; }

sysd() {
    if have_systemd; then
        systemctl "$@" >/dev/null 2>&1 || true
    fi
    return 0
}

apt_get() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=a \
        apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$@"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

would_remove() {
    DEBIAN_FRONTEND=noninteractive apt-get -s "$@" 2>/dev/null | awk '/^Remv /{print $2}' || true
}

protected_hits() {
    local p hits=""
    for p in $1; do
        case " $PROTECTED_PKGS " in
            *" $p "*) hits+=" $p"; continue ;;
        esac
        case "$p" in
            linux-image-*|linux-headers-*|linux-generic*|linux-virtual*) hits+=" $p" ;;
        esac
    done
    printf '%s' "$hits"
}

short_list() {
    local -a items=("$@")
    if [[ ${#items[@]} -le 3 ]]; then
        printf '%s' "${items[*]}"
    else
        printf '%s +%d more' "${items[*]:0:3}" $(( ${#items[@]} - 3 ))
    fi
}

purge_if_installed() {
    local pkgs=() p
    for p in "$@"; do
        if pkg_installed "$p"; then pkgs+=("$p"); fi
    done
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return 0
    fi
    run "purge $(short_list "${pkgs[@]}")" apt_get purge "${pkgs[@]}" \
        || warn "could not purge: ${pkgs[*]}"
}

as_root_home() {
    env HOME=/root USER=root LOGNAME=root SHELL=/bin/bash "$@"
}

detect_distro() {
    [[ $EUID -eq 0 ]] || die "run this as root (sudo -i, then ./main.sh)"
    [[ -r /etc/os-release ]] || die "/etc/os-release not found — unsupported system"

    # shellcheck disable=SC1091
    . /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

    case "$DISTRO_ID" in
        ubuntu) DOCKER_DISTRO="ubuntu"; IS_UBUNTU=true ;;
        debian) DOCKER_DISTRO="debian"; IS_UBUNTU=false ;;
        *)
            if [[ " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
                DOCKER_DISTRO="ubuntu"; IS_UBUNTU=true
            elif [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
                DOCKER_DISTRO="debian"; IS_UBUNTU=false
            else
                die "unsupported distro '$DISTRO_ID' — this script targets Ubuntu and Debian"
            fi
            ;;
    esac

    # Ubuntu derivatives carry UBUNTU_CODENAME; that is the one Docker's repo knows about.
    DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$DOCKER_CODENAME" ]] || warn "no release codename found; Docker repo setup may fail"
}

banner() {
    local title="  ${S_STAR}  v p s   s e t u p  ${S_STAR}  " bar
    printf -v bar '%*s' "${#title}" ''
    bar="${bar// /$BOX_H}"

    printf '\n  %s%s%s%s%s\n' "$C_PINK" "$BOX_TL" "$bar" "$BOX_TR" "$C_RESET"
    printf '  %s%s%s%s%s%s%s%s%s\n' \
        "$C_PINK" "$BOX_V" "$C_RESET" "$C_B" "$C_MAUVE" "$title" "$C_RESET" \
        "$C_PINK" "${BOX_V}${C_RESET}"
    printf '  %s%s%s%s%s\n' "$C_PINK" "$BOX_BL" "$bar" "$BOX_BR" "$C_RESET"
    printf '   %s%s %s%s\n' "$C_DIM" "$S_STAR" "$DISTRO_NAME" "$C_RESET"
}

gather_answers() {
    local current answer

    current="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo localhost)"

    step "a few questions"
    printf '\n'

    while true; do
        answer="$(ask "$(printf '    %s%s%s hostname %s[%s] %s' \
            "$C_PINK" "$S_TIP" "$C_RESET" "$C_DIM" "$current" "$C_RESET")" "$current")"
        if [[ "$answer" == "$current" ]]; then
            NEW_HOSTNAME=""; break
        elif valid_hostname "$answer"; then
            NEW_HOSTNAME="$answer"; break
        else
            printf '      %sletters, digits, hyphens and dots only%s\n' "$C_DIM" "$C_RESET" >&2
        fi
    done

    if [[ "$IS_UBUNTU" == true ]]; then
        confirm "kill snap, telemetry and pro ads?" y && DO_DEBLOAT=true || DO_DEBLOAT=false
    else
        DO_DEBLOAT=false
    fi

    confirm "zoxide?" y && INSTALL_ZOXIDE=true || INSTALL_ZOXIDE=false
    confirm "eza (takes over ls)?" y && INSTALL_EZA=true || INSTALL_EZA=false
    confirm "docker + compose?" y && INSTALL_DOCKER=true || INSTALL_DOCKER=false
    confirm "bun?" y && INSTALL_BUN=true || INSTALL_BUN=false
    confirm "btop?" y && INSTALL_BTOP=true || INSTALL_BTOP=false
    confirm "dtop?" y && INSTALL_DTOP=true || INSTALL_DTOP=false

    step "the plan"
    printf '\n'
    plan_row true "full system upgrade"
    plan_row "$DO_DEBLOAT" "snap, telemetry & pro ads out"
    plan_row true "zsh + oh my zsh + plugins"
    plan_row "$INSTALL_ZOXIDE" "zoxide"
    plan_row "$INSTALL_EZA" "eza (aliased over ls, dotfiles shown)"
    plan_row "$INSTALL_DOCKER" "docker + compose"
    plan_row "$INSTALL_BUN" "bun"
    plan_row "$INSTALL_BTOP" "btop"
    plan_row "$INSTALL_DTOP" "dtop"
    if [[ -n "$NEW_HOSTNAME" ]]; then
        plan_row true "hostname $C_B$NEW_HOSTNAME$C_RESET"
    else
        plan_row true "hostname stays $current"
    fi
    printf '\n'

    confirm "let's go?" y || { printf '\n    %suntouched. bye ♡%s\n\n' "$C_DIM" "$C_RESET"; exit 0; }
}

plan_row() {
    if [[ "$1" == true ]]; then
        printf '    %s%s%s %s\n' "$C_MINT" "$S_OK" "$C_RESET" "$2"
    else
        printf '    %s%s %s%s\n' "$C_DIM" "$S_NO" "$2" "$C_RESET"
    fi
}

set_hostname() {
    if [[ -z "$NEW_HOSTNAME" ]]; then
        step "hostname"; skip "left alone"; return 0
    fi
    step "hostname"

    if have_systemd && command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$NEW_HOSTNAME" >/dev/null 2>&1 \
            || warn "hostnamectl failed; writing /etc/hostname anyway"
    fi
    printf '%s\n' "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME" 2>/dev/null || true

    local short="${NEW_HOSTNAME%%.*}" names="$NEW_HOSTNAME"
    [[ "$short" != "$NEW_HOSTNAME" ]] && names="$NEW_HOSTNAME $short"

    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i -E "s|^127\.0\.1\.1[[:space:]].*|127.0.1.1\t${names}|" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$names" >> /etc/hosts
    fi
    ok "now called $C_B$NEW_HOSTNAME$C_RESET"

    # cloud-init re-applies the provider's hostname on every boot unless told not to.
    if [[ -d /etc/cloud ]]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
        ok "cloud-init told to keep it across reboots"
    fi
}

update_system() {
    step "system"
    run "refreshing package lists" apt_get update \
        || die "apt could not reach the archives — check DNS and networking"
    run "upgrading everything (slow part)" apt_get dist-upgrade \
        || die "dist-upgrade failed"
    run "base packages (curl, git, zsh, unzip…)" apt_get install ca-certificates curl gnupg git zsh unzip tar \
        || die "could not install the base packages"
}

# Marks the core set manual so removing the Ubuntu metapackages later cannot make
# it look like an unused dependency.
protect_core_packages() {
    local keep=(
        openssh-server openssh-client openssh-sftp-server sudo cloud-init netplan.io ifupdown
        systemd systemd-sysv systemd-resolved dbus rsyslog cron ufw unattended-upgrades
        ca-certificates curl wget gnupg git zsh unzip tar less nano vim-tiny
        iproute2 iputils-ping net-tools initramfs-tools e2fsprogs
        linux-generic linux-image-generic linux-image-virtual linux-virtual
        grub-pc grub-efi-amd64 grub2-common software-properties-common
    )
    local present=() p
    for p in "${keep[@]}"; do
        if pkg_installed "$p"; then present+=("$p"); fi
    done
    if [[ ${#present[@]} -gt 0 ]]; then
        apt-mark manual "${present[@]}" >/dev/null 2>&1 || true
        ok "${#present[@]} core packages pinned so nothing eats them"
    fi
}

snap_purge_all() {
    local pass snaps=() name
    command -v snap >/dev/null 2>&1 || return 0
    for pass in 1 2 3; do
        mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)
        [[ ${#snaps[@]} -gt 0 ]] || break
        # apps first, then bases/core/snapd — snapd refuses to drop a base still in use
        for name in "${snaps[@]}"; do
            case "$name" in core*|snapd|bare) continue ;; esac
            timeout 180 snap remove --purge "$name" || true
        done
        for name in "${snaps[@]}"; do
            case "$name" in
                core*|snapd|bare) timeout 180 snap remove --purge "$name" || true ;;
            esac
        done
    done
    return 0
}

remove_snap() {
    if command -v snap >/dev/null 2>&1; then
        run "yeeting every installed snap" snap_purge_all || warn "some snaps refused to go"
    fi

    sysd disable --now snapd.service
    sysd disable --now snapd.socket
    sysd disable --now snapd.seeded.service
    sysd disable --now snapd.snap-repair.timer

    purge_if_installed snapd
    apt-mark hold snapd >/dev/null 2>&1 || true

    # Negative pin so nothing can pull snapd back in as a dependency.
    cat > /etc/apt/preferences.d/no-snap.pref <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap
    ok "snap purged, held and pinned at -10"
    note "lxd and other snap-backed packages will refuse to install now"
}

remove_telemetry() {
    purge_if_installed popularity-contest ubuntu-report apport apport-symptoms whoopsie
    if [[ -f /etc/default/apport ]]; then
        sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
    fi
    sysd disable --now apport.service
    sysd disable --now whoopsie.service
    purge_if_installed landscape-common landscape-client
    ok "crash reporting, popcon and landscape gone"
}

remove_motd_ads() {
    local f
    if [[ -f /etc/default/motd-news ]]; then
        sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
    fi
    sysd disable --now motd-news.timer
    sysd disable --now motd-news.service

    for f in 10-help-text 50-motd-news 80-livepatch 88-esm-announce \
             91-contract-ua-esm-status 91-release-upgrade 95-hwe-eol; do
        if [[ -f "/etc/update-motd.d/$f" ]]; then
            chmod -x "/etc/update-motd.d/$f" || true
        fi
    done
    ok "motd news, livepatch and upgrade nags silenced"
}

remove_ubuntu_pro() {
    local candidates=(ubuntu-advantage-tools ubuntu-pro-client ubuntu-advantage-desktop-daemon ubuntu-pro-auto-attach)
    local present=() p removals bad

    for p in "${candidates[@]}"; do
        if pkg_installed "$p"; then present+=("$p"); fi
    done
    if [[ ${#present[@]} -eq 0 ]]; then
        skip "ubuntu pro client not installed"
        return 0
    fi

    if command -v pro >/dev/null 2>&1; then
        pro config set apt_news=false >/dev/null 2>&1 || true
    fi

    # Dry run first — this purge drops ubuntu-minimal/ubuntu-server, so make very
    # sure it is not about to take sshd or the kernel with it.
    removals="$(would_remove purge "${present[@]}")"
    bad="$(protected_hits "$removals")"
    if [[ -n "$bad" ]]; then
        warn "left ubuntu pro alone — removing it would also take:$bad"
        return 0
    fi

    purge_if_installed "${present[@]}"
    rm -f /etc/apt/apt.conf.d/20apt-esm-hook.conf
    ok "ubuntu pro / esm ads removed"
}

debloat() {
    if [[ "$IS_UBUNTU" != true ]]; then
        step "de-bloat"; skip "not ubuntu, nothing to do"; return 0
    fi
    if [[ "$DO_DEBLOAT" != true ]]; then
        step "de-bloat"; skip "skipped"; return 0
    fi

    step "taking out the trash"
    protect_core_packages
    remove_snap
    remove_telemetry
    remove_motd_ads
    remove_ubuntu_pro
}

omz_install() {
    local tmp rc=0
    tmp="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$tmp" \
        || { rm -f "$tmp"; return 1; }
    env HOME=/root USER=root LOGNAME=root SHELL=/bin/bash RUNZSH=no CHSH=no KEEP_ZSHRC=no \
        sh "$tmp" --unattended || rc=$?
    rm -f "$tmp"
    return "$rc"
}

install_omz() {
    step "zsh dressing room"

    if [[ -d "$OMZ_DIR" ]]; then
        skip "oh my zsh already here"
    else
        run "oh my zsh" omz_install || die "oh my zsh install failed"
    fi
    [[ -f "$ZSHRC" ]] || die "oh my zsh did not create $ZSHRC"

    local name url
    mkdir -p "$OMZ_CUSTOM/plugins"
    for name in zsh-autosuggestions zsh-syntax-highlighting; do
        url="https://github.com/zsh-users/${name}.git"
        if [[ -d "$OMZ_CUSTOM/plugins/$name/.git" ]]; then
            run "updating $name" git -C "$OMZ_CUSTOM/plugins/$name" pull --ff-only \
                || warn "could not update $name"
        else
            run "plugin $name" git clone --depth=1 "$url" "$OMZ_CUSTOM/plugins/$name" \
                || warn "could not install $name"
        fi
    done

    # zsh-syntax-highlighting must stay last — it wraps the ZLE widgets the others register.
    if grep -qE '^[[:space:]]*plugins=\(' "$ZSHRC"; then
        sed -i -E "s|^[[:space:]]*plugins=\(.*\)[[:space:]]*$|plugins=($OMZ_PLUGINS)|" "$ZSHRC"
    else
        printf 'plugins=(%s)\n' "$OMZ_PLUGINS" >> "$ZSHRC"
    fi
    if grep -qE "^plugins=\(${OMZ_PLUGINS// /[[:space:]]}\)$" "$ZSHRC"; then
        ok "plugins wired up"
    else
        warn "could not rewrite plugins=() — set it by hand in $ZSHRC to: plugins=($OMZ_PLUGINS)"
    fi
}

zoxide_upstream() {
    as_root_home sh -c 'curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh' || return 1
    [[ -x /root/.local/bin/zoxide ]]
}

install_zoxide() {
    if [[ "$INSTALL_ZOXIDE" != true ]]; then
        step "zoxide"; skip "skipped"; return 0
    fi
    step "zoxide"
    if command -v zoxide >/dev/null 2>&1 || [[ -x /root/.local/bin/zoxide ]]; then
        skip "already installed"
        return 0
    fi

    # The upstream installer keeps us on a modern release; distro packages lag badly.
    if run "zoxide (upstream installer)" zoxide_upstream; then
        ok "$(/root/.local/bin/zoxide --version 2>/dev/null || echo zoxide) in ~/.local/bin"
    elif run "zoxide (apt fallback)" apt_get install zoxide; then
        ok "installed from apt"
    else
        warn "zoxide could not be installed"
    fi
}

eza_arch() {
    case "$(dpkg --print-architecture)" in
        amd64) printf 'x86_64-unknown-linux-musl' ;;
        arm64) printf 'aarch64-unknown-linux-gnu' ;;
        armhf) printf 'arm-unknown-linux-gnueabihf' ;;
        *)     return 1 ;;
    esac
}

eza_upstream() {
    local arch tmp bin rc=0
    arch="$(eza_arch)" || return 1
    tmp="$(mktemp -d)"
    {
        curl -fsSL "https://github.com/eza-community/eza/releases/latest/download/eza_${arch}.tar.gz" \
            -o "$tmp/eza.tar.gz" \
        && tar -xzf "$tmp/eza.tar.gz" -C "$tmp"
    } || rc=1

    if [[ $rc -eq 0 ]]; then
        bin="$(find "$tmp" -type f -name eza -perm -u+x 2>/dev/null | head -n1)"
        [[ -n "$bin" ]] || bin="$(find "$tmp" -type f -name eza 2>/dev/null | head -n1)"
        if [[ -n "$bin" ]]; then
            install -m 0755 "$bin" /usr/local/bin/eza || rc=1
        else
            rc=1
        fi
    fi

    rm -rf "$tmp"
    return "$rc"
}

eza_version() {
    "${1:-eza}" --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

install_eza() {
    if [[ "$INSTALL_EZA" != true ]]; then
        step "eza"; skip "skipped"; return 0
    fi
    step "eza"

    if command -v eza >/dev/null 2>&1; then
        skip "already installed ($(eza_version))"
        return 0
    fi

    if run "eza (static build from github)" eza_upstream; then
        ok "eza $(eza_version /usr/local/bin/eza) in /usr/local/bin"
    elif apt_has eza && run "eza (apt fallback)" apt_get install eza; then
        ok "eza $(eza_version) from apt"
    else
        die "eza could not be installed — asked for, so stopping here"
    fi
}

docker_repo() {
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$DOCKER_DISTRO" "$DOCKER_CODENAME" \
        > /etc/apt/sources.list.d/docker.list
}

install_docker() {
    if [[ "$INSTALL_DOCKER" != true ]]; then
        step "docker"; skip "skipped"; return 0
    fi
    step "docker"

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        skip "docker and compose already here"
    else
        purge_if_installed docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc

        run "adding docker's apt repo" docker_repo || die "could not fetch docker's signing key"
        run "refreshing package lists" apt_get update || die "apt update failed after adding the docker repo"
        run "docker-ce, containerd, buildx, compose" \
            apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
            || die "docker packages failed to install"
    fi

    sysd enable --now containerd.service
    sysd enable --now docker.service

    if docker --version >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "$(docker --version | sed 's/,.*//')"
        ok "compose $(docker compose version --short)"
    else
        warn "docker installed but not answering — check 'systemctl status docker'"
    fi
}

bun_install() {
    as_root_home bash -c 'curl -fsSL https://bun.sh/install | bash' || return 1
    [[ -x /root/.bun/bin/bun ]]
}

install_bun() {
    if [[ "$INSTALL_BUN" != true ]]; then
        step "bun"; skip "skipped"; return 0
    fi
    step "bun"

    if [[ -x /root/.bun/bin/bun ]]; then
        skip "already installed ($(/root/.bun/bin/bun --version 2>/dev/null))"
        return 0
    fi

    pkg_installed unzip || run "unzip (bun needs it)" apt_get install unzip || true
    if run "bun" bun_install; then
        ok "bun $(/root/.bun/bin/bun --version)"
    else
        warn "bun failed — retry later with: curl -fsSL https://bun.sh/install | bash"
    fi
}

btop_arch() {
    case "$(dpkg --print-architecture)" in
        amd64) printf 'x86_64-unknown-linux-musl' ;;
        arm64) printf 'aarch64-unknown-linux-musl' ;;
        armhf) printf 'armv7-unknown-linux-musleabi' ;;
        i386)  printf 'i686-unknown-linux-musl' ;;
        *)     return 1 ;;
    esac
}

# Escape hatch for releases that do not ship btop at all (Debian 11 has it in
# backports only): the upstream static musl build needs nothing from the system.
btop_upstream() {
    local arch tmp rc=0
    arch="$(btop_arch)" || return 1
    tmp="$(mktemp -d)"
    {
        curl -fsSL "https://github.com/aristocratos/btop/releases/latest/download/btop-${arch}.tar.gz" \
            -o "$tmp/btop.tar.gz" \
        && tar -xzf "$tmp/btop.tar.gz" -C "$tmp" \
        && install -m 0755 "$tmp/btop/bin/btop" /usr/local/bin/btop
    } || rc=1
    if [[ $rc -eq 0 && -d "$tmp/btop/themes" ]]; then
        mkdir -p /usr/local/share/btop
        cp -r "$tmp/btop/themes" /usr/local/share/btop/ || true
    fi
    rm -rf "$tmp"
    return "$rc"
}

apt_has() {
    local cand
    cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')"
    [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Tools that colour their --version output leave a reset sequence inside our line,
# which cancels the dim styling for everything printed after it.
strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/[[:cntrl:]]//g'; }

btop_version() {
    "${1:-btop}" --version 2>/dev/null | awk 'NR==1 {print $NF; exit}' | strip_ansi || true
}

install_btop() {
    if [[ "$INSTALL_BTOP" != true ]]; then
        step "btop"; skip "skipped"; return 0
    fi
    step "btop"

    if command -v btop >/dev/null 2>&1; then
        skip "already installed ($(btop_version))"
        return 0
    fi

    if apt_has btop && run "btop (apt)" apt_get install btop; then
        ok "btop $(btop_version)"
    elif run "btop (static build from github)" btop_upstream; then
        ok "btop $(btop_version /usr/local/bin/btop) in /usr/local/bin"
    else
        warn "btop could not be installed"
    fi
}

# DTOP_NO_MODIFY_PATH keeps the installer out of .zshrc — ~/.local/bin is already
# on PATH from the block this script writes.
dtop_install() {
    as_root_home env DTOP_NO_MODIFY_PATH=1 sh -c \
        "curl --proto '=https' --tlsv1.2 -LsSf https://github.com/amir20/dtop/releases/latest/download/dtop-installer.sh | sh" \
        || return 1
    [[ -x /root/.local/bin/dtop ]]
}

install_dtop() {
    if [[ "$INSTALL_DTOP" != true ]]; then
        step "dtop"; skip "skipped"; return 0
    fi
    step "dtop"

    if [[ -x /root/.local/bin/dtop ]] || command -v dtop >/dev/null 2>&1; then
        skip "already installed"
        return 0
    fi

    if run "dtop (upstream installer)" dtop_install; then
        ok "$(/root/.local/bin/dtop --version 2>/dev/null | head -n1 | strip_ansi || echo dtop) in ~/.local/bin"
        command -v docker >/dev/null 2>&1 || note "it needs a docker daemon to show anything"
    else
        warn "dtop could not be installed — retry later from https://dtop.dev"
    fi
}

write_zshrc_block() {
    step "wiring up .zshrc"

    # Drop the previous block first so re-runs never stack duplicates.
    sed -i "\|^${BLOCK_START}$|,\|^${BLOCK_END}$|d" "$ZSHRC"

    cat >> "$ZSHRC" <<EOF
${BLOCK_START}
export PATH="\$HOME/.local/bin:\$PATH"

# bun
export BUN_INSTALL="\$HOME/.bun"
[ -d "\$BUN_INSTALL/bin" ] && export PATH="\$BUN_INSTALL/bin:\$PATH"
[ -s "\$BUN_INSTALL/_bun" ] && source "\$BUN_INSTALL/_bun"
EOF

    if [[ "$INSTALL_ZOXIDE" == true ]]; then
        cat >> "$ZSHRC" <<EOF

# zoxide — 'z <dir>' to jump around, 'zi' for the interactive picker
command -v zoxide >/dev/null 2>&1 && eval "\$(zoxide init zsh)"
EOF
    fi

    if [[ "$INSTALL_EZA" == true ]]; then
        local eza_short="--all --group-directories-first --classify=auto"
        local eza_long="--all --long --header --group --group-directories-first --classify=auto"
        local eza_tree="${eza_short} --tree --ignore-glob=.git"
        cat >> "$ZSHRC" <<EOF

# eza — drop-in ls, always showing hidden files (.env, .github, .gitignore…)
# real ls and tree are still there as 'command ls', '\\ls', /bin/ls, 'command tree'
if command -v eza >/dev/null 2>&1; then
    alias ls='eza ${eza_short}'
    alias l='eza ${eza_long}'
    alias ll='eza ${eza_long}'
    alias lsa='eza ${eza_long}'
    alias la='eza --all ${eza_long}'
    alias lt='eza ${eza_tree} --level=2'
    alias tree='eza ${eza_tree}'
fi
EOF
    fi

    # oh-my-zsh's docker plugin claims `dtop` for `docker top`; this block is
    # sourced after it, so dropping the alias here gives the binary its name back.
    if [[ "$INSTALL_DTOP" == true ]]; then
        cat >> "$ZSHRC" <<'EOF'

# dtop — the docker plugin aliases dtop to 'docker top', we want the real thing
unalias dtop 2>/dev/null || true
EOF
    fi

    printf '%s\n' "$BLOCK_END" >> "$ZSHRC"

    local wrote="path and bun"
    [[ "$INSTALL_ZOXIDE" == true ]] && wrote="$wrote, zoxide"
    [[ "$INSTALL_EZA" == true ]] && wrote="$wrote, eza"
    [[ "$INSTALL_DTOP" == true ]] && wrote="$wrote, dtop"
    ok "$wrote hooks written"
    [[ "$INSTALL_EZA" == true ]] && note "ls, l, ll, la, lsa, lt and tree are eza now; \\ls gets you coreutils back"
    return 0
}

set_default_shell() {
    step "login shell"
    local zsh_bin
    zsh_bin="$(command -v zsh || true)"
    if [[ -z "$zsh_bin" ]]; then
        warn "zsh not found — login shell unchanged"
        return 0
    fi

    grep -qxF "$zsh_bin" /etc/shells || printf '%s\n' "$zsh_bin" >> /etc/shells

    if chsh -s "$zsh_bin" root >/dev/null 2>&1 || usermod -s "$zsh_bin" root >/dev/null 2>&1; then
        ok "root now lands in $(getent passwd root 2>/dev/null | cut -d: -f7 || true)"
    else
        warn "could not change root's shell — run: chsh -s $zsh_bin root"
    fi
}

apt_tidy() {
    apt_get autoclean || true
    apt-get clean
    rm -f /root/install.sh /root/bun.zip
    if have_systemd; then
        journalctl --vacuum-time=3d || true
    fi
    return 0
}

cleanup() {
    step "tidying up"

    local removals bad
    removals="$(would_remove autoremove --purge)"
    if [[ -z "$removals" ]]; then
        skip "nothing orphaned"
    else
        bad="$(protected_hits "$removals")"
        if [[ -n "$bad" ]]; then
            warn "skipped autoremove — it wanted to take:$bad (check 'apt autoremove' yourself)"
        else
            run "removing orphaned packages" apt_get autoremove --purge || warn "autoremove failed"
        fi
    fi

    run "clearing apt caches and old journals" apt_tidy || true
}

row() {
    printf '    %s%-9s%s %s\n' "$C_GREY" "$1" "$C_RESET" "$2"
    journal "  $1 $2"
}

summary() {
    local zsh_v zoxide_v eza_v docker_v bun_v btop_v dtop_v host_now shell_now
    host_now="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
    shell_now="$(getent passwd root 2>/dev/null | cut -d: -f7 || true)"
    zsh_v="$(zsh --version 2>/dev/null | awk '{print $2}' || true)"
    zoxide_v="$(zoxide --version 2>/dev/null || /root/.local/bin/zoxide --version 2>/dev/null || true)"
    eza_v="$(eza_version)"
    [[ -n "$eza_v" ]] || eza_v="$(eza_version /usr/local/bin/eza)"
    docker_v="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)"
    bun_v="$(/root/.bun/bin/bun --version 2>/dev/null || true)"
    btop_v="$(btop_version)"
    [[ -n "$btop_v" ]] || btop_v="$(btop_version /usr/local/bin/btop)"
    dtop_v="$({ dtop --version 2>/dev/null || /root/.local/bin/dtop --version 2>/dev/null; } | awk 'NR==1 {print $NF; exit}' | strip_ansi || true)"

    printf '\n  %s%s%s\n' "$C_MINT" "$RULE" "$C_RESET"
    printf '  %s%s  all done%s\n' "$C_MINT" "$S_STAR" "$C_RESET"
    printf '  %s%s%s\n\n' "$C_MINT" "$RULE" "$C_RESET"

    row "host" "${host_now:-—}"
    row "shell" "${shell_now:-—}"
    row "zsh" "${zsh_v:-—}"
    row "zoxide" "${zoxide_v:-—}"
    row "eza" "${eza_v:-—}"
    row "docker" "${docker_v:-—}"
    row "bun" "${bun_v:-—}"
    row "btop" "${btop_v:-—}"
    row "dtop" "${dtop_v:-—}"

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        local w
        printf '\n  %s%s %d thing(s) want a look%s\n' "$C_PEACH" "$S_WARN" "${#WARNINGS[@]}" "$C_RESET"
        for w in "${WARNINGS[@]}"; do
            printf '    %s%s %s%s\n' "$C_DIM" "$S_SKIP" "$w" "$C_RESET"
        done
    fi

    printf '\n  %s%s%s  %sexec zsh%s to jump in\n' "$C_PINK" "$S_STAR" "$C_RESET" "$C_B" "$C_RESET"
    if [[ -f /var/run/reboot-required ]]; then
        printf '  %s%s%s  reboot required to finish the upgrade\n' "$C_PEACH" "$S_WARN" "$C_RESET"
    else
        printf '  %s%s%s  a reboot is a good idea after a full upgrade\n' "$C_DIM" "$S_SKIP" "$C_RESET"
    fi
    printf '  %s%s  log: %s%s\n\n' "$C_DIM" "$S_SKIP" "$LOG" "$C_RESET"
    return 0
}

main() {
    [[ $# -eq 0 ]] || die "this script takes no arguments — it asks what to do when you run it"
    detect_distro

    banner
    gather_answers

    LOG="/var/log/vps-setup-$(date +%F-%H%M%S).log"
    journal "vps-setup $(date -Is) on $DISTRO_NAME"

    set_hostname
    update_system
    debloat
    install_omz
    install_zoxide
    install_eza
    install_docker
    install_bun
    install_btop
    install_dtop
    write_zshrc_block
    set_default_shell
    cleanup
    summary
}

main "$@"
