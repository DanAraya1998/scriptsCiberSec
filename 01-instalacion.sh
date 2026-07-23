#!/usr/bin/env bash
# ==============================================================================
# 01-instalacion.sh
# Instalacion reproducible de Arch Linux para el proyecto CY-502.
#
# Objetivo:
#   - VM nueva de Oracle VirtualBox iniciada en modo UEFI.
#   - Disco GPT dedicado: EFI de 1 GiB sin cifrar + raiz cifrada con LUKS2.
#   - Btrfs: @, @home, @log y @snapshots.
#   - systemd-boot, ZRAM, NetworkManager y usuario administrativo con sudo.
#   - Entorno grafico XFCE con LightDM y utilidades de invitado de VirtualBox.
#
# ADVERTENCIA: el disco seleccionado se borra por completo.
# Ejecutar desde la ISO oficial de Arch Linux, como root y con Internet.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly TARGET_MOUNT="/mnt"
readonly CRYPT_NAME="cryptroot"
readonly BTRFS_OPTIONS="noatime,compress=zstd:3"
readonly TIMEZONE="America/Costa_Rica"
readonly SYSTEM_LOCALE="es_CR.UTF-8"
readonly FALLBACK_LOCALE="en_US.UTF-8"
readonly CONSOLE_KEYMAP="la-latin1"
readonly X11_KEYMAP="latam"
readonly DEFAULT_HOSTNAME="CY502-ARCH-GX"
readonly DEFAULT_USERNAME="cy502"
readonly MINIMUM_DISK_BYTES=$((25 * 1024 * 1024 * 1024))

LOG_FILE=""
DISK=""
EFI_PART=""
ROOT_PART=""
HOST_NAME=""
USER_NAME=""
MICROCODE_PACKAGE=""
MICROCODE_IMAGE=""
TARGET_MOUNTED=0
CRYPT_OPENED=0

usage() {
    cat <<'EOF'
Uso:
  bash 01-instalacion.sh
  bash 01-instalacion.sh --help

El script es interactivo. Antes de modificar el disco muestra los dispositivos
disponibles y exige confirmar literalmente el dispositivo elegido.

Requisitos:
  - ISO oficial vigente de Arch Linux.
  - Maquina VirtualBox nueva con UEFI habilitado.
  - Disco virtual dedicado de al menos 25 GiB (40 GiB recomendados).
  - Conexion a Internet.

Resultado:
  Arch Linux + LUKS2 + Btrfs + systemd-boot + ZRAM + XFCE + LightDM.
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

cleanup_best_effort() {
    set +e

    if (( TARGET_MOUNTED == 1 )); then
        umount -R "$TARGET_MOUNT" >/dev/null 2>&1
        TARGET_MOUNTED=0
    fi

    if (( CRYPT_OPENED == 1 )); then
        cryptsetup close "$CRYPT_NAME" >/dev/null 2>&1
        CRYPT_OPENED=0
    fi

    set -e
}

on_error() {
    local exit_code="$1"
    local line_number="$2"

    trap - ERR INT TERM
    printf '\n\033[1;31m[ERROR]\033[0m Fallo en la linea %s (codigo %s).\n' \
        "$line_number" "$exit_code" >&2
    cleanup_best_effort
    [[ -n "$LOG_FILE" ]] && printf 'Revise el registro: %s\n' "$LOG_FILE" >&2
    exit "$exit_code"
}

on_signal() {
    trap - ERR INT TERM
    printf '\n\033[1;31m[ERROR]\033[0m Instalacion interrumpida.\n' >&2
    cleanup_best_effort
    [[ -n "$LOG_FILE" ]] && printf 'Revise el registro: %s\n' "$LOG_FILE" >&2
    exit 130
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "No se encontro el comando requerido: $1"
}

partition_path() {
    local disk="$1"
    local number="$2"

    case "$disk" in
        /dev/nvme* | /dev/mmcblk* | /dev/loop*)
            printf '%sp%s' "$disk" "$number"
            ;;
        *)
            printf '%s%s' "$disk" "$number"
            ;;
    esac
}

validate_hostname() {
    local value="$1"
    [[ ${#value} -le 63 ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

validate_username() {
    local value="$1"
    [[ ${#value} -le 32 ]] || return 1
    [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

check_environment() {
    info "Comprobando el entorno de instalacion"

    (( EUID == 0 )) || die "Debe ejecutar este script como root."
    [[ -d /sys/firmware/efi/efivars ]] || \
        die "La ISO no fue iniciada en modo UEFI. Active EFI en VirtualBox y reinicie."

    local required_commands=(
        arch-chroot awk blockdev btrfs cryptsetup curl find findmnt genfstab
        loadkeys lsblk mkfs.btrfs mkfs.fat mount mountpoint pacman pacstrap
        readlink sed sfdisk tee timedatectl udevadm umount wipefs
    )
    local command_name
    for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
    done

    [[ ! -e "/dev/mapper/$CRYPT_NAME" ]] || \
        die "Ya existe /dev/mapper/$CRYPT_NAME. Cierre ese mapeo antes de continuar."
    ! mountpoint -q "$TARGET_MOUNT" || \
        die "$TARGET_MOUNT ya contiene un sistema montado. Desmontelo antes de continuar."

    if [[ -d "$TARGET_MOUNT" ]] && \
       [[ -n "$(find "$TARGET_MOUNT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        die "$TARGET_MOUNT no esta vacio. Revise su contenido antes de continuar."
    fi

    loadkeys "$CONSOLE_KEYMAP"
    timedatectl set-ntp true

    if ! curl --fail --silent --show-error --location \
        --connect-timeout 10 --output /dev/null https://archlinux.org/; then
        die "No fue posible acceder a Internet. Configure la red y vuelva a ejecutar el script."
    fi

    ok "UEFI, herramientas, teclado, hora y conectividad verificados."
}

collect_identity() {
    local input=""

    info "Datos del sistema"

    read -r -p "Nombre del equipo [$DEFAULT_HOSTNAME]: " input
    HOST_NAME="${input:-$DEFAULT_HOSTNAME}"
    validate_hostname "$HOST_NAME" || \
        die "Hostname invalido. Use letras, numeros y guiones; maximo 63 caracteres."

    input=""
    read -r -p "Usuario principal [$DEFAULT_USERNAME]: " input
    USER_NAME="${input:-$DEFAULT_USERNAME}"
    validate_username "$USER_NAME" || \
        die "Usuario invalido. Use minusculas, numeros, guion o guion bajo."

    printf '\nConfiguracion seleccionada:\n'
    printf '  Hostname:        %s\n' "$HOST_NAME"
    printf '  Usuario:         %s\n' "$USER_NAME"
    printf '  Zona horaria:    %s\n' "$TIMEZONE"
    printf '  Idioma:          %s\n' "$SYSTEM_LOCALE"
    printf '  Escritorio:      XFCE\n'
    printf '  Gestor de sesion: LightDM\n'
}

select_disk() {
    local entered_disk=""
    local disk_type=""
    local disk_size=""
    local -a active_mounts=()

    info "Discos detectados"
    lsblk -dpno NAME,SIZE,MODEL,TYPE

    printf '\nElija el DISCO COMPLETO, no una particion. Ejemplo: /dev/sda\n'
    read -r -p "Disco que se borrara: " entered_disk
    [[ -n "$entered_disk" ]] || die "No se indico ningun disco."

    DISK="$(readlink -f -- "$entered_disk")"
    [[ -b "$DISK" ]] || die "$entered_disk no es un dispositivo de bloques valido."

    disk_type="$(lsblk -dnro TYPE "$DISK")"
    [[ "$disk_type" == "disk" ]] || die "$DISK no corresponde a un disco completo."

    mapfile -t active_mounts < <(lsblk -nrpo MOUNTPOINT "$DISK" | awk 'NF {print}')
    if (( ${#active_mounts[@]} > 0 )); then
        printf 'Puntos de montaje detectados:\n' >&2
        printf '  %s\n' "${active_mounts[@]}" >&2
        die "El disco seleccionado esta en uso."
    fi

    disk_size="$(lsblk -bdnro SIZE "$DISK")"
    [[ "$disk_size" =~ ^[0-9]+$ ]] || die "No se pudo determinar el tamano de $DISK."
    (( disk_size >= MINIMUM_DISK_BYTES )) || \
        die "El disco debe tener al menos 25 GiB; se recomiendan 40 GiB."

    EFI_PART="$(partition_path "$DISK" 1)"
    ROOT_PART="$(partition_path "$DISK" 2)"

    printf '\n\033[1;31mSE BORRARA TODO EL CONTENIDO DE %s.\033[0m\n' "$DISK"
    lsblk -dpo NAME,SIZE,MODEL,SERIAL "$DISK"
    printf '\nPara autorizarlo, escriba exactamente: BORRAR %s\n' "$DISK"

    local confirmation=""
    read -r confirmation
    [[ "$confirmation" == "BORRAR $DISK" ]] || die "Confirmacion incorrecta. No se modifico el disco."

    ok "Disco confirmado: $DISK"
}

detect_microcode() {
    local cpu_vendor=""
    cpu_vendor="$(awk -F ': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo)"

    case "$cpu_vendor" in
        GenuineIntel)
            MICROCODE_PACKAGE="intel-ucode"
            MICROCODE_IMAGE="intel-ucode.img"
            ;;
        AuthenticAMD)
            MICROCODE_PACKAGE="amd-ucode"
            MICROCODE_IMAGE="amd-ucode.img"
            ;;
        *)
            warn "No se detecto microcodigo Intel o AMD; se continuara sin ese paquete."
            ;;
    esac
}

partition_and_encrypt() {
    info "Creando tabla GPT y particiones"

    wipefs --all --force "$DISK"
    sfdisk --wipe always "$DISK" <<'EOF'
label: gpt
size=1GiB, type=U
type=L
EOF

    blockdev --rereadpt "$DISK" || true
    udevadm settle --timeout=15

    [[ -b "$EFI_PART" ]] || die "No se creo la particion EFI esperada: $EFI_PART"
    [[ -b "$ROOT_PART" ]] || die "No se creo la particion raiz esperada: $ROOT_PART"

    mkfs.fat -F 32 -n EFI "$EFI_PART"

    printf '\nDefina ahora la frase de paso de LUKS2. No se mostrara ni se guardara.\n'
    printf 'Use una frase larga y unica; sera necesaria en cada arranque.\n\n'
    cryptsetup luksFormat --type luks2 --verify-passphrase --label CY502_LUKS "$ROOT_PART"
    cryptsetup open "$ROOT_PART" "$CRYPT_NAME"
    CRYPT_OPENED=1

    cryptsetup isLuks "$ROOT_PART"
    ok "Particion raiz protegida con LUKS2."
}

create_btrfs_layout() {
    local mapper="/dev/mapper/$CRYPT_NAME"

    info "Creando Btrfs y sus subvolumenes"

    mkfs.btrfs -f -L ArchRoot "$mapper"
    mkdir -p "$TARGET_MOUNT"
    mount "$mapper" "$TARGET_MOUNT"
    TARGET_MOUNTED=1

    btrfs subvolume create "$TARGET_MOUNT/@"
    btrfs subvolume create "$TARGET_MOUNT/@home"
    btrfs subvolume create "$TARGET_MOUNT/@log"
    btrfs subvolume create "$TARGET_MOUNT/@snapshots"

    umount "$TARGET_MOUNT"
    TARGET_MOUNTED=0

    mount -o "$BTRFS_OPTIONS,subvol=@" "$mapper" "$TARGET_MOUNT"
    TARGET_MOUNTED=1

    mkdir -p \
        "$TARGET_MOUNT/home" \
        "$TARGET_MOUNT/var/log" \
        "$TARGET_MOUNT/.snapshots" \
        "$TARGET_MOUNT/boot"

    mount -o "$BTRFS_OPTIONS,subvol=@home" "$mapper" "$TARGET_MOUNT/home"
    mount -o "$BTRFS_OPTIONS,subvol=@log" "$mapper" "$TARGET_MOUNT/var/log"
    mount -o "$BTRFS_OPTIONS,subvol=@snapshots" "$mapper" "$TARGET_MOUNT/.snapshots"
    mount -o umask=0077 "$EFI_PART" "$TARGET_MOUNT/boot"

    ok "Subvolumenes @, @home, @log y @snapshots montados."
}

install_packages() {
    local -a base_packages=(
        base
        linux
        linux-firmware
        btrfs-progs
        cryptsetup
        dosfstools
        efibootmgr
        networkmanager
        sudo
        zram-generator
        man-db
        man-pages
        nano
        bash-completion
    )

    local -a desktop_packages=(
        xorg-server
        xfce4
        lightdm
        lightdm-gtk-greeter
        accountsservice
        network-manager-applet
        gvfs
        udisks2
        mesa
        pipewire
        pipewire-alsa
        pipewire-pulse
        wireplumber
        pavucontrol
        xfce4-screensaver
        xdg-user-dirs
        ttf-dejavu
        virtualbox-guest-utils
    )

    detect_microcode
    [[ -n "$MICROCODE_PACKAGE" ]] && base_packages+=("$MICROCODE_PACKAGE")

    info "Actualizando el llavero de la ISO"
    pacman -Sy --noconfirm archlinux-keyring

    info "Instalando Arch Linux y el entorno grafico XFCE"
    pacstrap -K "$TARGET_MOUNT" "${base_packages[@]}" "${desktop_packages[@]}"

    genfstab -U "$TARGET_MOUNT" > "$TARGET_MOUNT/etc/fstab"
    [[ -s "$TARGET_MOUNT/etc/fstab" ]] || die "No se pudo generar /etc/fstab."

    ok "Sistema base y XFCE instalados."
}

configure_locale_and_identity() {
    info "Configurando idioma, teclado, hora e identidad"

    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET_MOUNT/etc/localtime"
    arch-chroot "$TARGET_MOUNT" hwclock --systohc

    sed -i -E 's/^#(es_CR\.UTF-8 UTF-8)$/\1/' "$TARGET_MOUNT/etc/locale.gen"
    sed -i -E 's/^#(en_US\.UTF-8 UTF-8)$/\1/' "$TARGET_MOUNT/etc/locale.gen"

    grep -q '^es_CR\.UTF-8 UTF-8$' "$TARGET_MOUNT/etc/locale.gen" || \
        printf '%s\n' 'es_CR.UTF-8 UTF-8' >> "$TARGET_MOUNT/etc/locale.gen"
    grep -q '^en_US\.UTF-8 UTF-8$' "$TARGET_MOUNT/etc/locale.gen" || \
        printf '%s\n' 'en_US.UTF-8 UTF-8' >> "$TARGET_MOUNT/etc/locale.gen"

    arch-chroot "$TARGET_MOUNT" locale-gen

    printf 'LANG=%s\n' "$SYSTEM_LOCALE" > "$TARGET_MOUNT/etc/locale.conf"
    printf 'KEYMAP=%s\n' "$CONSOLE_KEYMAP" > "$TARGET_MOUNT/etc/vconsole.conf"
    printf '%s\n' "$HOST_NAME" > "$TARGET_MOUNT/etc/hostname"

    cat > "$TARGET_MOUNT/etc/hosts" <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOST_NAME.localdomain $HOST_NAME
EOF

    install -d -m 0755 "$TARGET_MOUNT/etc/X11/xorg.conf.d"
    cat > "$TARGET_MOUNT/etc/X11/xorg.conf.d/00-keyboard.conf" <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$X11_KEYMAP"
EndSection
EOF
}

configure_user() {
    info "Creando el usuario no privilegiado"

    arch-chroot "$TARGET_MOUNT" useradd -m -G wheel -s /bin/bash "$USER_NAME"

    printf '\nDefina la contrasena de %s. No se mostrara ni se guardara.\n\n' "$USER_NAME"
    arch-chroot "$TARGET_MOUNT" passwd "$USER_NAME"

    cat > "$TARGET_MOUNT/etc/sudoers.d/10-wheel" <<'EOF'
# Administradores autorizados. Sudo solicita la contrasena del usuario.
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 0440 "$TARGET_MOUNT/etc/sudoers.d/10-wheel"
    arch-chroot "$TARGET_MOUNT" visudo -cf /etc/sudoers

    # El trabajo diario se realiza con el usuario normal y sudo.
    arch-chroot "$TARGET_MOUNT" passwd -l root

    ok "Usuario $USER_NAME creado; acceso directo cotidiano de root bloqueado."
}

configure_zram() {
    info "Configurando ZRAM"

    cat > "$TARGET_MOUNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
EOF
}

configure_xfce() {
    info "Configurando XFCE y LightDM"

    install -d -m 0755 "$TARGET_MOUNT/etc/lightdm/lightdm.conf.d"
    cat > "$TARGET_MOUNT/etc/lightdm/lightdm.conf.d/10-xfce.conf" <<'EOF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=xfce
EOF

    arch-chroot "$TARGET_MOUNT" systemctl enable NetworkManager.service
    arch-chroot "$TARGET_MOUNT" systemctl enable systemd-timesyncd.service
    arch-chroot "$TARGET_MOUNT" systemctl enable lightdm.service
    arch-chroot "$TARGET_MOUNT" systemctl enable vboxservice.service
    arch-chroot "$TARGET_MOUNT" systemctl set-default graphical.target

    ok "XFCE iniciara mediante LightDM en el primer arranque."
}

configure_initramfs_and_boot() {
    local luks_uuid=""
    local boot_entry="$TARGET_MOUNT/boot/loader/entries/arch.conf"
    local fallback_entry="$TARGET_MOUNT/boot/loader/entries/arch-fallback.conf"

    info "Configurando initramfs cifrado y systemd-boot"

    luks_uuid="$(cryptsetup luksUUID "$ROOT_PART")"
    [[ -n "$luks_uuid" ]] || die "No se pudo obtener el UUID de LUKS."

    sed -i -E \
        's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
        "$TARGET_MOUNT/etc/mkinitcpio.conf"
    grep -q '^HOOKS=(base systemd .* sd-encrypt ' "$TARGET_MOUNT/etc/mkinitcpio.conf" || \
        die "No se pudo configurar mkinitcpio con sd-encrypt."

    arch-chroot "$TARGET_MOUNT" mkinitcpio -P

    if ! arch-chroot "$TARGET_MOUNT" bootctl --esp-path=/boot install; then
        warn "No se pudo registrar systemd-boot en NVRAM; se instalara la ruta UEFI de respaldo."
        arch-chroot "$TARGET_MOUNT" bootctl --esp-path=/boot --variables=no install
    fi

    install -d -m 0700 "$TARGET_MOUNT/boot/loader/entries"
    cat > "$TARGET_MOUNT/boot/loader/loader.conf" <<'EOF'
default arch.conf
timeout 3
console-mode max
editor no
EOF

    {
        printf 'title   Arch Linux (XFCE)\n'
        printf 'linux   /vmlinuz-linux\n'
        [[ -n "$MICROCODE_IMAGE" ]] && printf 'initrd  /%s\n' "$MICROCODE_IMAGE"
        printf 'initrd  /initramfs-linux.img\n'
        printf 'options rd.luks.name=%s=%s root=/dev/mapper/%s rootfstype=btrfs rootflags=subvol=@ rw\n' \
            "$luks_uuid" "$CRYPT_NAME" "$CRYPT_NAME"
    } > "$boot_entry"

    {
        printf 'title   Arch Linux (initramfs de respaldo)\n'
        printf 'linux   /vmlinuz-linux\n'
        [[ -n "$MICROCODE_IMAGE" ]] && printf 'initrd  /%s\n' "$MICROCODE_IMAGE"
        printf 'initrd  /initramfs-linux-fallback.img\n'
        printf 'options rd.luks.name=%s=%s root=/dev/mapper/%s rootfstype=btrfs rootflags=subvol=@ rw\n' \
            "$luks_uuid" "$CRYPT_NAME" "$CRYPT_NAME"
    } > "$fallback_entry"

    chmod 0600 \
        "$TARGET_MOUNT/boot/loader/loader.conf" \
        "$boot_entry" \
        "$fallback_entry"

    ok "systemd-boot configurado sin editor de parametros en el arranque."
}

verify_installation() {
    info "Verificando la instalacion antes de desmontar"

    cryptsetup isLuks "$ROOT_PART"
    btrfs subvolume list "$TARGET_MOUNT" | tee /tmp/cy502-btrfs-subvolumes.txt
    arch-chroot "$TARGET_MOUNT" pacman -Q \
        xfce4-session lightdm lightdm-gtk-greeter networkmanager zram-generator \
        virtualbox-guest-utils
    arch-chroot "$TARGET_MOUNT" systemctl is-enabled NetworkManager.service
    arch-chroot "$TARGET_MOUNT" systemctl is-enabled lightdm.service
    arch-chroot "$TARGET_MOUNT" systemctl is-enabled vboxservice.service
    arch-chroot "$TARGET_MOUNT" visudo -cf /etc/sudoers

    [[ -f "$TARGET_MOUNT/boot/loader/entries/arch.conf" ]] || \
        die "Falta la entrada principal de systemd-boot."
    [[ -f "$TARGET_MOUNT/etc/systemd/zram-generator.conf" ]] || \
        die "Falta la configuracion de ZRAM."

    printf '\nEvidencia de particiones y sistemas de archivos:\n'
    lsblk -f "$DISK"

    ok "Las comprobaciones esenciales finalizaron correctamente."
}

finish_installation() {
    info "Guardando el registro y desmontando"

    install -Dm0600 "$LOG_FILE" "$TARGET_MOUNT/var/log/cy502-instalacion.log"
    sync

    umount -R "$TARGET_MOUNT"
    TARGET_MOUNTED=0
    cryptsetup close "$CRYPT_NAME"
    CRYPT_OPENED=0

    trap - ERR INT TERM

    printf '\n\033[1;32m============================================================\033[0m\n'
    printf '\033[1;32m INSTALACION FINALIZADA CORRECTAMENTE\033[0m\n'
    printf '\033[1;32m============================================================\033[0m\n'
    printf 'Equipo:      %s\n' "$HOST_NAME"
    printf 'Usuario:     %s\n' "$USER_NAME"
    printf 'Escritorio:  XFCE + LightDM\n'
    printf 'Cifrado:     LUKS2\n'
    printf 'Sistema:     Btrfs\n'
    printf '\nRetire la ISO de Arch Linux y reinicie con: reboot\n'
    printf 'En el arranque, introduzca la frase de paso de LUKS2.\n'
    printf 'Registro de la sesion live: %s\n' "$LOG_FILE"
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    (( $# == 0 )) || die "Argumento desconocido. Use --help."

    LOG_FILE="/tmp/cy502-instalacion-$(date +%Y%m%d-%H%M%S).log"
    : > "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    trap 'on_error $? $LINENO' ERR
    trap 'on_signal' INT TERM

    printf '\033[1;36mArch Linux CY-502 - Instalador %s\033[0m\n' "$SCRIPT_VERSION"
    printf 'Fecha: %s\n' "$(date --iso-8601=seconds)"

    check_environment
    collect_identity
    select_disk
    partition_and_encrypt
    create_btrfs_layout
    install_packages
    configure_locale_and_identity
    configure_user
    configure_zram
    configure_xfce
    configure_initramfs_and_boot
    verify_installation
    finish_installation
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
