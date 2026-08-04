#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly PROJECT_DIR="/etc/cy502"
readonly STATE_FILE="$PROJECT_DIR/hardening.conf"
readonly LOG_DIR="/var/log/cy502-hardening"
readonly SYSCTL_FILE="/etc/sysctl.d/99-hardening.conf"
readonly NFTABLES_FILE="/etc/nftables.conf"
readonly AUDIT_RULES_FILE="/etc/audit/rules.d/99-cy502-hardening.rules"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/20-cy502-hardening.conf"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.local"
readonly SNAPPER_CONFIG="/etc/snapper/configs/root"

readonly AIDE_VERSION="0.19.3"
readonly AIDE_RELEASE="1"
readonly AIDE_B2SUM="5d52019b3690c8590678d408209619e1b257f84e66f2f5074a198e14ab78777de963a37ff7c26f505f278a313747947a101f9ac13d391417e91f6418f84adbe3"
readonly AIDE_SIGNING_KEY="2BBBD30FAAB29B3253BCFBA6F6947DAB68E7B931"
readonly AIDE_BUILD_USER="cy502_aide_build"
readonly AIDE_BUILD_HOME="/var/tmp/cy502-aide-build"

LOG_FILE=""
EVIDENCE_DIR=""
PRIMARY_USER=""
PRIMARY_HOME=""
PRIMARY_GROUP=""
SSH_ENABLED=0
SSH_KEY_FILE=""
AIDE_BUILD_USER_CREATED=0

usage() {
    cat <<'EOF'
Uso:
  sudo bash 02-hardening.sh
  sudo bash 02-hardening.sh --help

Requisitos:
  - Ejecutar desde el Arch Linux ya instalado, no desde la ISO.
  - Sistema instalado con Btrfs y /.snapshots, segun 01-instalacion.sh.
  - Conexion a Internet y /boot montado.
  - Al menos un usuario normal existente.

SSH queda desactivado por defecto. Si se decide habilitarlo, el script solicita
una llave publica o valida las llaves existentes del usuario seleccionado.

AIDE 0.19.3 se compila desde su version estable oficial porque actualmente no
forma parte de los repositorios binarios oficiales de Arch. La descarga se
verifica mediante BLAKE2 y la firma OpenPGP del desarrollador.
EOF
}

info() {
    printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[ADVERTENCIA]\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "No se encontro el comando requerido: $1"
}

cleanup_aide_builder() {
    set +e

    if (( AIDE_BUILD_USER_CREATED == 1 )); then
        if userdel --remove "$AIDE_BUILD_USER" >/dev/null 2>&1; then
            AIDE_BUILD_USER_CREATED=0
        else
            warn "No se pudo eliminar el usuario temporal $AIDE_BUILD_USER. Reviselo manualmente."
        fi
    fi

    set -e
}

on_error() {
    local exit_code="$1"
    local line_number="$2"

    trap - ERR INT TERM
    printf '\n\033[1;31m[ERROR]\033[0m Fallo en la linea %s (codigo %s).\n' \
        "$line_number" "$exit_code" >&2
    cleanup_aide_builder
    [[ -n "$LOG_FILE" ]] && printf 'Revise el registro: %s\n' "$LOG_FILE" >&2
    exit "$exit_code"
}

on_signal() {
    trap - ERR INT TERM
    printf '\n\033[1;31m[ERROR]\033[0m Hardening interrumpido.\n' >&2
    cleanup_aide_builder
    [[ -n "$LOG_FILE" ]] && printf 'Revise el registro: %s\n' "$LOG_FILE" >&2
    exit 130
}

validate_username() {
    local value="$1"
    [[ ${#value} -le 32 ]] || return 1
    [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

set_assignment() {
    local file="$1"
    local key="$2"
    local value="$3"

    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}=.*|${key}=\"${value}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$file"
    fi
}

start_logging() {
    local timestamp=""

    timestamp="$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "$LOG_DIR"
    LOG_FILE="$LOG_DIR/hardening-$timestamp.log"
    EVIDENCE_DIR="$LOG_DIR/evidencias-$timestamp"
    : > "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    install -d -m 0700 "$EVIDENCE_DIR"

    exec > >(tee -a "$LOG_FILE") 2>&1
}

check_environment() {
    local root_fstype=""
    local required_commands=(
        awk chmod chown date find findmnt getent grep hostnamectl id install
        mountpoint pacman passwd readlink sed systemctl tee timedatectl useradd
        userdel usermod
    )
    local command_name=""

    info "Comprobando el sistema instalado"

    (( EUID == 0 )) || die "Debe ejecutar este script como root mediante sudo."
    [[ -f /etc/arch-release ]] || die "Este sistema no parece ser Arch Linux."
    [[ -d /run/systemd/system ]] || die "El sistema no fue iniciado con systemd."
    [[ "$(uname -m)" == "x86_64" ]] || die "Este script fue preparado para Arch Linux x86_64."

    for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
    done

    root_fstype="$(findmnt -n -o FSTYPE /)"
    [[ "$root_fstype" == "btrfs" ]] || \
        die "La raiz debe utilizar Btrfs para configurar los snapshots del proyecto."

    mountpoint -q /boot || die "/boot no esta montado. Montelo antes de continuar."
    [[ -d /.snapshots ]] || die "No existe /.snapshots. Ejecute primero 01-instalacion.sh."

    timedatectl set-ntp true
    install -d -m 0755 "$PROJECT_DIR"

    ok "Arch Linux, systemd, Btrfs, /boot y el reloj fueron verificados."
}

collect_primary_user() {
    local -a candidates=()
    local candidate=""
    local default_user=""
    local entered_user=""
    local uid_value=""

    info "Seleccionando el usuario administrativo"

    mapfile -t candidates < <(
        awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd
    )
    (( ${#candidates[@]} > 0 )) || die "No se encontro ningun usuario normal."

    for candidate in "${candidates[@]}"; do
        if id -nG "$candidate" | tr ' ' '\n' | grep -qx wheel; then
            default_user="$candidate"
            break
        fi
    done
    [[ -n "$default_user" ]] || default_user="${candidates[0]}"

    printf 'Usuarios normales detectados:\n'
    printf '  %s\n' "${candidates[@]}"
    read -r -p "Usuario principal [$default_user]: " entered_user
    PRIMARY_USER="${entered_user:-$default_user}"

    validate_username "$PRIMARY_USER" || die "Nombre de usuario invalido: $PRIMARY_USER"
    id "$PRIMARY_USER" >/dev/null 2>&1 || die "El usuario $PRIMARY_USER no existe."

    uid_value="$(id -u "$PRIMARY_USER")"
    (( uid_value >= 1000 && uid_value < 60000 )) || \
        die "$PRIMARY_USER no corresponde a una cuenta normal."

    PRIMARY_HOME="$(getent passwd "$PRIMARY_USER" | awk -F: '{print $6}')"
    [[ -n "$PRIMARY_HOME" && -d "$PRIMARY_HOME" ]] || \
        die "No se encontro el directorio personal de $PRIMARY_USER."
    PRIMARY_GROUP="$(id -gn "$PRIMARY_USER")"

    ok "Usuario seleccionado: $PRIMARY_USER"
}

update_and_install_packages() {
    local -a packages=(
        acl
        arch-audit
        audit
        base-devel
        clamav
        curl
        e2fsprogs
        fail2ban
        gnupg
        libelf
        mhash
        nftables
        openssh
        pcre
        snap-pac
        snapper
    )
    local audit_status=0

    info "Actualizando Arch Linux e instalando herramientas de seguridad"

    pacman -Syu --needed --noconfirm "${packages[@]}"

    require_command arch-audit
    require_command auditctl
    require_command augenrules
    require_command clamscan
    require_command curl
    require_command fail2ban-client
    require_command freshclam
    require_command gpg
    require_command makepkg
    require_command nft
    require_command runuser
    require_command snapper
    require_command ssh-keygen
    require_command sshd
    require_command sudo
    require_command sysctl
    require_command visudo

    printf '\nRevision de vulnerabilidades conocidas:\n'
    set +e
    arch-audit
    audit_status=$?
    set -e

    case "$audit_status" in
        0)
            ok "arch-audit no reporto vulnerabilidades conocidas."
            ;;
        1)
            warn "arch-audit encontro paquetes afectados. El resultado quedo en el registro."
            ;;
        *)
            warn "arch-audit termino con codigo $audit_status. Revise conectividad y salida."
            ;;
    esac

    ok "Sistema actualizado y herramientas instaladas."
}

configure_privileges() {
    info "Aplicando minimo privilegio y configuracion segura de sudo"

    usermod -aG wheel "$PRIMARY_USER"

    cat > /etc/sudoers.d/10-wheel <<'EOF'
# Administradores autorizados del proyecto CY-502.
Defaults use_pty
Defaults passwd_tries=3
Defaults timestamp_timeout=5
Defaults logfile="/var/log/sudo.log"
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 0440 /etc/sudoers.d/10-wheel

    touch /var/log/sudo.log
    chown root:root /var/log/sudo.log
    chmod 0600 /var/log/sudo.log

    cat > /etc/profile.d/99-cy502-umask.sh <<'EOF'
# Los archivos nuevos no son accesibles para otros usuarios por defecto.
umask 027
EOF
    chmod 0644 /etc/profile.d/99-cy502-umask.sh

    if grep -qE '^[[:space:]]*UMASK[[:space:]]+' /etc/login.defs; then
        sed -i -E 's/^[[:space:]]*UMASK[[:space:]]+.*/UMASK           027/' /etc/login.defs
    else
        printf '\nUMASK           027\n' >> /etc/login.defs
    fi

    chmod 0700 /root
    passwd -l root >/dev/null
    visudo -cf /etc/sudoers
    [[ "$(passwd -S root | awk '{print $2}')" == "L" ]] || die "No se pudo bloquear la cuenta root."

    ok "Cuenta root bloqueada y administracion limitada al grupo wheel mediante sudo."
}

configure_journald() {
    info "Activando registros persistentes de systemd-journald"

    install -d -m 0755 /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/10-cy502-persistent.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
Seal=yes
SystemMaxUse=500M
RuntimeMaxUse=100M
MaxRetentionSec=1month
ForwardToSyslog=no
EOF

    install -d -m 2755 -o root -g systemd-journal /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald.service
    journalctl --flush

    [[ -d /var/log/journal ]] || die "No se creo el almacenamiento persistente del journal."
    ok "El journal persistira despues de los reinicios."
}

configure_sysctl() {
    info "Endureciendo parametros del kernel y de red"

    cat > "$SYSCTL_FILE" <<'EOF'
# CY-502 - reduccion de exposicion del kernel
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.randomize_va_space = 2
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# CY-502 - proteccion IPv4
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1

# CY-502 - proteccion IPv6 sin deshabilitar su conectividad
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF

    chmod 0644 "$SYSCTL_FILE"
    sysctl --system

    [[ "$(sysctl -n kernel.dmesg_restrict)" == "1" ]] || die "Fallo kernel.dmesg_restrict."
    [[ "$(sysctl -n net.ipv4.conf.all.accept_redirects)" == "0" ]] || \
        die "Fallo el bloqueo de redirecciones IPv4."

    ok "Parametros de kernel y red aplicados."
}

collect_ssh_configuration() {
    local answer=""
    local existing_keys=0
    local key_hint=""
    local authorized_keys="$PRIMARY_HOME/.ssh/authorized_keys"

    info "Definiendo la politica de acceso remoto"

    read -r -p "¿Habilitar SSH con autenticacion exclusiva por llave? [s/N]: " answer
    case "${answer,,}" in
        s | si | y | yes)
            SSH_ENABLED=1
            ;;
        "" | n | no)
            SSH_ENABLED=0
            ok "SSH permanecera desactivado."
            return
            ;;
        *)
            die "Respuesta invalida para la configuracion de SSH."
            ;;
    esac

    if [[ -s "$authorized_keys" ]] && ssh-keygen -l -f "$authorized_keys" >/dev/null 2>&1; then
        existing_keys=1
        key_hint=" (Enter conserva las existentes)"
        printf 'Se encontraron llaves validas en %s.\n' "$authorized_keys"
    fi

    read -r -p "Ruta de una llave publica${key_hint}: " SSH_KEY_FILE

    if [[ -z "$SSH_KEY_FILE" ]]; then
        (( existing_keys == 1 )) || die "SSH no se habilitara sin una llave publica valida."
        return
    fi

    SSH_KEY_FILE="$(readlink -f -- "$SSH_KEY_FILE")"
    [[ -f "$SSH_KEY_FILE" && -r "$SSH_KEY_FILE" ]] || \
        die "No se puede leer la llave publica: $SSH_KEY_FILE"
    ssh-keygen -l -f "$SSH_KEY_FILE" >/dev/null 2>&1 || \
        die "$SSH_KEY_FILE no contiene una llave publica SSH valida."
}

install_authorized_key() {
    local ssh_dir="$PRIMARY_HOME/.ssh"
    local authorized_keys="$ssh_dir/authorized_keys"
    local key_line=""

    (( SSH_ENABLED == 1 )) || return

    install -d -m 0700 -o "$PRIMARY_USER" -g "$PRIMARY_GROUP" "$ssh_dir"
    touch "$authorized_keys"
    chown "$PRIMARY_USER:$PRIMARY_GROUP" "$authorized_keys"
    chmod 0600 "$authorized_keys"

    if [[ -n "$SSH_KEY_FILE" ]]; then
        while IFS= read -r key_line || [[ -n "$key_line" ]]; do
            [[ -n "$key_line" ]] || continue
            [[ "$key_line" =~ ^[[:space:]]*# ]] && continue
            grep -qxF -- "$key_line" "$authorized_keys" || printf '%s\n' "$key_line" >> "$authorized_keys"
        done < "$SSH_KEY_FILE"
    fi

    ssh-keygen -l -f "$authorized_keys" || die "No quedo ninguna llave valida en authorized_keys."
    chown "$PRIMARY_USER:$PRIMARY_GROUP" "$authorized_keys"
    chmod 0600 "$authorized_keys"
}

configure_ssh() {
    info "Endureciendo OpenSSH"

    install_authorized_key
    install -d -m 0755 /etc/ssh/sshd_config.d
    cat > "$SSH_DROPIN" <<EOF
# CY-502 - acceso remoto restringido
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
UsePAM yes
StrictModes yes
LogLevel VERBOSE
MaxAuthTries 3
LoginGraceTime 30
MaxSessions 2
MaxStartups 10:30:30
ClientAliveInterval 300
ClientAliveCountMax 2
DisableForwarding yes
PermitUserEnvironment no
AllowUsers $PRIMARY_USER
EOF
    chmod 0600 "$SSH_DROPIN"

    ssh-keygen -A
    sshd -t

    if (( SSH_ENABLED == 1 )); then
        systemctl enable --now sshd.service
        systemctl restart sshd.service
        ok "SSH activo: solo $PRIMARY_USER puede autenticarse mediante llave publica."
    else
        systemctl disable --now sshd.service >/dev/null 2>&1 || true
        systemctl is-active --quiet sshd.service && die "sshd sigue activo pese a la politica seleccionada."
        ok "OpenSSH quedo configurado y su servicio permanece inactivo."
    fi
}

configure_nftables() {
    info "Configurando nftables con entrada denegada por defecto"

    {
        cat <<'EOF'
#!/usr/bin/nft -f

flush ruleset

table inet cy502_filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state invalid drop
        ct state established,related accept
        iifname "lo" accept

        # ICMP e ICMPv6 son necesarios para diagnostico y funcionamiento IPv6.
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        # Respuestas DHCP para interfaces administradas por NetworkManager.
        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept
EOF

        if (( SSH_ENABLED == 1 )); then
            cat <<'EOF'

        # Acceso SSH habilitado expresamente por el administrador.
        tcp dport 22 ct state new accept
EOF
        fi

        cat <<'EOF'

        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
    } > "$NFTABLES_FILE"

    chmod 0600 "$NFTABLES_FILE"
    nft --check --file "$NFTABLES_FILE"
    systemctl enable nftables.service
    systemctl restart nftables.service
    nft list table inet cy502_filter >/dev/null

    ok "Firewall activo: entrada y reenvio denegados por defecto."
}

configure_fail2ban() {
    info "Configurando proteccion contra intentos repetidos"

    install -d -m 0755 /etc/fail2ban/jail.d

    if (( SSH_ENABLED == 1 )); then
        cat > "$FAIL2BAN_JAIL" <<'EOF'
[sshd]
enabled = true
backend = systemd
port = ssh
filter = sshd
banaction = nftables-multiport
maxretry = 5
findtime = 10m
bantime = 1h
EOF
        chmod 0644 "$FAIL2BAN_JAIL"
        install -d -m 0755 /etc/systemd/system/fail2ban.service.d
        cat > /etc/systemd/system/fail2ban.service.d/10-cy502-ordering.conf <<'EOF'
[Unit]
Wants=nftables.service
After=nftables.service sshd.service
EOF
        systemctl daemon-reload
        fail2ban-client --test
        systemctl enable --now fail2ban.service
        systemctl restart fail2ban.service
        fail2ban-client status sshd
        ok "Fail2ban activo para SSH mediante nftables."
    else
        cat > "$FAIL2BAN_JAIL" <<'EOF'
[sshd]
enabled = false
EOF
        chmod 0644 "$FAIL2BAN_JAIL"
        systemctl disable --now fail2ban.service >/dev/null 2>&1 || true
        ok "Fail2ban instalado pero inactivo porque no existe acceso remoto expuesto."
    fi
}

set_boot_parameter() {
    local file="$1"
    local key="$2"
    local value="$3"
    local option="$key=$value"

    grep -qE '^options[[:space:]]+' "$file" || return

    if grep -qE "^options.*(^|[[:space:]])${key}=[^[:space:]]+" "$file"; then
        sed -i -E "/^options[[:space:]]+/s/(^|[[:space:]])${key}=[^[:space:]]+/\\1${option}/" "$file"
    else
        sed -i -E "/^options[[:space:]]+/ s|$| ${option}|" "$file"
    fi
}

configure_auditd() {
    local boot_entry=""
    local executable=""

    info "Configurando auditoria de archivos y acciones privilegiadas"

    shopt -s nullglob
    for boot_entry in /boot/loader/entries/*.conf; do
        set_boot_parameter "$boot_entry" audit 1
        set_boot_parameter "$boot_entry" audit_backlog_limit 8192
        chmod 0600 "$boot_entry"
    done
    shopt -u nullglob

    cat > "$AUDIT_RULES_FILE" <<'EOF'
# CY-502 - capacidad y comportamiento ante errores
-b 8192
--backlog_wait_time 60000
-f 1

# Identidades, credenciales y privilegios
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k privilege_scope
-w /etc/sudoers.d -p wa -k privilege_scope

# Configuraciones criticas del proyecto
-w /etc/ssh -p wa -k ssh_config
-w /etc/nftables.conf -p wa -k firewall_config
-w /etc/audit -p wa -k audit_config
-w /etc/sysctl.d -p wa -k kernel_config
-w /etc/systemd/journald.conf.d -p wa -k logging_config
-w /etc/snapper -p wa -k snapshot_config
-w /boot/loader -p wa -k boot_config
EOF

    for executable in /usr/bin/sudo /usr/bin/su /usr/bin/pkexec; do
        if [[ -x "$executable" ]]; then
            printf -- '-w %s -p x -k privileged_command\n' "$executable" >> "$AUDIT_RULES_FILE"
        fi
    done

    chmod 0640 "$AUDIT_RULES_FILE"
    systemctl enable --now auditd.service
    augenrules --load
    auditctl -s
    auditctl -l >/dev/null

    ok "Auditd monitorea identidades, sudo, SSH, firewall, kernel y arranque."
}

configure_clamav() {
    local database_count=0

    info "Configurando ClamAV y actualizacion automatica de firmas"

    [[ -f /etc/clamav/freshclam.conf ]] || die "No existe /etc/clamav/freshclam.conf."
    sed -i -E 's/^[[:space:]]*Example[[:space:]]*$/#Example/' /etc/clamav/freshclam.conf

    install -d -m 0750 -o clamav -g clamav /var/log/clamav
    systemctl stop clamav-freshclam.service >/dev/null 2>&1 || true

    if ! freshclam --stdout; then
        warn "freshclam no pudo actualizarse en este intento; se verificara si ya existen firmas."
    fi

    database_count="$(find /var/lib/clamav -maxdepth 1 -type f \( -name '*.cvd' -o -name '*.cld' \) | wc -l)"
    (( database_count > 0 )) || \
        die "ClamAV no dispone de firmas. Revise Internet y ejecute nuevamente el script."

    cat > /etc/systemd/system/cy502-clamav-scan.service <<'EOF'
[Unit]
Description=CY-502 - analisis antimalware semanal de /home
After=local-fs.target clamav-freshclam.service

[Service]
Type=oneshot
ExecStart=/usr/bin/clamscan --recursive=yes --infected --log=/var/log/clamav/cy502-weekly.log /home
Nice=10
IOSchedulingClass=idle
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log/clamav
NoNewPrivileges=yes
EOF

    cat > /etc/systemd/system/cy502-clamav-scan.timer <<'EOF'
[Unit]
Description=CY-502 - programacion de analisis antimalware

[Timer]
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=30m
Persistent=true
Unit=cy502-clamav-scan.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now clamav-freshclam.service
    systemctl enable --now cy502-clamav-scan.timer
    clamscan --infected /etc/hosts

    ok "Firmas de ClamAV disponibles y analisis semanal programado."
}

configure_snapper() {
    info "Configurando snapshots Btrfs con Snapper"

    install -d -m 0755 /etc/snapper/configs
    [[ -f /usr/share/snapper/config-templates/default ]] || \
        die "No se encontro la plantilla predeterminada de Snapper."

    cp /usr/share/snapper/config-templates/default "$SNAPPER_CONFIG"
    set_assignment "$SNAPPER_CONFIG" SUBVOLUME "/"
    set_assignment "$SNAPPER_CONFIG" FSTYPE "btrfs"
    set_assignment "$SNAPPER_CONFIG" ALLOW_USERS ""
    set_assignment "$SNAPPER_CONFIG" ALLOW_GROUPS ""
    set_assignment "$SNAPPER_CONFIG" SYNC_ACL "no"
    set_assignment "$SNAPPER_CONFIG" NUMBER_CLEANUP "yes"
    set_assignment "$SNAPPER_CONFIG" NUMBER_MIN_AGE "1800"
    set_assignment "$SNAPPER_CONFIG" NUMBER_LIMIT "10"
    set_assignment "$SNAPPER_CONFIG" NUMBER_LIMIT_IMPORTANT "5"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_CREATE "yes"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_CLEANUP "yes"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_MIN_AGE "1800"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_LIMIT_HOURLY "6"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_LIMIT_DAILY "7"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_LIMIT_WEEKLY "4"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_LIMIT_MONTHLY "3"
    set_assignment "$SNAPPER_CONFIG" TIMELINE_LIMIT_YEARLY "0"
    set_assignment "$SNAPPER_CONFIG" EMPTY_PRE_POST_CLEANUP "yes"
    set_assignment "$SNAPPER_CONFIG" EMPTY_PRE_POST_MIN_AGE "1800"
    chmod 0640 "$SNAPPER_CONFIG"

    install -d -m 0755 /etc/conf.d
    if [[ -f /etc/conf.d/snapper ]]; then
        set_assignment /etc/conf.d/snapper SNAPPER_CONFIGS "root"
    else
        printf 'SNAPPER_CONFIGS="root"\n' > /etc/conf.d/snapper
    fi
    chmod 0644 /etc/conf.d/snapper

    chmod 0750 /.snapshots
    snapper -c root list >/dev/null
    systemctl enable --now snapper-timeline.timer
    systemctl enable --now snapper-cleanup.timer

    ok "Snapper administrara el subvolumen raiz y conservara snapshots limitados."
}

install_aide_from_source() {
    local key_url=""
    local imported_fingerprints=""
    local package_path=""

    command -v aide >/dev/null 2>&1 && return

    info "Compilando AIDE $AIDE_VERSION desde su publicacion estable verificada"

    getent passwd "$AIDE_BUILD_USER" >/dev/null 2>&1 && \
        die "Ya existe el usuario temporal $AIDE_BUILD_USER. Eliminelo tras verificar su origen."
    [[ ! -e "$AIDE_BUILD_HOME" ]] || \
        die "Ya existe $AIDE_BUILD_HOME. Reviselo antes de volver a ejecutar el script."

    useradd --create-home --user-group --home-dir "$AIDE_BUILD_HOME" \
        --shell /usr/bin/nologin "$AIDE_BUILD_USER"
    AIDE_BUILD_USER_CREATED=1
    chmod 0700 "$AIDE_BUILD_HOME"

    cat > "$AIDE_BUILD_HOME/PKGBUILD" <<EOF
pkgname=aide
pkgver=$AIDE_VERSION
pkgrel=$AIDE_RELEASE
pkgdesc="A file and directory integrity checker"
arch=(x86_64)
url="https://aide.github.io/"
license=(GPL-2.0-only)
depends=(acl e2fsprogs libelf mhash pcre)
source=(
  "https://github.com/aide/aide/releases/download/v\${pkgver}/aide-\${pkgver}.tar.gz"
  "https://github.com/aide/aide/releases/download/v\${pkgver}/aide-\${pkgver}.tar.gz.asc"
)
b2sums=(
  '$AIDE_B2SUM'
  'SKIP'
)
validpgpkeys=('$AIDE_SIGNING_KEY')

build() {
  cd "aide-\${pkgver}"
  ./configure \\
    --prefix=/usr \\
    --sysconfdir=/etc \\
    --with-posix-acl \\
    --with-xattr \\
    --with-zlib \\
    --with-e2fsattrs \\
    --with-curl \\
    --disable-static
  make
}

package() {
  cd "aide-\${pkgver}"
  make DESTDIR="\${pkgdir}" install
  install -d -m 0700 "\${pkgdir}/var/lib/aide"
  install -d -m 0700 "\${pkgdir}/var/log/aide"
}
EOF

    install -d -m 0700 -o "$AIDE_BUILD_USER" -g "$AIDE_BUILD_USER" \
        "$AIDE_BUILD_HOME/gnupg"
    chown "$AIDE_BUILD_USER:$AIDE_BUILD_USER" "$AIDE_BUILD_HOME/PKGBUILD"

    key_url="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$AIDE_SIGNING_KEY"
    runuser -u "$AIDE_BUILD_USER" -- env \
        HOME="$AIDE_BUILD_HOME" GNUPGHOME="$AIDE_BUILD_HOME/gnupg" \
        curl --fail --silent --show-error --location \
        --output "$AIDE_BUILD_HOME/aide-signing-key.asc" "$key_url"

    runuser -u "$AIDE_BUILD_USER" -- env \
        HOME="$AIDE_BUILD_HOME" GNUPGHOME="$AIDE_BUILD_HOME/gnupg" \
        gpg --batch --import "$AIDE_BUILD_HOME/aide-signing-key.asc"

    imported_fingerprints="$(
        runuser -u "$AIDE_BUILD_USER" -- env \
            HOME="$AIDE_BUILD_HOME" GNUPGHOME="$AIDE_BUILD_HOME/gnupg" \
            gpg --batch --with-colons --fingerprint "$AIDE_SIGNING_KEY" |
            awk -F: '$1 == "fpr" {print $10}'
    )"
    grep -qx "$AIDE_SIGNING_KEY" <<< "$imported_fingerprints" || \
        die "La huella de la llave de AIDE no coincide con la esperada."

    (
        cd "$AIDE_BUILD_HOME"
        runuser -u "$AIDE_BUILD_USER" -- env \
            HOME="$AIDE_BUILD_HOME" GNUPGHOME="$AIDE_BUILD_HOME/gnupg" \
            makepkg --cleanbuild --clean --force --noconfirm
    )

    package_path="$(
        cd "$AIDE_BUILD_HOME"
        runuser -u "$AIDE_BUILD_USER" -- env HOME="$AIDE_BUILD_HOME" \
            makepkg --packagelist | head -n 1
    )"
    [[ -f "$package_path" ]] || die "No se encontro el paquete compilado de AIDE."

    pacman -U --noconfirm "$package_path"
    pacman -Q aide
    cleanup_aide_builder

    ok "AIDE fue compilado, verificado e instalado mediante pacman."
}

configure_aide() {
    local database="/var/lib/aide/aide.db.gz"
    local new_database="/var/lib/aide/aide.db.new.gz"
    local checksum_file="/var/lib/aide/aide.db.gz.sha256"
    local check_status=0

    info "Creando la linea base de integridad con AIDE"

    install_aide_from_source
    install -d -m 0700 -o root -g root /var/lib/aide /var/log/aide

    cat > /etc/aide.conf <<'EOF'
@@define DBDIR /var/lib/aide
@@define LOGDIR /var/log/aide

database_in=file:@@{DBDIR}/aide.db.gz
database_out=file:@@{DBDIR}/aide.db.new.gz
gzip_dbout=yes

log_level=warning
report_level=changed_attributes
report_url=file:@@{LOGDIR}/aide.log
report_url=stdout

NORMAL = p+i+l+n+u+g+s+m+c+acl+xattrs+sha256
FAT = p+i+l+n+u+g+s+m+c+sha256

# Archivos volatiles o ajenos al alcance de la linea base.
!/var/log/.*
!/var/cache/.*
!/var/tmp/.*
!/tmp/.*
!/run/.*
!/proc/.*
!/sys/.*
!/dev/.*
!/home/.*
!/root/.*
!/.snapshots/.*
!/etc/cy502/hardening.conf

# Configuraciones, ejecutables, bibliotecas y archivos de arranque.
/etc NORMAL
/usr/bin NORMAL
/usr/lib NORMAL
/boot FAT
EOF
    chmod 0600 /etc/aide.conf
    aide --config-check

    cat > /etc/systemd/system/cy502-aide-check.service <<'EOF'
[Unit]
Description=CY-502 - verificacion de integridad con AIDE
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/aide --check
Nice=10
IOSchedulingClass=idle
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log/aide
NoNewPrivileges=yes
EOF

    cat > /etc/systemd/system/cy502-aide-check.timer <<'EOF'
[Unit]
Description=CY-502 - programacion diaria de AIDE

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
Unit=cy502-aide-check.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now cy502-aide-check.timer

    if [[ -s "$database" ]]; then
        warn "Ya existe una linea base de AIDE; no se reemplazara automaticamente."
        if [[ -s "$checksum_file" ]]; then
            (cd /var/lib/aide && sha256sum --check "$(basename "$checksum_file")") || \
                die "La base existente de AIDE no coincide con su suma registrada."
        else
            (cd /var/lib/aide && sha256sum "$(basename "$database")" > "$(basename "$checksum_file")")
        fi
    else
        if [[ -e "$new_database" ]]; then
            mv -- "$new_database" "${new_database}.previous-$(date +%Y%m%d-%H%M%S)"
            warn "Se conservo una base incompleta anterior antes de inicializar AIDE."
        fi
        warn "La inicializacion de AIDE puede tardar varios minutos y no muestra progreso continuo."
        aide --init
        [[ -s "$new_database" ]] || die "AIDE no genero la base de datos esperada."
        mv -- "$new_database" "$database"
        chmod 0600 "$database"
        (cd /var/lib/aide && sha256sum "$(basename "$database")" > "$(basename "$checksum_file")")
        chmod 0600 "$checksum_file"
    fi

    set +e
    aide --check --limit='/etc/(passwd|group|shadow|sudoers)'
    check_status=$?
    set -e
    if (( check_status != 0 )); then
        warn "La comprobacion limitada de AIDE reporto cambios o un error (codigo $check_status)."
    fi

    ok "Linea base de AIDE protegida y verificacion diaria programada."
}

unit_exists() {
    local unit="$1"
    systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -qE "^${unit}[[:space:]]"
}

review_services() {
    local -a unnecessary_units=(
        avahi-daemon.service
        avahi-daemon.socket
        bluetooth.service
        cups.service
        cups.socket
        httpd.service
        nginx.service
        nfs-server.service
        rpcbind.service
        rpcbind.socket
        smb.service
        telnet.socket
        tftp.service
        vsftpd.service
    )
    local unit=""

    info "Revisando y deshabilitando servicios no requeridos en el laboratorio"

    systemctl list-unit-files --state=enabled > "$EVIDENCE_DIR/servicios-habilitados-antes.txt"

    for unit in "${unnecessary_units[@]}"; do
        if unit_exists "$unit"; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || \
                warn "No se pudo deshabilitar $unit; reviselo manualmente."
        fi
    done

    systemctl list-unit-files --state=enabled > "$EVIDENCE_DIR/servicios-habilitados-despues.txt"
    ok "Se aplico una lista conservadora y el inventario restante quedo registrado."
}

create_initial_snapshot() {
    local snapshot_number=""

    info "Creando snapshot del sistema endurecido"

    if snapper -c root list | grep -Fq 'CY-502 - hardening inicial'; then
        warn "Ya existe el snapshot inicial de hardening; no se duplicara."
    else
        snapshot_number="$(
            snapper -c root create --type single --cleanup-algorithm number \
                --description 'CY-502 - hardening inicial' --print-number
        )"
        [[ "$snapshot_number" =~ ^[0-9]+$ ]] || die "Snapper no devolvio un numero valido."
        ok "Snapshot inicial creado con numero $snapshot_number."
    fi
}

write_project_state() {
    local ssh_value="disabled"

    (( SSH_ENABLED == 1 )) && ssh_value="key-only"

    {
        printf 'HARDENING_VERSION=%s\n' "$SCRIPT_VERSION"
        printf 'HARDENING_DATE=%s\n' "$(date --iso-8601=seconds)"
        printf 'PRIMARY_USER=%s\n' "$PRIMARY_USER"
        printf 'SSH_MODE=%s\n' "$ssh_value"
        printf 'AIDE_VERSION=%s\n' "$AIDE_VERSION"
        printf 'FIREWALL_TABLE=%s\n' "inet/cy502_filter"
        printf 'SNAPPER_CONFIG=%s\n' "root"
    } > "$STATE_FILE"
    chmod 0644 "$STATE_FILE"
}

generate_evidence() {
    local audit_status=0

    info "Generando evidencias tecnicas de la aplicacion"

    {
        printf 'PROYECTO CY-502 - RESUMEN DE HARDENING\n'
        printf 'Fecha: %s\n' "$(date --iso-8601=seconds)"
        printf 'Hostname: %s\n' "$(hostname)"
        printf 'Usuario principal: %s\n' "$PRIMARY_USER"
        printf 'Modo SSH: %s\n' "$([[ $SSH_ENABLED == 1 ]] && printf key-only || printf disabled)"
        printf '\n'
        hostnamectl
        printf '\nSistema operativo:\n'
        cat /etc/os-release
    } > "$EVIDENCE_DIR/00-resumen.txt"

    pacman -Q \
        aide arch-audit audit clamav fail2ban nftables openssh snap-pac snapper \
        > "$EVIDENCE_DIR/01-paquetes-seguridad.txt"

    set +e
    arch-audit > "$EVIDENCE_DIR/02-arch-audit.txt" 2>&1
    audit_status=$?
    printf 'exit_code=%s\n' "$audit_status" >> "$EVIDENCE_DIR/02-arch-audit.txt"
    set -e

    nft list ruleset > "$EVIDENCE_DIR/03-nftables.txt"

    {
        printf 'Estado de sshd:\n'
        systemctl is-enabled sshd.service 2>&1 || true
        systemctl is-active sshd.service 2>&1 || true
        printf '\nConfiguracion efectiva relevante:\n'
        sshd -T -C "user=$PRIMARY_USER,host=localhost,addr=127.0.0.1" |
            grep -E '^(permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods|maxauthtries|disableforwarding|allowusers) '
    } > "$EVIDENCE_DIR/04-ssh.txt"

    {
        printf 'Estado de journald:\n'
        systemctl is-active systemd-journald.service
        journalctl --disk-usage
        printf '\nDirectorio persistente:\n'
        ls -ld /var/log/journal
    } > "$EVIDENCE_DIR/05-journald.txt"

    {
        auditctl -s
        printf '\nReglas:\n'
        auditctl -l
    } > "$EVIDENCE_DIR/06-auditd.txt"

    {
        printf 'kernel.dmesg_restrict=%s\n' "$(sysctl -n kernel.dmesg_restrict)"
        printf 'kernel.kptr_restrict=%s\n' "$(sysctl -n kernel.kptr_restrict)"
        printf 'kernel.randomize_va_space=%s\n' "$(sysctl -n kernel.randomize_va_space)"
        printf 'kernel.yama.ptrace_scope=%s\n' "$(sysctl -n kernel.yama.ptrace_scope)"
        printf 'net.ipv4.conf.all.accept_redirects=%s\n' "$(sysctl -n net.ipv4.conf.all.accept_redirects)"
        printf 'net.ipv4.conf.all.accept_source_route=%s\n' "$(sysctl -n net.ipv4.conf.all.accept_source_route)"
        printf 'net.ipv4.conf.all.rp_filter=%s\n' "$(sysctl -n net.ipv4.conf.all.rp_filter)"
        printf 'net.ipv4.tcp_syncookies=%s\n' "$(sysctl -n net.ipv4.tcp_syncookies)"
        printf 'net.ipv6.conf.all.accept_redirects=%s\n' "$(sysctl -n net.ipv6.conf.all.accept_redirects)"
    } > "$EVIDENCE_DIR/07-sysctl.txt"

    {
        aide --version
        printf '\nBase de datos:\n'
        ls -l /var/lib/aide/aide.db.gz /var/lib/aide/aide.db.gz.sha256
        printf '\nTemporizador:\n'
        systemctl is-enabled cy502-aide-check.timer
        systemctl is-active cy502-aide-check.timer
    } > "$EVIDENCE_DIR/08-aide.txt"

    {
        clamscan --version
        printf '\nFirmas:\n'
        find /var/lib/clamav -maxdepth 1 -type f \( -name '*.cvd' -o -name '*.cld' \) -printf '%f\n'
        printf '\nServicios:\n'
        systemctl is-enabled clamav-freshclam.service
        systemctl is-enabled cy502-clamav-scan.timer
    } > "$EVIDENCE_DIR/09-clamav.txt"

    {
        if (( SSH_ENABLED == 1 )); then
            fail2ban-client status
            fail2ban-client status sshd
        else
            printf 'NO APLICA: SSH esta desactivado y no hay autenticacion remota expuesta.\n'
            systemctl is-enabled fail2ban.service 2>&1 || true
            systemctl is-active fail2ban.service 2>&1 || true
        fi
    } > "$EVIDENCE_DIR/10-fail2ban.txt"

    {
        btrfs subvolume list /
        printf '\nSnapshots administrados:\n'
        snapper -c root list
        printf '\nTemporizadores:\n'
        systemctl is-enabled snapper-timeline.timer
        systemctl is-enabled snapper-cleanup.timer
    } > "$EVIDENCE_DIR/11-snapper.txt"

    visudo -cf /etc/sudoers > "$EVIDENCE_DIR/12-sudo.txt" 2>&1
    id "$PRIMARY_USER" >> "$EVIDENCE_DIR/12-sudo.txt"
    sudo -l -U "$PRIMARY_USER" 2>&1 | tee -a "$EVIDENCE_DIR/12-sudo.txt" >/dev/null

    chmod -R go-rwx "$EVIDENCE_DIR"
    ok "Evidencias guardadas en $EVIDENCE_DIR"
}

verify_hardening() {
    info "Realizando comprobaciones finales"

    visudo -cf /etc/sudoers
    nft --check --file "$NFTABLES_FILE"
    systemctl is-active --quiet nftables.service
    systemctl is-active --quiet auditd.service
    systemctl is-active --quiet systemd-journald.service
    systemctl is-active --quiet clamav-freshclam.service
    systemctl is-active --quiet cy502-clamav-scan.timer
    systemctl is-active --quiet cy502-aide-check.timer
    systemctl is-active --quiet snapper-timeline.timer
    systemctl is-active --quiet snapper-cleanup.timer
    aide --config-check
    snapper -c root list >/dev/null

    if (( SSH_ENABLED == 1 )); then
        sshd -t
        systemctl is-active --quiet sshd.service
        systemctl is-active --quiet fail2ban.service
        fail2ban-client status sshd >/dev/null
    else
        ! systemctl is-active --quiet sshd.service || die "sshd no debia estar activo."
    fi

    ok "Los controles esenciales superaron la verificacion local."
}

finish_hardening() {
    install -d -m 0755 /var/lib/cy502
    cat > /var/lib/cy502/reboot-required <<'EOF'
Reinicio requerido para cargar audit=1 y audit_backlog_limit=8192 desde el arranque,
ademas de cualquier kernel actualizado durante la ejecucion de pacman.
EOF
    chmod 0644 /var/lib/cy502/reboot-required

    trap - ERR INT TERM

    printf '\n\033[1;32m============================================================\033[0m\n'
    printf '\033[1;32m HARDENING FINALIZADO CORRECTAMENTE\033[0m\n'
    printf '\033[1;32m============================================================\033[0m\n'
    printf 'Equipo:       %s\n' "$(hostname)"
    printf 'Usuario:      %s\n' "$PRIMARY_USER"
    printf 'SSH:          %s\n' "$([[ $SSH_ENABLED == 1 ]] && printf 'activo, solo llave' || printf 'desactivado')"
    printf 'Registro:     %s\n' "$LOG_FILE"
    printf 'Evidencias:   %s\n' "$EVIDENCE_DIR"
    printf '\nReinicie el sistema para completar la auditoria temprana del arranque:\n'
    printf '  sudo reboot\n'
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    (( $# == 0 )) || die "Argumento desconocido. Use --help."
    (( EUID == 0 )) || die "Debe ejecutar este script como root mediante sudo."

    start_logging
    trap 'on_error $? $LINENO' ERR
    trap 'on_signal' INT TERM

    printf '\033[1;36mArch Linux CY-502 - Hardening %s\033[0m\n' "$SCRIPT_VERSION"
    printf 'Fecha: %s\n' "$(date --iso-8601=seconds)"

    check_environment
    collect_primary_user
    update_and_install_packages
    configure_privileges
    configure_journald
    configure_sysctl
    collect_ssh_configuration
    configure_ssh
    configure_nftables
    configure_fail2ban
    configure_auditd
    configure_clamav
    configure_snapper
    review_services
    write_project_state
    configure_aide
    create_initial_snapshot
    verify_hardening
    generate_evidence
    finish_hardening
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
