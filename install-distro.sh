#!/data/data/com.termux/files/usr/bin/bash

################################################################################
#                                                                              #
# Termux Distro Installer Template.                                            #
#                                                                              #
# Template for creating a Linux Distro installer.                              #
#                                                                              #
# Copyright (C) 2023-2025  Jore <https://github.com/jorexdeveloper>            #
#                                                                              #
# This program is free software: you can redistribute it and/or modify         #
# it under the terms of the GNU General Public License as published by         #
# the Free Software Foundation, either version 3 of the License, or            #
# (at your option) any later version.                                          #
#                                                                              #
# This program is distributed in the hope that it will be useful,              #
# but WITHOUT ANY WARRANTY; without even the implied warranty of               #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                #
# GNU General Public License for more details.                                 #
#                                                                              #
# You should have received a copy of the GNU General Public License            #
# along with this program.  If not, see <https://www.gnu.org/licenses/>.       #
#                                                                              #
################################################################################
# shellcheck disable=SC2034,SC2155

# ATTENTION!!! CHANGE BELOW FUNTIONS FOR DISTRO DEPENDENT ACTIONS!!!

################################################################################
# Called before any safety checks                                              #
# New Variables: AUTHOR GITHUB LOG_FILE ACTION_INSTALL ACTION_CONFIGURE        #
#                ROOTFS_DIRECTORY COLOR_SUPPORT (all available colors)         #
################################################################################
pre_check_actions() {
	P=${N} # primary color
	S=${N} # secondary color
	T=${M} # tertiary color
}

################################################################################
# Called before printing intro                                                 #
# New Variables: none                                                          #
################################################################################
distro_banner() {
	local spaces=$(printf "%*s" $((($(stty size | awk '{print $2}') - 13) / 2)) "")
	msg -a "${spaces}${P}Termux-Distro${S}"
	msg -a "${spaces}     ${T}${VERSION_NAME}${S}"
}

################################################################################
# Called after checking architecture and required pkgs                         #
# New Variables: SYS_ARCH LIB_GCC_PATH                                         #
################################################################################
post_check_actions() {
	return
}

################################################################################
# Called after checking for rootfs directory                                   #
# New Variables: KEEP_ROOTFS_DIRECTORY                                         #
################################################################################
pre_install_actions() {
	ARCHIVE_NAME=termux-distro-${SYS_ARCH}.tar.xz
}

################################################################################
# Called after extracting rootfs                                               #
# New Variables: KEEP_ROOTFS_ARCHIVE                                           #
################################################################################
post_install_actions() {
	return
}

################################################################################
# Called before making configurations                                          #
# New Variables: none                                                          #
################################################################################
pre_config_actions() {
	return
}

################################################################################
# Called after configurations                                                  #
# New Variables: none                                                          #
################################################################################
post_config_actions() {
	if [[ -f ${ROOTFS_DIRECTORY}/etc/locale.gen && -x ${ROOTFS_DIRECTORY}/sbin/dpkg-reconfigure ]]; then
		msg -tn "Generating locales..."
		sed -i -E 's/#[[:space:]]?(en_US.UTF-8[[:space:]]+UTF-8)/\1/g' "${ROOTFS_DIRECTORY}"/etc/locale.gen

		if distro_exec locale-gen &>>"${LOG_FILE}"; then # DEBIAN_FRONTEND=noninteractive /sbin/dpkg-reconfigure locales &>>"${LOG_FILE}"
			cursor -u1
			msg -ts "Locales generated"
		else
			cursor -u1
			msg -te "Failed to generate locales."
		fi
	fi
}


pre_complete_actions() {
	msg -tn "Creating xstartup program..."

	local xstartup=$(
		# Customize depending on distribution defaults
		cat 2>>"${LOG_FILE}" <<-EOF
			#!/bin/bash
			unset SESSION_MANAGER
			unset DBUS_SESSION_BUS_ADDRESS

			export XDG_RUNTIME_DIR=\${TMPDIR}/runtime-"\${USER}"
			export SHELL=\${SHELL}

			if [[ -r ~/.Xresources ]]; then
			    xrdb ~/.Xresources
			fi

		
		EOF
	)

	if {
		mkdir -p "${ROOTFS_DIRECTORY}"/root/.vnc &&
			echo "${xstartup}" >"${ROOTFS_DIRECTORY}"/root/.vnc/xstartup &&
			chmod 744 "${ROOTFS_DIRECTORY}"/root/.vnc/xstartup &&
			if [[ ${DEFAULT_LOGIN} != root ]]; then
				mkdir -p "${ROOTFS_DIRECTORY}"/home/"${DEFAULT_LOGIN}"/.vnc &&
					echo "${xstartup}" >"${ROOTFS_DIRECTORY}"/home/"${DEFAULT_LOGIN}"/.vnc/xstartup &&
					chmod 744 "${ROOTFS_DIRECTORY}"/home/"${DEFAULT_LOGIN}"/.vnc/xstartup
			fi
	} 2>>"${LOG_FILE}"; then
		cursor -u1
		msg -ts "Xstartup program created"
	else
		cursor -u1
		msg -te "Failed create xstartup program"
	fi
}


post_complete_actions() {
	return
}


# Does something
do_something() {
	return
}

DISTRO_NAME="Termux Distro"
PROGRAM_NAME=$(basename "${0}")
DISTRO_REPOSITORY=termux-distro
KERNEL_RELEASE=$(uname -r)
VERSION_NAME=1.0

SHASUM_CMD=sha256sum
TRUSTED_SHASUMS=$(
	cat <<-EOF
		0000000000000000000000000000000000000000000000000000000000000000 *termux-distro-armhf.tar.xz
		0000000000000000000000000000000000000000000000000000000000000000 *termux-distro-arm64.tar.xz
	EOF
)

ARCHIVE_STRIP_DIRS=0 # directories stripped by tar when extracting rootfs archive
BASE_URL=https://raw.githubusercontent.com/jorexdeveloper/termux-distro
TERMUX_FILES_DIR=/data/data/com.termux/files

DISTRO_SHORTCUT=${TERMUX_FILES_DIR}/usr/bin/td
DISTRO_LAUNCHER=${TERMUX_FILES_DIR}/usr/bin/termux-distro

DEFAULT_ROOTFS_DIR=${TERMUX_FILES_DIR}/termux-distro
DEFAULT_LOGIN=user

# WARNING!!! DO NOT CHANGE BELOW!!!

# Check in program's directory for template
distro_template=$(realpath "$(dirname "${0}")")/termux-distro.sh

# shellcheck disable=SC1090
if [[ -f ${distro_template} ]] || curl -fsSLO https://raw.githubusercontent.com/jorexdeveloper/termux-distro/main/termux-distro.sh 2>/dev/null; then
	source "${distro_template}" "${@}" || exit 1
else
	echo "You need an active internet connection to run this program."
fi
