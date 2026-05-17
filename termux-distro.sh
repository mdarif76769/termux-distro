
safety_check() {
	if [[ ${EUID} == 0 || $(id -u) == 0 ]]; then
		msg -aq "Do NOT run this program with root permissions! This can cause several issues and potentially damage your phone."
	fi

	local pid=$(grep TracerPid /proc/$$/status | awk '{print $2}')
	if [[ ${pid} != 0 ]]; then
		if [[ $(grep Name /proc/"${pid}"/status | awk '{print $2}') == proot ]]; then
			msg -aq "Do NOT run this program within proot! This can lead to performance degradation and other issues."
		fi
	fi

	if [[ ! -t 0 ]]; then
		msg -aq "This program depends on terminal input for some actions. Please don't pipe or redirect it."
	fi
}

print_intro() {
	msg -h "Welcome to ${DISTRO_NAME}"
}

check_arch() {
	local arch
	if command -v getprop &>>"${LOG_FILE}"; then
		arch=$(getprop ro.product.cpu.abi unknown-arch)
	elif command -v uname &>>"${LOG_FILE}"; then
		arch=$(uname -m)
	else
		msg -fq "Failed to get device architecture"
	fi

	case "${arch}" in
		arm64-v8a | armv8l)
			SYS_ARCH=arm64
			LIB_GCC_PATH=/usr/lib/aarch64-linux-gnu/libgcc_s.so.1
			;;
		armeabi | armv7l | armeabi-v7a)
			SYS_ARCH=armhf
			LIB_GCC_PATH=/usr/lib/arm-linux-gnueabihf/libgcc_s.so.1
			;;
		*)
			
			msg -fqe "${arch} is NOT supported"
			;;
	esac

	msg -ts "${arch} is supported"
}

package_check() {
	msg -tn "Upgrading Termux packages..."
	trap 'buffer -h; echo; msg -fem2; exit 130' INT
	buffer -s

	if buffer -i pkg update -y && pkg update -y &&
		buffer -i pkg upgrade -y && pkg upgrade -y < <(printf "\n\n\n\n\n"); then
		buffer -h3
		trap - INT
		cursor -u1
		msg -ts "Termux packages upgraded"
	else
		buffer -h5
		trap - INT
		cursor -u1
		msg -te "Failed to upgrade Termux packages"
		msg -fqm0
	fi

	msg -tn "Installing program dependencies"
	trap 'buffer -h; echo; msg -fem2; exit 130' INT
	buffer -s

	local package
	for package in curl proot pulseaudio sed tar unzip xz-utils; do
		buffer -i pkg install -y "${package}"

		if ! pkg install -y "${package}"; then
			buffer -h5
			trap - INT
			cursor -u1
			msg -te "Failed to install ${package}"
			msg -fqm0
		fi
	done

	buffer -h3
	trap - INT
	cursor -u1
	msg -ts "Program dependencies installed"
}

rootfs_directory_check() {
	if [[ -e ${ROOTFS_DIRECTORY} ]]; then
		if [[ -d ${ROOTFS_DIRECTORY} ]]; then
			if [[ $(ls -UA "${ROOTFS_DIRECTORY}" 2>>"${LOG_FILE}") ]]; then
				choose -t "Found an existing rootfs directory" \
					"Use" "Remove"

				if [[ ${?} -eq 1 ]]; then
					KEEP_ROOTFS_DIRECTORY=1
					return
				fi
			else
				remove "${ROOTFS_DIRECTORY}" &>>"${LOG_FILE}" || wtf "removing empty rootfs directory"
				return
			fi
		else
			msg -t "Found an existing file named"
			msg "${ROOTFS_DIRECTORY}"

			if ! ask -n -- -t "Remove and proceed?"; then
				msg -fqm2
			fi
		fi

		msg -tn "Removing ${ROOTFS_DIRECTORY}..."

		if remove "${ROOTFS_DIRECTORY}" &>>"${LOG_FILE}"; then
			cursor -u1
			msg -ts "Removed ${ROOTFS_DIRECTORY}"
		else
			cursor -u1
			msg -fq "Failed to remove ${ROOTFS_DIRECTORY}"
		fi
	fi
}

download_rootfs_archive() {
	if [[ ! ${KEEP_ROOTFS_DIRECTORY} ]]; then
		if [[ -e ${ARCHIVE_NAME} ]]; then
			if [[ -f ${ARCHIVE_NAME} ]]; then
				msg -t "Using existing rootfs archive"

				KEEP_ROOTFS_ARCHIVE=1
				return
			else
				msg -t "Found item with the same name as the rootfs archive"

				if ! ask -n -- -t "Remove and proceed?"; then
					msg -fqm2
				fi
			fi

			if remove "${ARCHIVE_NAME}" &>>"${LOG_FILE}"; then
				msg -ts "Removed ${ARCHIVE_NAME}"
			else
				msg -fq "Failed to remove ${ARCHIVE_NAME}"
			fi
		fi

		if [[ ${KEEP_ROOTFS_ARCHIVE} ]]; then
			msg -tn "Downloading new rootfs archive..."
		else
			msg -tn "Downloading rootfs archive"
		fi

		msg -a " (${T}$(curl --disable --fail --location --silent --head "${BASE_URL}/${ARCHIVE_NAME}" | awk 'tolower($1)=="content-length:" {cl=$2} END {print cl+0}' | numfmt --to=iec --suffix=B)${P})"

		local tmp_dload=${ARCHIVE_NAME}.pending
		if curl --disable --fail --location --progress-bar --retry-connrefused --retry 0 --retry-delay 3 --continue-at - --output "${tmp_dload}" "${BASE_URL}/${ARCHIVE_NAME}"; then
			mv "${tmp_dload}" "${ARCHIVE_NAME}" &>>"${LOG_FILE}"

			cursor -u3
			if [[ ${KEEP_ROOTFS_ARCHIVE} ]]; then
				KEEP_ROOTFS_ARCHIVE=
				msg -ts "Downloaded new rootfs archive"
			else
				msg -ts "Downloaded rootfs archive"
			fi
		else
			cursor -u1
			msg -te "Failed to download rootfs archive"
			msg -fqm0
		fi
	fi
}

verify_rootfs_archive() {
	if [[ ! ${KEEP_ROOTFS_DIRECTORY} ]]; then
		msg -tn "Verifying rootfs archive..."

		if grep --regexp="${ARCHIVE_NAME}$" <<<"${TRUSTED_SHASUMS}" 2>>"${LOG_FILE}" | "${SHASUM_CMD}" --quiet --check &>>"${LOG_FILE}"; then
			cursor -u1
			if [[ ${NEW_ROOTFS_ARCHIVE} ]]; then
				msg -ts "New rootfs archive is ok"
			else
				msg -ts "Rootfs archive is ok"
				return
			fi
		else
			cursor -u1
			if [[ ${NEW_ROOTFS_ARCHIVE} ]]; then
				msg -te "New rootfs archive is malformed"
			else
				msg -te "Rootfs archive is malformed"
			fi

			if [[ ${KEEP_ROOTFS_ARCHIVE} ]]; then
				if remove "${ARCHIVE_NAME}"; then
					NEW_ROOTFS_ARCHIVE=1
					download_rootfs_archive
					verify_rootfs_archive
				else
					msg -fq "Failed to remove malformed rootfs archive"
				fi
			else
				wtf "verifying downloaded rootfs archive"
			fi
		fi
	fi
}

extract_rootfs_archive() {
	if [[ ! ${KEEP_ROOTFS_DIRECTORY} ]]; then
		msg -t "Extracting rootfs archive"
		mkdir -p "${ROOTFS_DIRECTORY}"
		trap 'printf "\r\e[0J${N}${RC}"; trap - INT; msg -fen "Process interupted (clearing cache...)"; remove "${ROOTFS_DIRECTORY}" &>>"${LOG_FILE}"; cursor -u1; msg -fe "Process interupted (cache cleared)"; exit 130' INT

		if proot --link2symlink tar --strip="${ARCHIVE_STRIP_DIRS}" --delay-directory-restore --preserve-permissions --warning=no-unknown-keyword --extract --auto-compress --exclude="dev" --file="${ARCHIVE_NAME}" --directory="${ROOTFS_DIRECTORY}" --checkpoint=102 --checkpoint-action=ttyout="${HC}${S}└${N}  ${T}Progress: %{}T%* \r${N}" &>>"${LOG_FILE}"; then
			trap - INT
			cursor -u2
			msg -ts "Rootfs archive extracted"
		else
			trap - INT
			msg -fen "Failed to extract rootfs archive (clearing cache...)"
			remove "${ROOTFS_DIRECTORY}" &>>"${LOG_FILE}"
			cursor -u1
			msg -fq "Failed to extract rootfs archive (cache cleared)"
		fi
	fi
}

create_rootfs_launcher() {
	msg -tn "Creating ${DISTRO_NAME} launcher..."

	mkdir -p "$(dirname "${DISTRO_LAUNCHER}")" &>>"${LOG_FILE}" && cat >"${DISTRO_LAUNCHER}" 2>>"${LOG_FILE}" <<-EOF
	
		unset LD_PRELOAD

		program_name=$(basename "${DISTRO_LAUNCHER}")
		working_dir=
		home_dir=
		env_vars=(
		    LANG=C.UTF-8
		    TERM=\${TERM:-xterm-256color}
		    PATH=${DEFAULT_PATH}:${TERMUX_FILES_DIR}/usr/local/bin:${TERMUX_FILES_DIR}/usr/bin
		)
		custom_ids=
		isolated_env=
		custom_bindings=()
		share_tmp=
		no_kill_on_exit=
		no_link2symlink=
		no_proot_errors=
		no_sysvipc=
		fix_ports=
		kernel_release=
		user_name=

		
		while [[ \${#} -gt 0 ]]; do
		    case "\${1}" in
		        --wd*)
		            optarg=\${1/--wd/}
		            optarg=\${optarg/=/}
		            if [[ ! \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '--wd' requires an argument."
		                exit 1
		            fi
		            working_dir=\${optarg}
		            ;;
		        --home*)
		            optarg=\${1/--home/}
		            optarg=\${optarg/=/}
		            if [[ ! \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '--home' requires an argument."
		                exit 1
		            fi
		            home_dir=\${optarg}
		            ;;
		        --env*)
		            optarg=\${1/--env/}
		            optarg=\${optarg/=/}
		            if [[ ! \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '--env' requires an argument."
		                exit 1
		            fi
		            env_vars+=("\${optarg}")
		            ;;
		        --id*)
		            optarg=\${1/--id/}
		            optarg=\${optarg/=/}
		            if [[ ! \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '--id' requires an argument."
		                exit 1
		            fi
		            custom_ids=\${optarg}
		            ;;
		        --termux-ids)
		            custom_ids=\$(id -u):\$(id -g)
		            ;;
		        --isolated)
		            isolated_env=1
		            ;;
		        --bind*)
		            optarg=\${1/--bind/}
		            optarg=\${optarg/=/}
		            if [[ ! \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '--bind' requires an argument."
		                exit 1
		            fi
		            custom_bindings+=(--bind="\${optarg}")
		            ;;
		        --share-tmp)
		            share_tmp=1
		            ;;
		        --no-kill-on-exit)
		            no_kill_on_exit=1
		            ;;
		        --no-link2symlink)
		            no_link2symlink=1
		            ;;
		        --no-proot-errors)
		            no_proot_errors=1
		            ;;
		        --no-sysvipc)
		            no_sysvipc=1
		            ;;
		        --fix-ports)
		            fix_ports=1
		            ;;
		        --kernel*)
		            optarg=\${1/--kernel/}
		            optarg=\${optarg/=/}
		            if [[ ! \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '--kernel' requires an argument."
		                exit 1
		            fi
		            kernel_release=\${optarg}
		            ;;
		        -r | --rename*)
		            optarg=\${1/--rename/}
		            optarg=\${optarg/=/}
		            if [[ ! \${optarg} || \${optarg} == -r ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '-r' or '--rename' requires an argument."
		                exit 1
		            fi
		            if [[ ! -e "${ROOTFS_DIRECTORY}" ]]; then
		                echo "'${ROOTFS_DIRECTORY}' is missing"
		                exit 1
		            fi
		            old_chroot="${ROOTFS_DIRECTORY}"
		            new_chroot=\$(realpath "\${optarg}")
		            rmdir "\${new_chroot}" &>/dev/null
		            if [[ -e \${new_chroot} ]]; then
		                echo "'\${new_chroot}' already exists"
		                exit 1
		            fi
		            echo "Renaming '\${old_chroot}' to '\${new_chroot}'"
		            if mv "\${old_chroot}" "\${new_chroot}" &&
		                echo "Updating proot links" &&
		                find "\${new_chroot}" -type l | while read -r name; do
		                    old_target=\$(readlink "\${name}")
		                    if [[ \${old_target:0:\${#old_chroot}} == "\${old_chroot}" ]]; then
		                        ln -sf "\${old_target/\${old_chroot}/\${new_chroot}}" "\${name}"
		                    fi
		                done &&
		                echo "Updating the \${program_name} command" &&
		                sed -Ei "s@\${old_chroot}@\${new_chroot}@" ${DISTRO_LAUNCHER}; then
		                echo "${DISTRO_NAME} rootfs renamed succesfully"
		                exit
		            else
		                echo "Failed to rename ${DISTRO_NAME} rootfs"
		                exit 1
		            fi
		            ;;
		        -b | --backup*)
		            optarg="\${1/--backup/}"
		            optarg="\${optarg/=/}"
		            if [[ \${optarg} == -b || -z \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '-b' or '--backup' requires an argument."
		                exit 1
		            fi
		            if [[ ! -e "${ROOTFS_DIRECTORY}" ]]; then
		                echo "'${ROOTFS_DIRECTORY}' is missing"
		                exit 1
		            fi
		            shift
		            file=\${optarg}
		            include=(.l2s bin boot captures etc home lib media mnt opt proc root run sbin snap srv sys tmp usr var)
		            exclude=(apex data dev linkerconfig product sdcard storage system vendor "\${@}")
		            echo "Backing up ${DISTRO_NAME} into '\${file}'"
		            echo "Including:" "\${include[@]}"
		            echo "Excluding:" "\${exclude[@]}"
		            exclude_args=()
		            for i in "\${exclude[@]}"; do
		                i=\$(echo -n "\${i}" | sed -E 's@^/@@')
		                exclude_args=("\${exclude_args[@]}" --exclude="\${i}")
		            done
		            for i in "\${include[@]}" "\${exclude[@]}"; do
		                mkdir -p "${ROOTFS_DIRECTORY}/\${i}" &>/dev/null
		            done
		            if tar --warning=no-file-ignored --one-file-system --xattrs --xattrs-include='*' --preserve-permissions --create --auto-compress -C "${ROOTFS_DIRECTORY}" --file="\${file}" "\${exclude_args[@]}" "\${include[@]}"; then
		                echo "${DISTRO_NAME} backed up succesfully"
		                exit
		            else
		                echo "Failed to backup ${DISTRO_NAME}"
		                exit 1
		            fi
		            ;;
		        -R | --restore*)
		            optarg=\${1/--restore/}
		            optarg=\${optarg/=/}
		            if [[ \${optarg} == -R || ! \${optarg} ]]; then
		                shift
		                optarg=\${1}
		            fi
		            if [[ ! \${optarg} ]]; then
		                echo "Option '-R' or '--restore' requires an argument."
		                exit 1
		            fi
		            if [[ ! -e \${optarg} ]]; then
		                echo "'\${optarg}' is missing"
		                exit 1
		            fi
		            if [[ -e "${ROOTFS_DIRECTORY}" ]] && ! rmdir "${ROOTFS_DIRECTORY}" &>/dev/null; then
		                echo "'${ROOTFS_DIRECTORY}' already exists"
		                echo "  <1> Remove"
		                echo "  <2> Overwrite "
		                echo "  <3> Quit (default)"
		                read -r -p "Select action: " choice
		                case "\${choice}" in
		                    1 | r | R)
		                        echo "Removing '${ROOTFS_DIRECTORY}'"
		                        chmod 777 -R "${ROOTFS_DIRECTORY}" &>/dev/null
		                        rm -rf "${ROOTFS_DIRECTORY}" || {
		                            echo "Failed to remove '${ROOTFS_DIRECTORY}'" && exit 1
		                        }
		                        ;;
		                    2 | o | O)
		                        echo "Overwriting '${ROOTFS_DIRECTORY}'"
		                        ;;
		                    *)
		                        echo "Operation cancelled"
		                        exit 1
		                        ;;
		                esac
		            fi
		            file=\${optarg}
		            echo "Restoring ${DISTRO_NAME} from '\${file}'"
		            mkdir -p "${ROOTFS_DIRECTORY}" &>/dev/null
		            if tar --delay-directory-restore --preserve-permissions --warning=no-unknown-keyword --extract --auto-compress -C "${ROOTFS_DIRECTORY}" --file "\${file}"; then
		                echo "${DISTRO_NAME} restored succesfully"
		                exit
		            else
		                echo "Failed to restore ${DISTRO_NAME}"
		                exit 1
		            fi
		            ;;
		        -u | --uninstall)
		            if [[ -d "${ROOTFS_DIRECTORY}" ]]; then
		                echo "Uninstalling ${DISTRO_NAME} from '${ROOTFS_DIRECTORY}'"
		                if read -r -p "Confirm action (y/N): " choice && [[ \${choice} =~ ^(y|Y)$ ]]; then
		                    echo "Uninstalling ${DISTRO_NAME}"
		                    chmod 777 -R "${ROOTFS_DIRECTORY}" ${DISTRO_LAUNCHER} ${DISTRO_SHORTCUT} &>/dev/null
		                    if rm -rf "${ROOTFS_DIRECTORY}" ${DISTRO_LAUNCHER} ${DISTRO_SHORTCUT}; then
		                        echo "${DISTRO_NAME} uninstalled"
		                        exit
		                    else
		                        echo "Failed to uninstall ${DISTRO_NAME}"
		                    fi
		                else
		                    echo "Operation cancelled"
		                fi
		            else
		                echo "No rootfs found in '${ROOTFS_DIRECTORY}'"
		            fi
		            exit 1
		            ;;
		        -v | --version)
		            echo "\${program_name} version ${VERSION_NAME}"
		            echo "Copyright (C) 2023-2025 ${AUTHOR} <${GITHUB}>."
		            echo "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>."
		            echo
		            echo "This is free software, you are free to change and redistribute it."
		            echo "There is NO WARRANTY, to the extent permitted by law."
		            exit
		            ;;
		        -h | --help)
		            echo "Usage: \${program_name} [OPTION] [USERNAME] [-- [COMMAND [ARGS]]]"
		            echo
		            echo "Login or execute COMMAND in ${DISTRO_NAME} as USERNAME (default=${DEFAULT_LOGIN})."
		            echo
		            echo "LOGIN OPTIONS:"
		            echo "      --wd DIR               Set working directory. (defaults to HOME)"
		            echo "      --home DIR             Set home directory."
		            echo "                             (defaults to /home/USERNAME or /root)"
		            echo "      --env VAR=VAL          Set environment variable."
		            echo "      --id UID:GID           Set the current user and group ids."
		            echo "      --termux-ids           Use Termux user and group ids."
		            echo "      --isolated             Do not mount host specific directories in the"
		            echo "                             guest file system."
		            echo "      --bind PATH1[:PATH2]   Make PATH1 accessible as PATH2 in the guest"
		            echo "                             file system. (overrrides '--isolated')"
		            echo "      --share-tmp            Bind Termux TMPDIR to /tmp in the guest file"
		            echo "                             system."
		            echo "      --no-kill-on-exit      Do not kill running processes on exit."
		            echo "      --no-link2symlink      Disable hard-link emulation by proot."
		            echo "      --no-proot-errors      Prevent proot from printing error messages"
		            echo "                             except fatal errors."
		            echo "      --no-sysvipc           Disable System V IPC emulation by proot."
		            echo "      --fix-ports            Modify bindings to protected ports to use a"
		            echo "                             higher port number."
		            echo "      --kernel STRING        Set the current kernel release."
		            echo
		            echo "MANAGEMENT OPTIONS:"
		            echo "  -r, --rename PATH          Rename the rootfs directory."
		            echo "  -b, --backup FILE [DIRS]   Backup the rootfs directory excluding DIRS."
		            echo "                             The backup is performed as a TAR archive and"
		            echo "                             compression is determined by the output file"
		            echo "                             extension."
		            echo "  -R, --restore FILE         Restore the rootfs directory from TAR archive."
		            echo "  -u, --uninstall            Uninstall ${DISTRO_NAME}."
		            echo
		            echo "OTHER OPTIONS:"
		            echo "  -v, --version              Print program version and exit."
		            echo "  -h, --help                 Print help message and exit."
		            echo
		            echo "For more information, visit:"
		            echo "⇒ ${GITHUB}/${DISTRO_REPOSITORY}"
		            exit
		            ;;
		        --)
		            shift
		            break
		            ;;
		        -*)
		            echo "Unrecognized option '\${1}'."
		            echo "See '\${program_name} --help' for more information"
		            exit 1
		            ;;
		        *)
		            if [[ ! \${user_name} ]]; then
		                user_name=\${1}
		            else
		                echo "Received too many arguments. Did you forget to add '--'?"
		                echo "See '\${program_name} --help' for more information"
		                exit 1
		            fi
		            ;;
		    esac
		    shift
		done

		# Set login name
		if [[ ! \${user_name} ]]; then
		    user_name=${DEFAULT_LOGIN}
		fi

		# Check if user exists
		if [[ ! -e "${ROOTFS_DIRECTORY}"/etc/passwd ]] || ! grep -qE "^\${user_name}:" "${ROOTFS_DIRECTORY}"/etc/passwd &>/dev/null; then
		    echo "User \${user_name} does not exist in ${DISTRO_NAME}."
		    exit 1
		fi

		# Set home directory
		if [[ ! \${home_dir} ]]; then
		    if [[ \${user_name} == root ]]; then
		        home_dir=/root
		    else
		        home_dir=/home/\${user_name}
		    fi
		fi

		# Set home directory in environment
		env_vars=(HOME="\${home_dir}" "\${env_vars[@]}")
		mkdir -p "${ROOTFS_DIRECTORY}\${home_dir}" &>/dev/null

		# Prevent running as root
		if [[ \${EUID} -eq 0 || \$(id -u) -eq 0 ]]; then
		    echo "Do NOT start ${DISTRO_NAME} with root permissions! This can cause several issues and potentially damage your phone."
		    exit 1
		fi

		# Prevent running within proot
		pid=\$(grep TracerPid /proc/\$\$/status | awk '{print \$2}')
		if [[ \${pid} != 0 ]]; then
		    if [[ \$(grep Name /proc/"\${pid}"/status | awk '{print \$2}') == proot ]]; then
		        echo "Do NOT start ${DISTRO_NAME} within proot! This can lead to performance degradation and other issues."
		        exit 1
		    fi
		fi

		# Check for login command
		if [[ ! \${*} ]]; then
		    # Prefer su as login command
		    if [[ -x "${ROOTFS_DIRECTORY}"/usr/bin/su ]]; then
		        set -- su --login "\${user_name}"
		    elif [[ -x "${ROOTFS_DIRECTORY}"/usr/bin/login ]]; then
		        set -- login "\${user_name}"
		    else
		        echo "No login command found in the guest rootfs."
		        echo "See '\${program_name} --help' to learn how to run programs without logging in."
		        exit 1
		    fi
		fi

		# Create directory where proot stores all hard link info
		export PROOT_L2S_DIR="${ROOTFS_DIRECTORY}"/.l2s
		if [[ ! -d \${PROOT_L2S_DIR} ]]; then
		    mkdir -p "\${PROOT_L2S_DIR}"
		fi

		# Create fake /root/.version required by some apps i.e LibreOffice
		if [[ ! -f "${ROOTFS_DIRECTORY}"/root/.version ]]; then
		    mkdir -p "${ROOTFS_DIRECTORY}"/root && touch "${ROOTFS_DIRECTORY}"/root/.version
		fi

		proot_args=()
		proot_args+=(-L)
		proot_args+=(--cwd="\${working_dir:-\${home_dir}}")
		proot_args+=(--rootfs="${ROOTFS_DIRECTORY}")

		# Use custom UID/GID
		if [[ \${custom_ids} ]]; then
		    proot_args+=(--change-id="\${custom_ids}")
		else
		    proot_args+=(--root-id)
		fi

		# Enable proot hard-link emulation
		if [[ ! \${no_link2symlink} ]]; then
		    proot_args+=(--link2symlink)
		fi

		# Kill all processes on command exit
		if [[ ! \${no_kill_on_exit} ]]; then
		    proot_args+=(--kill-on-exit)
		fi

		# Handle System V IPC syscalls in proot
		if [[ ! \${no_sysvipc} ]]; then
		    proot_args+=(--sysvipc)
		fi

		# Make current kernel appear as kernel_release
		proot_args+=(--kernel-release="\${kernel_release:-${KERNEL_RELEASE}}")

		# Turn off proot errors
		if [[ \${no_proot_errors} ]]; then
		    proot_args+=(--verbose=-1)
		fi

		# Core file systems that should always be present.
		proot_args+=(--bind=/dev)
		proot_args+=(--bind=/dev/urandom:/dev/random)
		proot_args+=(--bind=/proc)
		proot_args+=(--bind=/proc/self/fd:/dev/fd)
		proot_args+=(--bind=/proc/self/fd/0:/dev/stdin)
		proot_args+=(--bind=/proc/self/fd/1:/dev/stdout)
		proot_args+=(--bind=/proc/self/fd/2:/dev/stderr)
		proot_args+=(--bind=/sys)

		# Fake system data entries restricted by Android OS
		if [[ ! -r /proc/loadavg ]]; then
		    proot_args+=(--bind="${ROOTFS_DIRECTORY}"/proc/.loadavg:/proc/loadavg)
		fi
		if [[ ! -r /proc/stat ]]; then
		    proot_args+=(--bind="${ROOTFS_DIRECTORY}"/proc/.stat:/proc/stat)
		fi
		if [[ ! -r /proc/uptime ]]; then
		    proot_args+=(--bind="${ROOTFS_DIRECTORY}"/proc/.uptime:/proc/uptime)
		fi
		if [[ ! -r /proc/version ]]; then
		    proot_args+=(--bind="${ROOTFS_DIRECTORY}"/proc/.version:/proc/version)
		fi
		if [[ ! -r /proc/vmstat ]]; then
		    proot_args+=(--bind="${ROOTFS_DIRECTORY}"/proc/.vmstat:/proc/vmstat)
		fi
		if [[ ! -r /proc/sys/kernel/cap_last_cap ]]; then
		    proot_args+=(--bind="${ROOTFS_DIRECTORY}"/proc/.sysctl_entry_cap_last_cap:/proc/sys/kernel/cap_last_cap)
		fi

		# Fake battery stats
		if [[ ! -r /sys/class/power_supply/BAT0/uevent ]]; then
		    proot_args+=(--bind="${ROOTFS_DIRECTORY}"/sys/class/power_supply/BAT0/.uevent:/sys/class/power_supply/BAT0/uevent)
		fi

		# Bind /tmp to /dev/shm
		proot_args+=(--bind="${ROOTFS_DIRECTORY}"/tmp:/dev/shm)
		if [[ ! -d "${ROOTFS_DIRECTORY}/tmp" ]]; then
		    mkdir -p "${ROOTFS_DIRECTORY}"/tmp
		fi
		chmod 1777 "${ROOTFS_DIRECTORY}"/tmp &>/dev/null

		# Add host system specific files and directories
		if [[ ! \${isolated_env} ]]; then
		    for dir in /apex /data/app /data/dalvik-cache /data/misc/apexdata/com.android.art/dalvik-cache /product /system /vendor; do
		        if [[ ! -d \${dir} ]]; then
		            continue
		        fi
		        dir_mode=\$(stat --format='%a' "\${dir}")
		        if [[ \${dir_mode:2} =~ ^[157]$ ]]; then
		            proot_args+=("--bind=\${dir}")
		        fi
		    done

		    # Required by termux-api Android 11+
		    if [[ -e /linkerconfig/ld.config.txt ]]; then
		        proot_args+=(--bind=/linkerconfig/ld.config.txt)
		    fi

		    # Used by getprop
		    if [[ -f /property_contexts ]]; then
		        proot_args+=(--bind=/property_contexts)
		    fi

		    proot_args+=(--bind=/data/data/com.termux/cache)
		    proot_args+=(--bind=${TERMUX_FILES_DIR}/home)
		    proot_args+=(--bind=${TERMUX_FILES_DIR}/usr)

		    if [[ -d ${TERMUX_FILES_DIR}/apps ]]; then
		        proot_args+=(--bind=${TERMUX_FILES_DIR}/apps)
		    fi

		    if [[ -r /storage ]]; then
		        proot_args+=(--bind=/storage)
		        proot_args+=(--bind=/storage/emulated/0:/sdcard)
		    else
		        if [[ -r /storage/self/primary/ ]]; then
		            storage_path=/storage/self/primary
		        elif [[ -r /storage/emulated/0/ ]]; then
		            storage_path=/storage/emulated/0
		        elif [[ -r /sdcard/ ]]; then
		            storage_path=/sdcard
		        else
		            storage_path=
		        fi
		        if [[ \${storage_path} ]]; then
		            proot_args+=(--bind="\${storage_path}":/sdcard)
		            proot_args+=(--bind="\${storage_path}":/storage/emulated/0)
		            proot_args+=(--bind="\${storage_path}":/storage/self/primary)
		        fi
		    fi

		    if [[ \${EXTERNAL_STORAGE} ]]; then
		        proot_args+=(--bind="\${EXTERNAL_STORAGE}")
		    fi
		fi

		# Bind the tmp folder of the host system to the guest system (ignores --isolated)
		if [[ \${share_tmp} ]]; then
		    proot_args+=(--bind="\${TMPDIR:-${TERMUX_FILES_DIR}/usr/tmp}":/tmp)
		fi

		# Bind custom directories
		if [[ \${#custom_bindings} -gt 0 ]]; then
		    proot_args+=("\${custom_bindings[@]}")
		fi

		# Modify bindings to protected ports to use a higher port number.
		if [[ \${fix_ports} ]]; then
		    proot_args+=(-p)
		fi

		# Setup the default environment
		proot_args+=(/usr/bin/env -i "\${env_vars[@]}")

		# Enable audio support in distro (for root users, add option '--system')
		if ! pidof -q pulseaudio &>/dev/null; then
		    pulseaudio --start --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" --exit-idle-time=-1
		fi

		# Execute launch command
		exec proot "\${proot_args[@]}" "\${@}"
	EOF

	if ln -sfT "${DISTRO_LAUNCHER}" "${DISTRO_SHORTCUT}" &>>"${LOG_FILE}" && termux-fix-shebang "${DISTRO_LAUNCHER}" &>>"${LOG_FILE}" && chmod 700 "${DISTRO_LAUNCHER}" &>>"${LOG_FILE}"; then
		cursor -u1
		msg -ts "Created ${DISTRO_NAME} launcher"
	else
		cursor -u1
		msg -fq "Failed to create ${DISTRO_NAME} launcher"
	fi
}

################################################################################
# Creates a script used to launch the vnc server in the distro                 #
################################################################################
create_vnc_launcher() {
	msg -tn "Creating vnc wrapper..."

	local vnc_wrapper=${ROOTFS_DIRECTORY}/usr/local/bin/vnc
	mkdir -p "$(dirname "${vnc_wrapper}")" &>>"${LOG_FILE}" && cat >"${vnc_wrapper}" 2>>"${LOG_FILE}" <<-EOF
		#!/bin/bash

		################################################################################
		#                                                                              #
		# vnc wrapper                                                                  #
		#                                                                              #
		# This script starts the vnc server                                            #
		#                                                                              #
		# Copyright (C) 2023-2025  ${AUTHOR} <${GITHUB}>            #
		#                                                                              #
		################################################################################

		root_check() {
		    if [[ \${EUID} -eq 0 || \$(id -u) -eq 0 ]]; then
		        echo "Some applications may not work properly if you run as root."
		        read -r -p "Continue anyway? (y/N): " reply
		        if [[ \${reply} =~ ^(y|Y)$ ]]; then
		            return
		        fi
		        echo "Operation cancelled"
		        return 1
		    fi
		}

		clean_tmp() {
		    if [[ \${DISPLAY} ]]; then
		        rm -rf "\${TMPDIR}"/.X"\${DISPLAY}"-lock /tmp/.X11-unix/X"\${DISPLAY}"
		    fi
		}

		set_geometry() {
		    case "\${ORIENTATION}" in
		        p) geometry=\${HEIGHT}x\${WIDTH} ;;
		        *) geometry=\${WIDTH}x\${HEIGHT} ;;
		    esac
		}

		start_session() {
		    if [[ -e \${HOME}/.vnc/passwd || -e \${HOME}/.config/tigervnc/passwd ]]; then
		        export HOME=\${HOME}
		        export USER=\${USER}
		        LD_PRELOAD=${LIB_GCC_PATH}
		        vncserver "\${DISPLAY}" -geometry "\${geometry}" -depth "\${DEPTH}" "\${@}"
		    else
		        vncpasswd && start_session
		    fi
		}

		check_status() {
		    vncserver -list "\${@}"
		}

		kill_session() {
		    vncserver -clean -kill "\${DISPLAY}" "\${@}" && clean_tmp
		}

		print_usage() {
		    echo "Usage: \$(basename "\${0}") [COMMAND]"
		    echo
		    echo "Without any command, starts a new vnc session."
		    echo
		    echo "Commands:"
		    echo "  kill             Kill vnc session."
		    echo "  status           List active vnc sessions."
		    echo "  landscape        Use landscape (\${HEIGHT}x\${WIDTH}) orientation. (default)"
		    echo "  potrait          Use potrait (\${WIDTH}x\${HEIGHT}) orientation."
		    echo "  help             Print this message and exit."
		    echo
		    echo "Extra options are parsed to the installed vnc server, see vncserver(1)."
		}


		DEPTH=24
		WIDTH=1920
		HEIGHT=1200
		ORIENTATION=l

		while [[ \${#} -gt 0 ]]; do
		    case "\${1}" in
		        p | potrait)
		            ORIENTATION=p
		            ;;
		        l | landscape)
		            ORIENTATION=l
		            ;;
		        s | status)
		            action=s
		            ;;
		        k | kill)
		            action=k
		            ;;
		        h | help)
		            print_usage
		            exit
		            ;;
		        *) break ;;
		    esac
		    shift
		done

		if ! {
		    command -v vncserver && command -v vncpasswd
		} &>/dev/null; then
		    echo "No vnc server found."
		    exit 1
		fi

		case "\${action}" in
		    k) kill_session "\${@}" ;;
		    s) check_status "\${@}" ;;
		    *) root_check && clean_tmp && set_geometry && start_session "\${@}" ;;
		esac
	EOF

	if chmod 700 "${vnc_wrapper}" &>>"${LOG_FILE}"; then
		cursor -u1
		msg -ts "Created vnc wrapper"
	else
		cursor -u1
		msg -te "Failed to create vnc wrapper"
	fi
}


make_configurations() {
	msg -tn "Configuring ${DISTRO_NAME}..."

	local config status lines=1
	for config in sys_setup extra_setups env_setup; do
		status=$(${config} 2>>"${LOG_FILE}")

		if [[ ${status//-0/} ]]; then
			((lines++))
			msg -Nn
			msg -ne "${config//_/ } failed (${status})"
		fi
	done

	cursor -u"${lines}" -C
	msg -ts "Configured ${DISTRO_NAME}    "

	if [[ ${lines} -gt 1 ]]; then
		cursor -d"${lines}" -C
		echo
	fi
}

set_user_shell() {
	if [[ -x ${ROOTFS_DIRECTORY}/bin/chsh ]] && {
		if [[ ! ${1} ]]; then
			local default_shell=
			if [[ -f ${ROOTFS_DIRECTORY}/etc/passwd ]]; then
				default_shell=$(basename "$(grep -E "^${DEFAULT_LOGIN}:" "${ROOTFS_DIRECTORY}"/etc/passwd | awk -F: '{print $7}')")
			fi

			if [[ ! ${default_shell} ]]; then
				return
			fi

			ask -n -- -t "Change login shell? (${T}${default_shell}${P})"
		fi
	}; then
		local shell shells
		mapfile -t shells < <(sed -E '/^#.*/d; s:^/([a-z]+/)*::' <"${ROOTFS_DIRECTORY}"/etc/shells | sort -u)

		choose -t "Select new login shell" \
			"${shells[@]}"
		shell=${shells[((${?} - 1))]}

		msg -tn "Setting login shell to ${shell}..."

		if [[ -x ${ROOTFS_DIRECTORY}/bin/${shell} ]] && distro_exec /bin/chsh -s /usr/bin/"${shell}" "${DEFAULT_LOGIN}" &>>"${LOG_FILE}" && {
			if [[ ${DEFAULT_LOGIN} != root ]]; then
				distro_exec /bin/chsh -s /usr/bin/"${shell}" root &>>"${LOG_FILE}" || false
			fi
		}; then
			cursor -u1
			msg -ts "Login shell set to ${shell}"
		else
			cursor -u1
			msg -te "Failed to set login shell to ${shell}"

			if ask -y "Try again?"; then
				cursor -u7
				set_user_shell -q
			fi
		fi
	fi
}

set_zone_info() {
	if [[ -x ${ROOTFS_DIRECTORY}/bin/ln ]] && {
		if [[ ! ${1} ]]; then
			local default_localtime=
			if [[ -e ${ROOTFS_DIRECTORY}/etc/timezone ]]; then
				default_localtime=$(cat "${ROOTFS_DIRECTORY}"/etc/timezone 2>>"${LOG_FILE}")
			fi

			if [[ ! ${default_localtime} ]]; then
				default_localtime=unknown
				ask -y -- -t "Change local time? (${T}${default_localtime}${P})"
			else
				ask -n -- -t "Change local time? (${T}${default_localtime}${P})"
			fi
		fi
	}; then
		msg -t "Input new local time"
		msg -n

		local zone
		read -r -e -p "${S}▶${P} " -i "$(getprop persist.sys.timezone Etc/UTC 2>>"${LOG_FILE}")" zone

		if [[ ${zone} && -f ${ROOTFS_DIRECTORY}/usr/share/zoneinfo/${zone} ]] && rm -f "${ROOTFS_DIRECTORY}"/etc/timezone &>>"${LOG_FILE}" && echo "${zone}" >"${ROOTFS_DIRECTORY}"/etc/timezone 2>>"${LOG_FILE}" && distro_exec /bin/ln -sfT /usr/share/zoneinfo/"${zone}" /etc/localtime 2>>"${LOG_FILE}"; then
			msg -ts "Local time set to ${zone}"
		else
			msg -te "Failed to set local time to ${zone:-empty text}"
			if ask -y "Try again?"; then
				cursor -u7
				set_zone_info -q
			fi
		fi
	fi
}

prompt_cleanup() {
	if [[ ! "${KEEP_ROOTFS_DIRECTORY}" && ! "${KEEP_ROOTFS_ARCHIVE}" && -f "${ARCHIVE_NAME}" ]]; then
		if ask -y -- -t "Remove rootfs archive?"; then
			msg -tn "Removing rootfs archive..."

			if remove "${ARCHIVE_NAME}" &>>"${LOG_FILE}"; then
				cursor -u1
				msg -st "Rootfs archive removed"
			else
				cursor -u1
				msg -te "Failed to remove rootfs archive"
			fi
		fi
	fi
}

show_complete_msg() {
	msg -st "${DISTRO_NAME} ${main_action}ation complete"
	msg

	local args=(-t "What's next?")
	local launcher=$(basename "${DISTRO_LAUNCHER}")

	args+=(
		""
		"  ${S}●${P} Login as ${DEFAULT_LOGIN}"
		"       ${T}${launcher}${P}")

	if [[ ${DEFAULT_LOGIN} != root ]]; then
		args+=(
			""
			"  ${S}●${P} Login as root"
			"       ${T}${launcher} root${P}"
		)
	fi

	if [[ ${DE_INSTALLED} ]]; then
		args+=(
			""
			"  ${S}●${P} Start Desktop"
			"      ${S}1.${P} ${T}${launcher}${P}"
			""
			"      ${S}2.${P} ${T}vnc${P}"
			""
			"      ${S}3.${P} Open vnc viewer"
			""
			"      ${S}4.${P} Type in vnc viewer"
			"          Name: ${T}${DISTRO_NAME} Desktop${P}"
			"          Host: ${T}localhost${P}"
			"          Port: ${T}5900${P}")
	fi

	args+=(
		""
		"For more information, visit"
		"${S}${SU}${GITHUB}/${DISTRO_REPOSITORY}${RU}${P}"
	)

	box "${args[@]}"
	msg -f "You're all set!"
}

uninstall_rootfs() {
	if [[ -d ${ROOTFS_DIRECTORY} && $(ls -UA "${ROOTFS_DIRECTORY}") ]]; then
		msg -h "Uninstalling ${DISTRO_NAME} from"
		msg "${T}${ROOTFS_DIRECTORY}${P}"

		if ask -n -- -t "Confirm action"; then
			msg -fn "Uninstalling ${DISTRO_NAME}..."

			if remove "${ROOTFS_DIRECTORY}" "${DISTRO_LAUNCHER}" "${DISTRO_SHORTCUT}" &>>"${LOG_FILE}"; then
				cursor -u1
				msg -fs "${DISTRO_NAME} uninstalled"
			else
				cursor -u1
				msg -fq "Failed to uninstall ${DISTRO_NAME}"
			fi
		else
			msg -fqm2
		fi
	else
		msg -aq "No rootfs found in ${ROOTFS_DIRECTORY}"
	fi
}

print_version() {
	echo "${PROGRAM_NAME} version ${VERSION_NAME}"
	echo "Copyright (C) 2023-2025 ${AUTHOR} <${GITHUB}>."
	echo "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>."
	echo
	echo "This is free software, you are free to change and redistribute it."
	echo "There is NO WARRANTY, to the extent permitted by law."
}

print_usage() {
	echo "Usage: ${PROGRAM_NAME} [OPTION] [DIRECTORY]"
	echo
	echo "Install ${DISTRO_NAME} in DIRECTORY"
	echo "(default=${DEFAULT_ROOTFS_DIR})"
	echo
	echo "OPTIONS:"
	echo "  -d, --directory PATH   Change directory to PATH before execution."
	echo "      --install-only     Installation only (use with caution)."
	echo "      --config-only      Configurations only (if already installed)."
	echo "  -u, --uninstall        Uninstall ${DISTRO_NAME}."
	echo "      --color WHEN       Enable/Disable color output if supported"
	echo "                         (default=on). Valid arguments are:"
	echo "                         [always|on] or [never|off]"
	echo "  -l, --log              Log error messages to ${PROGRAM_NAME%.sh}.log."
	echo "  -v, --version          Print program version and exit."
	echo "  -h, --help             Print help message and exit."
	echo
	echo "NOTE: The install directory must be within ${TERMUX_FILES_DIR} (or any of its sub-directories) to prevent permission issues."
	echo
	echo "For more information, visit:"
	echo "⇒ ${GITHUB}/${DISTRO_REPOSITORY}"
}

sys_setup() {
	local status=

	local dir
	for dir in proc sys sys/.empty sys/class/power_supply/BAT0; do
		if [[ ! -e ${ROOTFS_DIRECTORY}/${dir} ]]; then
			mkdir -p "${ROOTFS_DIRECTORY}/${dir}"
		fi

		chmod 700 "${ROOTFS_DIRECTORY}/${dir}"
	done

	if [[ ! -f ${ROOTFS_DIRECTORY}/proc/.loadavg ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/proc/.loadavg
			0.12 0.07 0.02 2/165 765
		EOF
	fi
	status+=-${?}

	if ! [[ -f ${ROOTFS_DIRECTORY}/proc/.stat ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/proc/.stat
			cpu  1957 0 2877 93280 262 342 254 87 0 0
			cpu0 31 0 226 12027 82 10 4 9 0 0
			cpu1 45 0 664 11144 21 263 233 12 0 0
			cpu2 494 0 537 11283 27 10 3 8 0 0
			cpu3 359 0 234 11723 24 26 5 7 0 0
			cpu4 295 0 268 11772 10 12 2 12 0 0
			cpu5 270 0 251 11833 15 3 1 10 0 0
			cpu6 430 0 520 11386 30 8 1 12 0 0
			cpu7 30 0 172 12108 50 8 1 13 0 0
			intr 127541 38 290 0 0 0 0 4 0 1 0 0 25329 258 0 5777 277 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
			ctxt 140223
			btime 1680020856
			processes 772
			procs_running 2
			procs_blocked 0
			softirq 75663 0 5903 6 25375 10774 0 243 11685 0 21677
		EOF
	fi
	status+=-${?}

	if [[ ! -f ${ROOTFS_DIRECTORY}/proc/.uptime ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/proc/.uptime
			5400.0 0.0
		EOF
	fi
	status+=-${?}

	if [[ ! -f ${ROOTFS_DIRECTORY}/proc/.version ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/proc/.version
			Linux version ${KERNEL_RELEASE} (proot@termux) (gcc (GCC) 12.2.1 20230201, GNU ld (GNU Binutils) 2.40) #1 SMP PREEMPT_DYNAMIC Wed, 01 Mar 2023 00:00:00 +0000
		EOF
	fi
	status+=-${?}

	if [[ ! -f ${ROOTFS_DIRECTORY}/proc/.vmstat ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/proc/.vmstat
			nr_free_pages 1743136
			nr_zone_inactive_anon 179281
			nr_zone_active_anon 7183
			nr_zone_inactive_file 22858
			nr_zone_active_file 51328
			nr_zone_unevictable 642
			nr_zone_write_pending 0
			nr_mlock 0
			nr_bounce 0
			nr_zspages 0
			nr_free_cma 0
			numa_hit 1259626
			numa_miss 0
			numa_foreign 0
			numa_interleave 720
			numa_local 1259626
			numa_other 0
			nr_inactive_anon 179281
			nr_active_anon 7183
			nr_inactive_file 22858
			nr_active_file 51328
			nr_unevictable 642
			nr_slab_reclaimable 8091
			nr_slab_unreclaimable 7804
			nr_isolated_anon 0
			nr_isolated_file 0
			workingset_nodes 0
			workingset_refault_anon 0
			workingset_refault_file 0
			workingset_activate_anon 0
			workingset_activate_file 0
			workingset_restore_anon 0
			workingset_restore_file 0
			workingset_nodereclaim 0
			nr_anon_pages 7723
			nr_mapped 8905
			nr_file_pages 253569
			nr_dirty 0
			nr_writeback 0
			nr_writeback_temp 0
			nr_shmem 178741
			nr_shmem_hugepages 0
			nr_shmem_pmdmapped 0
			nr_file_hugepages 0
			nr_file_pmdmapped 0
			nr_anon_transparent_hugepages 1
			nr_vmscan_write 0
			nr_vmscan_immediate_reclaim 0
			nr_dirtied 0
			nr_written 0
			nr_throttled_written 0
			nr_kernel_misc_reclaimable 0
			nr_foll_pin_acquired 0
			nr_foll_pin_released 0
			nr_kernel_stack 2780
			nr_page_table_pages 344
			nr_sec_page_table_pages 0
			nr_swapcached 0
			pgpromote_success 0
			pgpromote_candidate 0
			nr_dirty_threshold 356564
			nr_dirty_background_threshold 178064
			pgpgin 890508
			pgpgout 0
			pswpin 0
			pswpout 0
			pgalloc_dma 272
			pgalloc_dma32 261
			pgalloc_normal 1328079
			pgalloc_movable 0
			pgalloc_device 0
			allocstall_dma 0
			allocstall_dma32 0
			allocstall_normal 0
			allocstall_movable 0
			allocstall_device 0
			pgskip_dma 0
			pgskip_dma32 0
			pgskip_normal 0
			pgskip_movable 0
			pgskip_device 0
			pgfree 3077011
			pgactivate 0
			pgdeactivate 0
			pglazyfree 0
			pgfault 176973
			pgmajfault 488
			pglazyfreed 0
			pgrefill 0
			pgreuse 19230
			pgsteal_kswapd 0
			pgsteal_direct 0
			pgsteal_khugepaged 0
			pgdemote_kswapd 0
			pgdemote_direct 0
			pgdemote_khugepaged 0
			pgscan_kswapd 0
			pgscan_direct 0
			pgscan_khugepaged 0
			pgscan_direct_throttle 0
			pgscan_anon 0
			pgscan_file 0
			pgsteal_anon 0
			pgsteal_file 0
			zone_reclaim_failed 0
			pginodesteal 0
			slabs_scanned 0
			kswapd_inodesteal 0
			kswapd_low_wmark_hit_quickly 0
			kswapd_high_wmark_hit_quickly 0
			pageoutrun 0
			pgrotated 0
			drop_pagecache 0
			drop_slab 0
			oom_kill 0
			numa_pte_updates 0
			numa_huge_pte_updates 0
			numa_hint_faults 0
			numa_hint_faults_local 0
			numa_pages_migrated 0
			pgmigrate_success 0
			pgmigrate_fail 0
			thp_migration_success 0
			thp_migration_fail 0
			thp_migration_split 0
			compact_migrate_scanned 0
			compact_free_scanned 0
			compact_isolated 0
			compact_stall 0
			compact_fail 0
			compact_success 0
			compact_daemon_wake 0
			compact_daemon_migrate_scanned 0
			compact_daemon_free_scanned 0
			htlb_buddy_alloc_success 0
			htlb_buddy_alloc_fail 0
			cma_alloc_success 0
			cma_alloc_fail 0
			unevictable_pgs_culled 27002
			unevictable_pgs_scanned 0
			unevictable_pgs_rescued 744
			unevictable_pgs_mlocked 744
			unevictable_pgs_munlocked 744
			unevictable_pgs_cleared 0
			unevictable_pgs_stranded 0
			thp_fault_alloc 13
			thp_fault_fallback 0
			thp_fault_fallback_charge 0
			thp_collapse_alloc 4
			thp_collapse_alloc_failed 0
			thp_file_alloc 0
			thp_file_fallback 0
			thp_file_fallback_charge 0
			thp_file_mapped 0
			thp_split_page 0
			thp_split_page_failed 0
			thp_deferred_split_page 1
			thp_split_pmd 1
			thp_scan_exceed_none_pte 0
			thp_scan_exceed_swap_pte 0
			thp_scan_exceed_share_pte 0
			thp_split_pud 0
			thp_zero_page_alloc 0
			thp_zero_page_alloc_failed 0
			thp_swpout 0
			thp_swpout_fallback 0
			balloon_inflate 0
			balloon_deflate 0
			balloon_migrate 0
			swap_ra 0
			swap_ra_hit 0
			ksm_swpin_copy 0
			cow_ksm 0
			zswpin 0
			zswpout 0
			direct_map_level2_splits 29
			direct_map_level3_splits 0
			nr_unstable 0
		EOF
	fi
	status+=-${?}

	if [[ ! -f ${ROOTFS_DIRECTORY}/proc/.sysctl_entry_cap_last_cap ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/proc/.sysctl_entry_cap_last_cap
			40
		EOF
	fi
	status+=-${?}

	if [[ ! -f ${ROOTFS_DIRECTORY}/proc/.sysctl_inotify_max_user_watches ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/proc/.sysctl_inotify_max_user_watches
			4096
		EOF
	fi
	status+=-${?}

	if [[ ! -f ${ROOTFS_DIRECTORY}/sys/class/power_supply/BAT0/.uevent ]]; then
		cat <<-EOF >"${ROOTFS_DIRECTORY}"/sys/class/power_supply/BAT0/.uevent
			POWER_SUPPLY_NAME=BAT0
			POWER_SUPPLY_TYPE=Battery
			POWER_SUPPLY_PRESENT=1
			POWER_SUPPLY_STATUS=Discharging
			POWER_SUPPLY_HEALTH=Good
			POWER_SUPPLY_TECHNOLOGY=Li-ion
			POWER_SUPPLY_CAPACITY=75
			POWER_SUPPLY_CAPACITY_LEVEL=Normal
			POWER_SUPPLY_VOLTAGE_NOW=11500000
			POWER_SUPPLY_CURRENT_NOW=900000
			POWER_SUPPLY_CHARGE_NOW=3750000
			POWER_SUPPLY_CHARGE_FULL=5000000
			POWER_SUPPLY_CHARGE_FULL_DESIGN=5200000
			POWER_SUPPLY_CYCLE_COUNT=85
			POWER_SUPPLY_TEMP=320
			POWER_SUPPLY_MODEL_NAME=BAT-Generic
			POWER_SUPPLY_MANUFACTURER=OpenPower
			POWER_SUPPLY_SERIAL_NUMBER=1234567890
			POWER_SUPPLY_TIME_TO_EMPTY_NOW=5400
			POWER_SUPPLY_TIME_TO_FULL_NOW=1800
		EOF
	fi
	status+=-${?}

	echo -n "${status}"
}

env_setup() {
	local status=
	local marker="${PROGRAM_NAME} variables"

	local env_file=${ROOTFS_DIRECTORY}/etc/environment
	sed -i "/^### start\s${marker}\s###$/,/^###\send\s${marker}\s###$/d; /^$/d" "${env_file}"
	{
		echo -e "\n### start ${marker} ###"
		echo -e "# These variables were added by ${PROGRAM_NAME} during"
		echo -e "# the rootfs installation/configuration and are updated"
		echo -e "# automatically every time ${PROGRAM_NAME} is executed.\n"

		# Posix syntax only
		cat >>"${env_file}" <<-EOF
			# Environment variables
			export PATH=${DEFAULT_PATH}:${TERMUX_FILES_DIR}/usr/local/bin:${TERMUX_FILES_DIR}/usr/bin
			export TERM=${TERM:-xterm-256color}

			if [ -z "\${LANG}" ]; then
			    export LANG=en_US.UTF-8
			fi

			# pulseaudio server
			export PULSE_SERVER=127.0.0.1

			# vncserver display
			export DISPLAY=:0

			# Misc variables
			export MOZ_FAKE_NO_SANDBOX=1
			export TMPDIR=/tmp
		EOF
	} >>"${env_file}"
	status+=-${?}

	echo -e "\n# Host system variables" >>"${env_file}"
	local var
	for var in COLORTERM ANDROID_DATA ANDROID_ROOT ANDROID_ART_ROOT ANDROID_I18N_ROOT ANDROID_RUNTIME_ROOT ANDROID_TZDATA_ROOT BOOTCLASSPATH DEX2OATBOOTCLASSPATH; do
		if [[ ${!var} ]]; then
			echo "export ${var}=${!var}" >>"${env_file}"
		fi
	done
	status+=-${?}

	echo -e "\n### end ${marker} ###\n" >>"${env_file}"

	# local f
	# for f in /etc/bash.bashrc /etc/profile; do # /etc/login.defs
	# 	if [[ ! -e ${ROOTFS_DIRECTORY}${f} ]]; then
	# 		continue
	# 	fi

	# 	sed -i -E "s@\<(PATH=)(\"?[^\"[:space:]]+(\"|\$|\>))@\1\"${DEFAULT_PATH}\"@g" "${ROOTFS_DIRECTORY}${f}"
	# done
	# status+=-${?}

	echo -n "${status}"
}

ids_setup() {
	local status=

	chmod u+rw "${ROOTFS_DIRECTORY}"/etc/{passwd,shadow,group,gshadow} &>>"${LOG_FILE}"
	status+=-${?}

	if ! grep -qe ':Termux:/:/sbin/nologin' "${ROOTFS_DIRECTORY}"/etc/passwd; then
		echo "aid_$(id -un):x:$(id -u):$(id -g):Termux:/:/sbin/nologin" >>"${ROOTFS_DIRECTORY}"/etc/passwd
	fi
	status+=-${?}

	if ! grep -qe ':18446:0:99999:7:' "${ROOTFS_DIRECTORY}"/etc/shadow; then
		echo "aid_$(id -un):*:18446:0:99999:7:::" >>"${ROOTFS_DIRECTORY}"/etc/shadow
	fi
	status+=-${?}

	local group_name group_id
	while read -r group_name group_id; do
		if ! grep -qe "${group_name}" "${ROOTFS_DIRECTORY}"/etc/group; then
			echo "aid_${group_name}:x:${group_id}:root,aid_$(id -un)" >>"${ROOTFS_DIRECTORY}"/etc/group
		fi

		if ! grep -qe "${group_name}" "${ROOTFS_DIRECTORY}"/etc/gshadow; then
			echo "aid_${group_name}:*::root,aid_$(id -un)" >>"${ROOTFS_DIRECTORY}"/etc/gshadow
		fi
	done < <(paste <(id -Gn | tr ' ' '\n') <(id -G | tr ' ' '\n'))
	status+=-${?}

	echo -n "${status}"
}


extra_setups() {
	local status=

	if [[ -f ${ROOTFS_DIRECTORY}/root/.bash_profile ]]; then
		sed -i '/^if/,/^fi/d' "${ROOTFS_DIRECTORY}"/root/.bash_profile
	fi
	status+=-${?}

	if [[ -x ${ROOTFS_DIRECTORY}/bin/passwd ]]; then
		distro_exec /bin/passwd -d root
		if [[ ${DEFAULT_LOGIN} != root ]]; then
			distro_exec /bin/passwd -d "${DEFAULT_LOGIN}"
		fi
	fi &>>"${LOG_FILE}"
	status+=-${?}

	local dir="${ROOTFS_DIRECTORY}"/bin
	if [[ -x ${dir}/sudo ]]; then
		chmod +s "${dir}"/sudo

		if [[ ${DEFAULT_LOGIN} != root ]]; then
			echo "${DEFAULT_LOGIN}   ALL=(ALL:ALL) NOPASSWD: ALL" >"${ROOTFS_DIRECTORY}"/etc/sudoers.d/"${DEFAULT_LOGIN}"
		fi

		echo "Set disable_coredump false" >"${ROOTFS_DIRECTORY}"/etc/sudo.conf
	fi

	if [[ -x ${dir}/su ]]; then
		chmod +s "${dir}"/su
	fi
	status+=-${?}

	local resolv_conf=${ROOTFS_DIRECTORY}/etc/resolv.conf
	remove "${resolv_conf}"

	if [[ ${PREFIX} && -f ${PREFIX}/etc/resolv.conf ]]; then
		cp "${PREFIX}"/etc/resolv.conf "${resolv_conf}"
	elif touch "${resolv_conf}" && chmod +w "${resolv_conf}"; then
		cat >"${resolv_conf}" <<-EOF
			nameserver 8.8.8.8
			nameserver 8.8.4.4
		EOF
	fi
	status+=-${?}

	cat >"${ROOTFS_DIRECTORY}"/etc/hosts <<-EOF
		# IPv4
		127.0.0.1   localhost.localdomain localhost

		# IPv6
		::1         localhost.localdomain localhost ip6-localhost ip6-loopback
		fe00::0     ip6-localnet
		ff00::0     ip6-mcastprefix
		ff02::1     ip6-allnodes
		ff02::2     ip6-allrouters
		ff02::3     ip6-allhosts
	EOF
	status+=-${?}

	echo -n "${status}"
}


distro_exec() {
	unset LD_PRELOAD
	proot -L \
		--cwd=/ \
		--root-id \
		--bind=/dev \
		--bind=/dev/urandom:/dev/random \
		--bind=/proc \
		--bind=/proc/self/fd:/dev/fd \
		--bind=/proc/self/fd/0:/dev/stdin \
		--bind=/proc/self/fd/1:/dev/stdout \
		--bind=/proc/self/fd/2:/dev/stderr \
		--bind=/sys \
		--bind="${ROOTFS_DIRECTORY}"/proc/.loadavg:/proc/loadavg \
		--bind="${ROOTFS_DIRECTORY}"/proc/.stat:/proc/stat \
		--bind="${ROOTFS_DIRECTORY}"/proc/.uptime:/proc/uptime \
		--bind="${ROOTFS_DIRECTORY}"/proc/.version:/proc/version \
		--bind="${ROOTFS_DIRECTORY}"/proc/.vmstat:/proc/vmstat \
		--bind="${ROOTFS_DIRECTORY}"/proc/.sysctl_entry_cap_last_cap:/proc/sys/kernel/cap_last_cap \
		--bind="${ROOTFS_DIRECTORY}"/proc/.sysctl_inotify_max_user_watches:/proc/sys/fs/inotify/max_user_watches \
		--bind="${ROOTFS_DIRECTORY}"/sys/.empty:/sys/fs/selinux \
		--kernel-release="${KERNEL_RELEASE}" \
		--rootfs="${ROOTFS_DIRECTORY}" \
		--link2symlink \
		--kill-on-exit \
		/bin/env -i \
		HOME=/root \
		LANG=C.UTF-8 \
		PATH="${DEFAULT_PATH}" \
		TERM="${TERM:-xterm-256color}" \
		TMPDIR=/tmp \
		"${@}"
}


animation() {
	local frames=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
	local interval=0.1
	local start=1

	while getopts ":s" opt; do
		case "${opt}" in
			s)
				start=
				continue
				;;
			*) ;;
		esac
	done
	shift $((OPTIND - 1))
	unset OPTARG OPTIND opt

	_animate() {
		local frame
		while true; do
			for frame in "${frames[@]}"; do
				printf " ${T}%s${P}\b\b" "${frame}"
				sleep "${interval}"
			done
		done
	}

	if [[ ${start} ]]; then
		local pid_file=$(mktemp --tmpdir) && {
			(
				stty -echo
				printf "${HC}"
				_animate "${@}" &
				printf "%s" "${!}" >"${pid_file}"
			)
			ANIM_PID=$(cat "${pid_file}")
			rm -f "${pid_file}"
		}
	else
		local ifs_old=${IFS}
		local tty_settings=$(stty -g)
		
		stty -icanon -isig
		while IFS= read -r -n 1 -t 0.01 _; do
			:
		done
		stty "${tty_settings}"
		IFS=${ifs_old}

		printf "${RC}"
		stty echo

		if [[ ${ANIM_PID} ]]; then
			kill "${ANIM_PID}" &>>"${LOG_FILE}"
			ANIM_PID=
		fi
	fi
}


remove() {
	chmod 777 -R -- "${@}"
	rm -rf -- "${@}"
}


colors() {
	if [[ ${ENABLE_COLOR} ]]; then
		N=$'\e[0m'  # reset
		R=$'\e[91m' # red
		G=$'\e[92m' # green
		Y=$'\e[93m' # yellow
		B=$'\e[94m' # blue
		M=$'\e[95m' # magenta
		C=$'\e[96m' # cyan
		W=$'\e[97m' # white
		P=${N}      # primary color
		S=${N}      # secondary color
		T=${Y}      # tertiary color
	else
		N=
		R=
		G=
		Y=
		B=
		M=
		C=
		W=
		P=
		S=
		T=
	fi

	HC=$'\e[?25l' # hide cursor
	RC=$'\e[?25h' # reset cursor
	SU=$'\e[4m'   # show underline
	RU=$'\e[24m'  # reset underline
	SV=$'\e[7m'   # reverse video
	RV=$'\e[27m'  # reset video
}


buffer() {
	local show=
	local hide=
	local info=
	local count=

	while getopts ":shi0123456789" opt; do
		case "${opt}" in
			s)
				show=1
				continue
				;;
			h)
				hide=1
				continue
				;;
			i)
				info=1
				continue
				;;
			[0-9])
				count=${opt}
				continue
				;;
			*) ;;
		esac
	done
	shift $((OPTIND - 1))
	unset OPTARG OPTIND opt

	if [[ ${show} ]]; then
		# '\e[?1049h': Use alternative screen buffer
		# '\e[?25l':   Hide the cursor
		# '\e[2J':     Clear the screen
		# '\e[1;%sr':  Limit scrolling area
		#              Also sets cursor to (0,0)
		printf "\e[?1049h\e[?25l\e[2J\e[1;%sr" "$((TERM_HEIGHT - 1))"
		stty -echo
	fi

	if [[ ${info} ]]; then
		local line=${*}
		local width=$((TERM_WIDTH - 1))

		# '\e7':       Save cursor position (more widely supported than '\e[s')
		# '\e[%sH':    Move cursor to bottom of the terminal
		# '%-*s':      Align string left and pad with spaces
		# '\e8':       Restore cursor position (more widely supported than '\e[u')
		printf "\e7\e[%sH${SV}%-*s\e8${RV}${N}" \
			"${TERM_HEIGHT}" \
			"${TERM_WIDTH}" \
			" ${line:0:${width}}"
	fi

	if [[ ${hide} ]]; then
		local ifs_old=${IFS}
		local tty_settings=$(stty -g)
		# -isig:     Disable processing of INTR, QUIT, SUSP characters (e.g., Ctrl+C, Ctrl+Z)
		stty -isig

		if [[ ${count} ]]; then
			if [[ ${count} ]]; then
				while [[ ${count} -gt 0 ]]; do
					buffer -i "Closing in ${count}s"
					sleep 1
					((count--))
				done
			fi
		fi

		# -icanon:   Disable canonical (line-buffered) input (Input is read character by character)
		stty -icanon
		while IFS= read -r -n 1 -t 0.01 _; do
			:
		done

		stty "${tty_settings}"
		IFS=${ifs_old}

		# '\e[2J':    Clear the terminal
		# '\e[;r':    Set the scroll region to its default value
		#             Also sets cursor to (0,0)
		# '\e[?1049l: Restore main screen buffer
		# '\e[?25h':  Unhide the cursor
		printf "\e[2J\e[;r\e[?1049l\e[?25h"
		stty echo
	fi
}


cursor() {
	local up=
	local down=
	local right=
	local left=
	local clear=1

	while getopts ":u:d:r:l:C" opt; do
		case "${opt}" in
			u)
				up=${OPTARG}
				continue
				;;
			d)
				down=${OPTARG}
				continue
				;;
			r)
				right=${OPTARG}
				continue
				;;
			l)
				left=${OPTARG}
				continue
				;;
			C)
				clear=
				continue
				;;
			*) ;;
		esac
	done
	shift $((OPTIND - 1))
	unset OPTARG OPTIND opt

	if [[ ${up} ]]; then
		printf "\r\e[%sA" "${up}"
	fi

	if [[ ${down} ]]; then
		printf "\r\e[%sB" "${down}"
	fi

	if [[ ${right} ]]; then
		printf "\r\e[%sC" "${right}"
	fi

	if [[ ${left} ]]; then
		printf "\r\e[%sD" "${left}"
	fi

	if [[ ${clear} ]]; then
		printf "\e[0J"
	fi
}


choose() {
	local title=
	local message=
	local selected=1

	while getopts ":t:m:d:" opt; do
		case "${opt}" in
			t)
				title=${OPTARG}
				continue
				;;
			m)
				message=${OPTARG}
				continue
				;;

			d)
				selected=${OPTARG}
				continue
				;;
			*) ;;
		esac
	done
	shift $((OPTIND - 1))
	unset OPTARG OPTIND opt

	if [[ ${title} ]]; then
		msg -t "${title}"
	fi

	if [[ ${message} ]]; then
		msg "${message}"
	fi

	_list() {
		msg -l"${selected}" "${@}" "Quit"
		msg -fn "Use ↑/k (Up), ↓/j (Down), Space/Enter (Select)"
	}

	_reset() {
		if [[ ${2} ]]; then
			cursor -u$((${1} + 2))
			printf "${RC}"
			stty echo
			trap - INT
		else
			cursor -u$((${1} + 2)) -C
		fi
	}

	_list "${@}"
	stty -echo
	printf "${HC}"
	trap 'printf "${RC}\n"; stty echo; exit 130' INT

	local choice quit
	quit=$((${#} + 1))
	while true; do
		read -rsn 1 choice
		if [[ ! ${choice} || ${choice} == " " ]] && [[ ${selected} -gt 0 ]]; then
			choice=${selected}
		elif [[ ${choice} == $'\e' ]]; then
			read -rsn 2 choice
		fi

		case "${choice,,}" in
			[1-${#}])
				_reset "${#}" -
				msg "${!choice}"
				return "${choice}"
				;;
			q | "${quit}")
				_reset "${#}" -
				msg "Quit"
				msg -fqm2
				;;
			k | j | "[a" | "[b")
				if [[ ${choice} == "[A" || ${choice} == k ]]; then
					((selected--))
				elif [[ ${choice} == "[B" || ${choice} == j ]]; then
					((selected++))
				fi

				if [[ ${selected} -lt 1 ]]; then
					selected=1
					continue
				fi

				if [[ ${selected} -gt ${quit} ]]; then
					selected=${quit}
					continue
				fi

				_reset ${#}
				_list "${@}"
				continue
				;;
			*) ;;
		esac
	done
}

################################################################################
# Prints parsed message to the standard output (all messages MUST be printed   #
# using this function)                                                         #
#                                                                              #
# Args:                                                                        #
#     OPTIONS (see case inside)                                                #
#     Message to be printed                                                    #
################################################################################
msg() {
	local color=${P}
	local prefix="${S}│${N}  "
	local quit=
	local append=
	local extra_msg=
	local highlight_item=0
	local list_items=
	local lead_newline=
	local trail_newline='\n'
	local extra_msgs=(
		"Active internet connection required"
		"See '${PROGRAM_NAME} --help' for more information"
		"Operation cancelled"
	)
	local success=
	local title=

	while getopts ":hftseanNqm:l0123456789" opt; do
		case "${opt}" in
			h)
				prefix="${S}┌${N}  "
				;;
			f)
				prefix="${S}│${N}\n${S}└${N}  "
				;;
			t)
				title=1
				prefix="${S}│${N}\n${S}◇${N}  "
				continue
				;;
			s)
				success=1
				color=${G}
				continue
				;;
			e)
				color=${R}
				continue
				;;
			a)
				append=1
				continue
				;;
			n)
				trail_newline=
				continue
				;;
			N)
				lead_newline='\n'
				continue
				;;
			q)
				quit=1
				color=${R}
				continue
				;;
			m)
				extra_msg=${P}${extra_msgs[${OPTARG}]}${N}
				continue
				;;
			l)
				list_items=1
				continue
				;;
			[0-9])
				highlight_item=${opt}
				continue
				;;
			*) ;;
		esac
	done
	shift $((OPTIND - 1))
	unset OPTARG OPTIND opt

	if [[ ${success} && ${title} ]]; then
		prefix="${S}│${N}\n${S}◆${N}  "
	fi

	if [[ ${list_items} ]]; then
		local i=1
		local item
		for item in "${@}"; do
			if [[ ${i} -eq ${highlight_item} ]]; then
				printf "\r${prefix}  ${S}●${N} ${color}%s${N}\n" "${item}"
			else
				printf "\r${prefix}  ${S}○${N} ${color}%s${N}\n" "${item}"
			fi

			((i++))
		done
	else
		local message=${*}
		if [[ ! ${message} && ${extra_msg} ]]; then
			message=${extra_msg}
			extra_msg=
		fi

		while true; do
			if [[ ${append} ]]; then
				printf "${lead_newline}${color}%s${N}${trail_newline}" "${message}"
			else
				printf "\r${prefix}${lead_newline}${color}%s${N}${trail_newline}" "${message}"
			fi

			if [[ ${extra_msg} ]]; then
				message=${extra_msg}
				extra_msg=
			else
				break
			fi
		done
	fi

	if [[ ${quit} ]]; then
		exit 1
	fi
}


box() {
	local header=
	local footer=
	local start_prefix="├──"
	local end_prefix="├──"

	while getopts ":t:h:f:" opt; do
		case "${opt}" in
			h)
				header=${OPTARG}
				start_prefix="${S}┌${N}  "
				;;
			t)
				header=${OPTARG}
				start_prefix="${S}◇${N}  "
				;;
			f)
				footer=${OPTARG}
				end_prefix="${S}└${N}  "
				;;
			*) ;;
		esac
	done
	shift $((OPTIND - 1))
	unset OPTARG OPTIND opt

	local width sep i line
	width=$((TERM_WIDTH - 5))

	sep=
	for ((i = width; i > 0; i--)); do
		sep+=─
	done

	if [[ ${header} ]]; then
		header=${header:0:$((width - 1))}
		header+=" "
	fi

	if [[ ${footer} ]]; then
		footer=${footer:0:$((width - 1))}
		footer+=" "
	fi

	printf "\r${S}${start_prefix}${P}${header}${S}%s─${N}" "${sep:${#header}}"
	printf "%s\n" "${@}" | fmt -sw "${width}" -g "${width}" | sed 's/^/ /' |
		while read -r line; do
			printf "\n${S}│${N}  ${P}%-*s${N} ${S}" "$((width + 2))" "${line}"
		done | sed 's/ //'
	printf "\n${S}${end_prefix}${P}${footer}${S}%s─${N}\n" "${sep:${#footer}}"
}


ask() {
	local selected=n

	while getopts ":yn" opt; do
		case "${opt}" in
			y | n)
				selected=${opt}
				continue
				;;
			*) ;;
		esac
	done
	shift $((OPTIND - 1))
	unset OPTARG OPTIND opt

	if [[ ${*} ]]; then
		msg "${@}"
	fi

	_msg() {
		case "${selected}" in
			y) msg "  ${S}●${N} Yes   ${S}○${N} No   ${S}○${N} Quit" ;;
			n) msg "  ${S}○${N} Yes   ${S}●${N} No   ${S}○${N} Quit" ;;
			*) msg "  ${S}○${N} Yes   ${S}○${N} No   ${S}●${N} Quit" ;;
		esac

		msg -fn "Use ←/h (Left), →/l (Right), Space/Enter (Select)"
	}

	_reset() {
		if [[ ${1} ]]; then
			cursor -u2
			printf "${RC}"
			stty echo
			trap - INT
		else
			cursor -u2 -C
		fi
	}

	_msg
	stty -echo
	printf "${HC}"
	trap 'printf "${RC}\n"; stty echo; exit 130' INT

	local reply
	while true; do
		read -rsn 1 reply

		if [[ ! ${reply} || ${reply} == " " ]]; then
			reply=${selected:-q}
		elif [[ ${reply} == $'\e' ]]; then
			read -rsn 2 reply
		fi

		case "${reply,,}" in
			y)
				_reset -
				msg "Yes"
				return 0
				;;
			n)
				_reset -
				msg "No"
				return 1
				;;
			q)
				_reset -
				msg "Quit"
				msg -fqm2
				;;
			h | l | "[d" | "[c")
				if [[ ${reply} == "[D" || ${reply} == h ]]; then
					if [[ ! ${selected} ]]; then
						selected=n
					elif [[ ${selected} == n ]]; then
						selected=y
					else
						continue
					fi
				elif [[ ${reply} == "[C" || ${reply} == l ]]; then
					if [[ ${selected} == y ]]; then
						selected=n
					elif [[ ${selected} == n ]]; then
						selected=
					else
						continue
					fi
				fi

				_reset
				_msg
				continue
				;;
			*) ;;
		esac
	done
}


wtf() {
	msg -te "Something wicked happened while"
	msg -e "${@:-doing something wicked}"
	msg -te "Please submit an issue at"
	msg -fq "${SU}${GITHUB}/${DISTRO_REPOSITORY}/issues${RU}"
}



# Project information
GITHUB=https://github.com/jorexdeveloper
AUTHOR=Jore

# Default env path
DEFAULT_PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:/system/bin:/system/xbin

# Output for log messages
LOG_FILE=/dev/null

# Enable color by default
if [[ -t 1 ]]; then
	ENABLE_COLOR=1
else
	ENABLE_COLOR=
fi

# Override permissions for new files
umask 0022

# Main actions
ACTION_INSTALL=1
ACTION_CONFIGURE=1
ACTION_UNINSTALL=

# Process command line options
while [[ ${#} -gt 0 ]]; do
	case "${1}" in
		-d | --directory*)
			optarg=${1/--directory/}
			optarg=${optarg/=/}

			if [[ ! ${optarg} || ${optarg} == -d ]]; then
				shift
				optarg=${1}
			fi

			if [[ ! ${optarg} ]]; then
				msg -aqm1 "Option '-d' or '--directory' requires an argument."
			fi

			if [[ -d ${optarg} && -r ${optarg} ]]; then
				cd "${optarg}" || {
					msg -aq "Can't cd to '${optarg}'"
					exit 1
				}
			else
				msg -aq "'${optarg}' is not a readable directory!"
			fi

			unset optarg
			;;
		--install-only)
			ACTION_CONFIGURE=
			;;
		--config-only)
			ACTION_INSTALL=
			;;
		-u | --uninstall)
			ACTION_UNINSTALL=1
			;;
		-l | --log)
			LOG_FILE=${PROGRAM_NAME%.sh}.log
			;;
		-v | --version)
			print_version
			exit
			;;
		-h | --help)
			print_usage
			exit
			;;
		--color*)
			optarg=${1/--color/}
			optarg=${optarg/=/}

			if [[ ! ${optarg} ]]; then
				shift
				optarg=${1}
			fi

			if [[ ! ${optarg} ]]; then
				msg -aqm1 "Option '-d' or '--directory' requires an argument."
			fi

			case "${optarg}" in
				on)
					if [[ -t 1 ]]; then
						ENABLE_COLOR=1
					else
						ENABLE_COLOR=
					fi
					colors
					;;
				always)
					ENABLE_COLOR=1
					colors
					;;
				off | never)
					ENABLE_COLOR=
					colors
					;;
				*)
					msg -aqm1 "Invalid  argument '${optarg}' for '--color'."
					;;
			esac
			unset optarg
			;;
		-S | --no-safety-check)
			_no_safety_check=1
			;;
		-P | --no-package-check)
			_no_package_check=1
			;;
		-C | --no-rootfs-directory-check)
			_no_rootfs_directory_check=1
			;;
		-D | --no-download-rootfs-archive)
			_no_download_rootfs_archive=1
			;;
		-V | --no-verify-rootfs-archive)
			_no_verify_rootfs_archive=1
			;;
		-X | --no-extract-rootfs-archive)
			_no_extract_rootfs_archive=1
			;;
		-K | --no-make-configurations)
			_no_make_configurations=1
			;;
		-H | --help-dev)
			echo "Usage: ${T}${PROGRAM_NAME}${P} [OPTION] [DIRECTORY]"
			echo
			echo "These options are for development only, meant to speed up testing of the program, use with caution!"
			echo
			echo "OPTIONS:"
			echo "  -S, --no-safety-check            Disable fuction call."
			echo "  -P, --no-package-check           Disable fuction call."
			echo "  -C, --no-rootfs-directory-check  Disable fuction call."
			echo "  -D, --no-verify-download-archive Disable fuction call."
			echo "  -V, --no-verify-rootfs-archive   Disable fuction call."
			echo "  -X, --no-verify-extract-archive  Disable fuction call."
			echo "  -K, --no-make-configurations     Disable fuction call."
			echo "  -H, --help-dev                   Show these options."
			exit
			;;
		--)
			shift
			break
			;;
		-*)
			msg -aqm1 "Unrecognized option '${1}'."
			;;
		*) break ;;
	esac
	shift
done

# Prevent extra arguments except directory
if [[ ${#} -gt 1 ]]; then
	msg -aqm1 "Received too many arguments."
fi

# Update colors
colors

# Set the rootfs directory
if [[ ${1} ]]; then
	ROOTFS_DIRECTORY=$(realpath "${1}")

	if [[ ${ROOTFS_DIRECTORY} != "${TERMUX_FILES_DIR}"* ]]; then
		msg -aq "The rootfs directory ${T}${ROOTFS_DIRECTORY}${R} is NOT within ${T}${TERMUX_FILES_DIR}${R}."
	fi
else
	ROOTFS_DIRECTORY=${DEFAULT_ROOTFS_DIR}
fi

# Uninstall rootfs
if [[ ${ACTION_UNINSTALL} ]]; then
	uninstall_rootfs
	exit
fi

# For some message customizations
if [[ ${ACTION_INSTALL} ]]; then
	main_action=install
else
	main_action=configur
fi

# Pre install actions
if [[ ${ACTION_INSTALL} || ${ACTION_CONFIGURE} ]]; then
	pre_check_actions # External function
	[[ ! ${_no_safety_check} ]] && safety_check

	# Get terminal size after safety check
	read -r TERM_HEIGHT TERM_WIDTH < <(stty size)

	clear
	distro_banner # External function
	print_intro
	check_arch
	[[ ! ${_no_package_check} ]] && package_check
	post_check_actions # External function
	msg -t "${main_action^}ing ${DISTRO_NAME} in"
	msg "${T}${ROOTFS_DIRECTORY}${P}"
fi

# Install actions
if [[ ${ACTION_INSTALL} ]]; then
	[[ ! ${_no_rootfs_directory_check} ]] && rootfs_directory_check
	pre_install_actions # External function
	[[ ! ${_no_download_rootfs_archive} ]] && download_rootfs_archive
	[[ ! ${_no_verify_rootfs_archive} ]] && verify_rootfs_archive
	[[ ! ${_no_extract_rootfs_archive} ]] && extract_rootfs_archive
	post_install_actions # External function
fi

# Create launchers
if [[ ${ACTION_INSTALL} || ${ACTION_CONFIGURE} ]]; then
	create_rootfs_launcher
	create_vnc_launcher
fi

# Post install configurations
if [[ ${ACTION_CONFIGURE} ]]; then
	pre_config_actions # External function
	[[ ! ${_no_make_configurations} ]] && make_configurations
	post_config_actions # External function
	set_user_shell
	set_zone_info
fi

# Clean up files
if [[ ${ACTION_INSTALL} ]]; then
	prompt_cleanup
fi

# Print message for successful completion
if [[ ${ACTION_INSTALL} || ${ACTION_CONFIGURE} ]]; then
	pre_complete_actions # External function
	show_complete_msg
	post_complete_actions # External function
fi
