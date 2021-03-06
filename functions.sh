# Copyright (C) 2017 Evgeny Golyshev <eugulixes@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

DEBOOTSTRAP_VER="1.0.91"

# Checks if the specified variable is set.
# Globals:
#     None
# Arguments:
#     Variable name
# Returns:
#     None
check_if_variable_is_set() {
    var_name=$1
    if [ -z "${!var_name+x}" ]; then
        false
    else
        true
    fi
}

# It's quite dangerous to run some of the functions from the script if the
# following variables are undefined, so it's necessary to check the variables
# before running the script.
for var in BUILD_DIR IMAGE KEYRING MOUNT_POINT PIECES PROJECT_NAME PYTHON R SOURCE_DIR USR_BIN YML_FILE; do
    if ! check_if_variable_is_set ${var}; then
        >&2 echo "${var_name} is not specified"
        exit 1
    fi
done

#
# APT-related functions
#

# Clears out the local repository of retrieved package files and removes
# indexes.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
clean() {
    chroot_exec apt-get clean
    rm -rf ${R}/var/lib/apt/lists/*
}

# Updates the indexes in the chroot environment.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
update_indexes() {
    chroot_exec apt-get update
}

# Upgrades the chroot environment.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
upgrade() {
    # TODO: find a way to get rid of --allow-unauthenticated
    chroot_exec apt-get -y --allow-unauthenticated dist-upgrade
}

# Installs the specified packages in the chroot environment.
# Globals:
#     None
# Arguments:
#     Packages names, separated by spaces
# Returns:
#     None
install_packages() {
    # TODO: find a way to get rid of --allow-unauthenticated
    chroot_exec apt-get -y --allow-unauthenticated install $*
}

# Removes the specified packages with their configuration files from the chroot
# environment.
# Globals:
#     None
# Arguments:
#     Packages names, separated by spaces
# Returns:
#     None
purge_packages() {
    chroot_exec apt-get -y purge $*
}

#
# Base functions
#

# Checks if all required dependencies are installed on the system.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
check_dependencies() {
    if [ -z `which dpkg` ]; then
        # Do not mention Debian or Ubuntu since dpkg is a part of
        # the base system there.
        fatal "there is no dpkg. Run dnf install dpkg on Fedora to fix it."
        exit 1
    fi

    if [ ! -e /usr/bin/qemu-arm-static ]; then
        fatal "there is no /usr/bin/qemu-arm-static." \
              "Run apt-get install qemu-user-static on Debian/Ubuntu or" \
              "dnf install qemu-user-static on Fedora."
        exit 1
    fi

    if [ ! -e /usr/bin/qemu-aarch64-static ]; then
        fatal "there is no /usr/bin/qemu-aarch64-static."
              "Run apt-get install qemu-user-static on Debian/Ubuntu or" \
              "dnf install qemu-user-static on Fedora."
        exit 1
    fi

    for dep in gpg kpartx parted python3 rsync wget; do
        if [ -z `which ${dep}` ]; then
            fatal "there is no ${dep}." \
                  "Run apt-get install ${dep} on Debian/Ubuntu or" \
                  "dnf install ${dep} on Fedora."
            exit 1
        fi
    done

    if [ -z `which mkpasswd` ]; then
        fatal "there is no mkpasswd." \
              "Run apt-get install whois on Debian/Ubuntu or" \
              "dnf install expect on Fedora."
        exit 1
    fi

    if [ -z `which uuidgen` ]; then
        # Do not mention Fedora since uuidgen belongs to the util-linux package
        # which is a key component of the system.
        fatal "there is no uuidgen." \
              "Run apt-get install uuid-runtime on Debian/Ubuntu to fix it."
        exit 1
    fi

    if ! ${PYTHON} -c "import yaml"; then
        fatal "there is no yaml python package." \
              "Run apt-get install python3-yaml on Debian/Ubuntu or" \
              "dnf install python3-PyYAML on Fedora"
        exit 1
    fi
}

# Checks if two or more mutually exclusive parameters are set true or does not
# contain an empty string.
# The function has the following side effect: it assigns an empty string to the
# parameters which are set to false.
# Globals:
#     None
# Arguments:
#     Parameters
# Returns:
#     None
check_mutually_exclusive_params() {
    for param in $*; do
        # false is considered as non-empty string, so use empty string
        # explicitly.
        if [[ ${!param} == false ]]; then
            declare $param=""
        fi
    done

    for a in $*; do
        for b in $*; do
            if [[ ${a} == ${b} ]]; then
                continue
            fi

            if [ ! -z "${!a}" ] && [ ! -z "${!b}" ]; then
                fatal "${a} and ${b} conflict with each other."
                exit 1
            fi
        done
    done
}

# Looks for debootstrap installed locally. If it does not exist, tries to find
# debootstrap installed globally. When the function succeeds, it assigns the
# corresponding executable name to DEBOOTSTRAP_EXEC and the full path of the
# executable to DEBOOTSTRAP_DIR (only in case of a local debootstrap).
# Otherwise, the function exits with the exit code 1.
# Globals:
#     DEBOOTSTRAP_DIR
#     DEBOOTSTRAP_EXEC
# Arguments:
#     None
# Returns:
#     None
choose_debootstrap() {
    local ver=""

    if [ -f debootstrap/debootstrap ]; then
        DEBOOTSTRAP_EXEC="env DEBOOTSTRAP_DIR=`pwd`/debootstrap ./debootstrap/debootstrap"

        # After cloning the debootstrap git repo the program is a fully
        # functional, but does not have a correct version number. However, the
        # version can be found in the source package changelog.
        ver=`sed 's/.*(\(.*\)).*/\1/; q' debootstrap/debian/changelog`
    elif [ ! -z `which debootstrap` ]; then
        DEBOOTSTRAP_EXEC=`which debootstrap`
        ver=`${DEBOOTSTRAP_EXEC} --version | awk '{print $2}' || /bin/true`
    else
        fatal "there is no debootstrap." \
              "It's recommended to install the latest version of the program" \
              "using its git repo:" \
              "https://anonscm.debian.org/git/d-i/debootstrap.git"
        exit 1
    fi

    if [ -z ${ver} ]; then
        fatal "your debootstrap seems to be broken. Could not get its version."
        exit 1
    fi

    if dpkg --compare-versions ${ver} lt ${DEBOOTSTRAP_VER}; then
        fatal "debootstrap ${DEBOOTSTRAP_VER} or higher is required."
        exit 1
    fi

    info "using ${DEBOOTSTRAP_EXEC}"
}

# Chooses the corresponding user mode emulation binary and assigns its full
# path to the EMULATOR environment variable. The binary depends on the
# architecture of the operating system which is going to be used as a base for
# the target image.
# Globals:
#     EMULATOR
#     PIECES
# Arguments:
#     None
# Returns:
#     None
choose_user_mode_emulation_binary() {
    if [ ! ${#PIECES[@]} -eq 3 ]; then
        fatal "Use the following naming convention for OS: <distro name>-<codename>-<arch>."
        exit 1
    fi

    case ${PIECES[2]} in
    armhf)
        EMULATOR=/usr/bin/qemu-arm-static
        ;;
    arm64)
        EMULATOR=/usr/bin/qemu-aarch64-static
        ;;
    *)
        fatal "Unknown architecture ${PIECES[2]}."
        exit 1
    esac
}

# Cleans up the build environment.
# Globals:
#     IMAGE
#     KEYRING
#     LOOP_DEV
#     MOUNT_POINT
#     PROJECT_NAME
# Arguments:
#     None
# Returns:
#     None
cleanup() {
    set -x

    rm -f ${KEYRING}

    umount ${MOUNT_POINT} 2> /dev/null || /bin/true

    umount_required_filesystems

    if check_if_variable_is_set LOOP_DEV; then
        losetup -d ${LOOP_DEV}
    fi

    set +x
}

# Runs all scripts which are located in the specified directory.
# Globals:
#     None
# Arguments:
#     Path to the directory
# Returns:
#     None
run_scripts() {
    dir=${1}
    if [ -d ${dir} ]; then
        for script in ${dir}/*.sh; do
            info "running ${script} from ${dir}"
            . ${script}
        done
    else
        info "cannot run anything from ${dir} since it does not exist."
    fi
}

# Calls the cleanup function on the following signals: EXIT, SIGHUP, SIGINT,
# SIGQUIT and SIGABRT.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
set_traps() {
    trap cleanup 0 1 2 3 6
}

#
# Chroot-related functions
#

# Executes the specified command in the chroot environment.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
chroot_exec() {
    chroot ${R} $* 1>&2
}

# Executes the specified command in the chroot environment using shell.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
chroot_exec_sh() {
    chroot ${R} sh -c "${*}" 1>&2
}

#
# Debootstrap-related functions
#

# Runs the first stage of building a chroot environment. Then it installs
# a user mode emulation binary to the chroot.
# Globals:
#     DEBOOTSTRAP_EXEC
#     OS
#     PIECES
#     KEYRING
# Arguments:
#     None
# Returns:
#     None
run_first_stage() {
    arch=${PIECES[2]}
    codename=${PIECES[1]}
    primary_repo=`get_attr ${OS} repos | head -n1`
    ${DEBOOTSTRAP_EXEC} --arch=${arch} --foreign --variant=minbase --keyring=${KEYRING} ${codename} ${R} ${primary_repo} 1>&2

    install_user_mode_emulation_binary
}

# Runs the second (i.e. final) stage of building a chroot environment.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
run_second_stage() {
    chroot_exec debootstrap/debootstrap --second-stage
}

#
# Print messages in different colors
#

text_in_red_color=$(tput setaf 1)

text_in_green_color=$(tput setaf 2)

text_in_yellow_color=$(tput setaf 3)

reset=$(tput sgr0)

# Prints the specified message with the level fatal.
# Globals:
#     None
# Arguments:
#     Message
# Returns:
#     None
fatal() {
    >&2 echo "${text_in_red_color}Fatal${reset}: ${*}"
}

# Prints the specified message with the level info.
# Globals:
#     None
# Arguments:
#     Message
# Returns:
#     None
info() {
    >&2 echo "${text_in_yellow_color}Info${reset}: ${*}"
}

# Prints the specified message with the level success.
# Globals:
#     None
# Arguments:
#     Message
# Returns:
#     None
success() {
    >&2 echo "${text_in_green_color}Success${reset}: ${*}"
}

#
# FS-related functions
#

# Checks if the required directories exist.
# Globals:
#     None
# Arguments:
#     None
# Returns:
#     None
check_required_directories() {
    dirs="bootstrap devices"

    for dir in ${dirs}; do
        if [ ! -d ${dir} ] ; then
            fatal "${dir} required directory not found!"
            exit 1
        fi
    done
}

# Checks if the required files exist.
# Globals:
#     YML_FILE
# Arguments:
#     None
# Returns:
#     None
check_required_files() {
    if [ ! -f ${YML_FILE} ]; then
        fatal "${YML_FILE} does not exist"
        exit 1
    fi
}

# Creates the specified directory if it does not exist.
# Globals:
#     None
# Arguments:
#     Directory name
# Returns:
#     None
create_dir() {
    dir=$1

    if [ ! -d ${dir} ]; then
        mkdir -p ${dir}
    fi
}

# Creates the directories which are considered as necessary for projects/
# Globals:
#     BUILD_DIR
#     PROJECT_NAME
# Arguments:
#     None
# Returns:
#     None
create_necessary_dirs() {
    target=${BUILD_DIR}/${PROJECT_NAME}
    if [ -d ${target} ]; then
        fatal "${target} already exists"
        exit 1
    fi

    create_dir ${target}
    create_dir ${target}/boot
    create_dir ${target}/mount_point
}

# Installs the specified file to the specified directory and changes
# the permissions of the file to 744.
# Globals:
#     None
# Arguments:
#     Path to the file
#     Path to the directory
# Returns:
#     None
install_exec() {
    install -o root -g root -m 744 $*
}

# Installs the specified file to the specified directory and changes
# the permissions of the file to 644.
# Globals:
#     None
# Arguments:
#     Path to the file
#     Path to the directory
# Returns:
#     None
install_readonly() {
    install -o root -g root -m 644 $*
}

# Installs the corresponding user mode emulation binary to the chroot
# environment.
# Globals:
#     EMULATOR
#     USR_BIN
# Arguments:
#     None
# Returns:
#     None
install_user_mode_emulation_binary() {
    # It's not possible to use install_exec for installing user mode emulation
    # binaries. For details, see https://github.com/drtyhlpr/rpi23-gen-image/pull/85.
    install -m 755 -o root -g root ${EMULATOR} ${USR_BIN}
}

# Mounts the required filesystems to the chroot environment.
# Globals:
#     R
# Arguments:
#     None
# Returns:
#     None
mount_required_filesystems() {
    mount -t proc none "${R}/proc"
    mount -t sysfs none "${R}/sys"

    # To prevent the following error message:
    # E: Can not write log (Is /dev/pts mounted?) - posix_openpt (19: No such device)
    if [ -d "${R}/dev/pts" ] ; then
        mount --bind /dev/pts "${R}/dev/pts"
    fi

    # To prevent the following error message:
    # Couldn't create temporary file /tmp/apt.conf.xxxxxx for passing config to apt-key
    mount --bind /tmp "${R}/tmp"
}

# Unmounts the required filesystems.
# Globals:
#     R
# Arguments:
#     None
# Returns:
#     None
umount_required_filesystems() {
    umount -l "${R}/proc"    2> /dev/null || /bin/true
    umount -l "${R}/sys"     2> /dev/null || /bin/true
    umount    "${R}/dev/pts" 2> /dev/null || /bin/true
    umount    "${R}/tmp"     2> /dev/null || /bin/true
}

#
# Image attributes-related functions
#

# Gets the values the specified image attribute using image_attrs.py. If its
# exit code is different from 0, interrupt the execution of the script and
# exit.
# Globals:
#     PYTHON
#     YML_FILE
# Arguments:
#     Image attribute
# Returns:
#     Image attribute value
get_attr() {
    output="`${PYTHON} ${PIEMAN_BIN}/image_attrs.py --file=${YML_FILE} $* 2>&1`"
    if [ $? -ne 0 ]; then
        fatal "while getting the specified attribute from ${YML_FILE} occurred the following error: ${output}."
        exit 1
    fi

    echo "${output}"
}

# Gets the values the specified image attribute using image_attrs.py.
# If image_attrs.py could not succeed, the function does nothing.
# Globals:
#     PYTHON
#     YML_FILE
# Arguments:
#     Image attribute
# Returns:
#     Image attribute value
get_attr_or_nothing() {
    ${PYTHON} ${PIEMAN_BIN}/image_attrs.py --file=${YML_FILE} $* 2> /dev/null || /bin/true
}

#
# Unsorted functions
#

# Adds the specified package name to the INCLUDES environment variable which is
# a comma-separated list.
# Globals:
#     INCLUDES
# Arguments:
#     Package name
# Returns:
#     None
add_package_to_includes() {
    package=${1}
    if [ -z `echo ${INCLUDES} | grep ",${package}"` ]; then
        INCLUDES="${INCLUDES},${package}"
    fi
}

# Finds the public keys related to the operating system which is going to be
# used as a base for the target image, and adds them to the keyring, the name
# of which is stored in the KEYRING environment variable.
# Globals:
#     PIECES
#     KEYRING
# Arguments:
#     None
# Returns:
#     None
create_keyring() {
    for key in keys/${PIECES[0]}/*; do
        gpg --no-default-keyring --keyring=${KEYRING} --import ${key}
    done
}
