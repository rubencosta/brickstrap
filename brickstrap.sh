#!/bin/bash
#
# brickstrap - create a foreign architecture rootfs using kernel namespaces,
#              multistrap, and qemu usermode emulation and create a disk image
#              using libguestfs
#
# Copyright (C) 2016      Johan Ouwerkerk <jm.ouwerkerk@gmail.com>
# Copyright (C) 2014-2016 David Lechner <david@lechnology.com>
# Copyright (C) 2014-2015 Ralph Hempel <rhempel@hempeldesigngroup.com>
#
# Based on polystrap:
# Copyright (C) 2011 by Johannes 'josch' Schauer <j.schauer@email.de>
#
# Template to write better bash scripts.
# More info: http://kvz.io/blog/2013/02/26/introducing-bash3boilerplate/
# Version 0.0.1
#
# Licensed under MIT
# Copyright (c) 2013 Kevin van Zonneveld
# http://twitter.com/kvz
#

### Runtime
#####################################################################
set -e

# Bash will remember & return the highest exitcode in a chain of pipes.
set -o pipefail

# Environment variables
[ -z "${LOG_LEVEL}" ] && LOG_LEVEL="3" # 4 = debug -> 0 = fail

#
# Get the brickstrap source directory
#
function br_script_path()
{
    SCRIPT_PATH=$(readlink -f "$0")
    SCRIPT_PATH=$(dirname "$SCRIPT_PATH")
    echo -n "$SCRIPT_PATH"
}

. "$(br_script_path)/brickstrap-argv.sh"
. "$(br_script_path)/brickstrap-components.sh"
. "$(br_script_path)/brickstrap-utils.sh"
. "$(br_script_path)/brickstrap-image.sh"
. "$(br_script_path)/brickstrap-image-drivers.sh"

# Commandline options. This defines the usage page
BRP_USAGE=$(cat <<'EOF'
Usage: brickstrap -p <project> -c <component> [-c <component> [...]] [<options>] <new-command>
       brickstrap [<options>] <step-command>

-p <project>   Directory which contains the brickstrap configuration (project).
               Values are either a path to the project directory or the name of
               an example project shipped with brickstrap by default.

-c <component> Selects a component from the project directory.

<new-command>  Command that creates a new brickstrap.conf.d/, namely "create-conf",
               "create-rootfs" and "all"

<step-command> Command that operates on an existing rootfs (any command that is
               not a <new-command>).

Options
-------
-d <destdir>   Destination directory in which brickstrap will store output.
               This directory will be created if it does not exist. If this
               option is not specified, files will be created in the current
               working directory.

-I <image>     Name of the disk image file to generate (without type suffix).

-l <layout>    Select disk image type to generate (partition layout).
               If no image type is selected, a 'default' layout is used.
               Projects may support additional custom <layout> types.

-Q <emulator>  Override which QEMU binary to use for emulation of foreign
               instruction sets.

               The <emulator> value must be either the path to a binary or
               the name of a Debian or QEMU architecture or the special string
               'none'. If <emulator> corresponds to a binary it is used
               unconditionally, without further validation. If <qemu> is an
               architecture which matches the host architecture or 'native'
               then no emulator will be used. Otherwise the system is queried
               for a well known QEMU emulator for the architecture matching the
               <emulator> value.

-x <package>   Blacklist a package (name). The package will not be added to the
               set of packages to install.

               If the project does not use the PACKAGES variable this setting
               will have no effect. The blacklist will also not prevent the
               package from being included as a dependency of the bootstrap or
               the remaining PACKAGES set.

-X <filename>  Blacklist a package file from the project. The file will be
               ignored while determining the set of packages to install.

               If the project does not use the PACKAGES variable this setting
               will have no effect. The blacklist will also not prevent
               packages listed in the file from being included as dependencies
               of the bootstrap or the remaining PACKAGES set.

-f             Force overwriting existing files/directories.

-h             Help. (You are looking at it.)

  Commands
  --------
  create-conf          generate the multistrap.conf file
* simulate-multistrap  debug/dry-run of multistrap using its --simulate option
  run-multistrap       run multistrap (creates rootfs and downloads packages)
  copy-root            copy files from project definition folder to the rootfs
  configure-packages   configure the packages in the rootfs
* run-hook <hook>      run a single hook in the project configuration folder
  run-hooks            run all of the hooks in the project configuration folder
* create-rootfs        run all of the above commands (except *) in order
  create-tar           create a tar file from the rootfs folder
  create-image         create a disk image file from the tar file
  create-report        run custom reporting script <project>/custom-report.sh
* shell [shell]        run the given shell in the rootfs (default is bash).
* delete               deletes all of the files created by other commands
  all                  run all of the above commands (except *) in order

  Environment Variables
  ---------------------
  LOG_LEVEL               Specifies log level verbosity (0-4)
                          0=fail, ... 3=info(default), 4=debug

  DEBIAN_MIRROR           Specifies the debian mirror used by apt
                          default: http://httpredir.debian.org/debian
                          (applies to create-conf only)

  RASPBIAN_MIRROR         Specifies the Raspbian mirror used by apt
                          default: http://archive.raspbian.org/raspbian
                          (applies to create-conf only)

  EV3DEV_MIRROR           Specifies the ev3dev mirror used by apt
                          default: http://archive.ev3dev.org/debian
                          (applies to create-conf only)

  EV3DEV_RASPBIAN_MIRROR  Specifies the ev3dev/raspbian mirror used by apt
                          default: http://archive/ev3dev.org/raspbian
                          (applies to create-conf only)

EOF
);

### Functions
#####################################################################

function _fmt () {
  color_info="\x1b[32m"
  color_warn="\x1b[33m"
  color_error="\x1b[31m"

  color=
  [ "${1}" = "info" ] && color="${color_info}"
  [ "${1}" = "warn" ] && color="${color_warn}"
  [ "${1}" = "error" ] && color="${color_error}"
  [ "${1}" = "fail" ] && color="${color_error}"

  color_reset="\x1b[0m"
  if [ "${TERM}" != "xterm" ] && [ "${TERM}" != "xterm-256color" ] || [ -t 1 ]; then
    # Don't use colours when using pipes in unrecognised terminals
    color=""
    color_reset=""
  fi
  echo -e "$(date +"%H:%M:%S") [${color}$(printf "%5s" ${1})${color_reset}]";
}

function fail ()  {                             echo "$(_fmt fail) ${@}"  || true; exit 1; }
function error () { [ "${LOG_LEVEL}" -ge 1 ] && echo "$(_fmt error) ${@}" || true;         }
function warn ()  { [ "${LOG_LEVEL}" -ge 2 ] && echo "$(_fmt warn) ${@}"  || true;         }
function info ()  { [ "${LOG_LEVEL}" -ge 3 ] && echo "$(_fmt info) ${@}"  || true;         }
function debug () { [ "${LOG_LEVEL}" -ge 4 ] && echo "$(_fmt debug) ${@}" || true;         }

function brp_help() {
    if [ $# -ge 1 ]; then
        echo >&2 "${@}"
    fi
    echo >&2 "${BRP_USAGE}"
    echo >&2 ""
}

### Parse commandline options - adding the while loop around the
### getopts loop allows commands anywhere in the command line.
###
### Note that cmd gets set to the first non-option string, others
### are simply ignored
#####################################################################

function brp_parse_cli_options()
{
    while [ $# -gt 0 ] ; do
        while getopts "fhc:d:p:Q:I:l:x:X:" BRP_OPT; do
            case "$BRP_OPT" in
            f)
                brp_set_single_value_opt BR_FORCE "$BR_FORCE" true \
                    "-$BRP_OPT" force
            ;;
            h)
                brp_help
                exit 0
            ;;
            p)
                brp_set_single_value_opt BR_PROJECT "$BR_PROJECT" "$OPTARG" \
                    "-$BRP_OPT" project
            ;;
            c)
                brp_set_multi_value_opt BR_COMPONENTS "$BR_COMPONENTS" \
                    "$OPTARG" "-$BRP_OPT" component
            ;;
            d)
                brp_set_single_value_opt BR_DESTDIR "$BR_DESTDIR" "$OPTARG" \
                    "-$BRP_OPT" destination
            ;;
            Q)
                brp_set_single_value_opt BR_QEMU "$BR_QEMU" "$OPTARG" \
                    "-$BRP_OPT" emulator
            ;;
            I)
                brp_set_single_value_opt BR_IMAGE_BASE_NAME \
                    "$BR_IMAGE_BASE_NAME" "$OPTARG" "-$BRP_OPT" image
            ;;
            l)
                brp_set_single_value_opt BR_IMAGE_TYPE "$BR_IMAGE_TYPE" \
                    "$OPTARG" "-$BRP_OPT" 'image type'
            ;;
            x)
                brp_set_multi_value_opt BR_PACKAGE_BLACKLIST \
                    "$BR_PACKAGE_BLACKLIST" "$OPTARG" "-$BRP_OPT" \
                    'package blacklist'
            ;;
            X)
                brp_set_multi_value_opt BR_PACKAGE_FILE_BLACKLIST \
                    "$BR_PACKAGE_FILE_BLACKLIST" "$OPTARG" "-$BRP_OPT" \
                    'package file blacklist'
            ;;
            \?) # unknown flag or missing argument
                brp_help
                exit 1
            ;;
            esac
        done

        shift $((OPTIND-1))

        if [ $# -gt 0 ]; then

            if [ "$BRP_CMD" == "run-hook" ] || [ "$BRP_CMD" == "shell" ]; then
                BRP_CMD_ARG="$1"
            fi

            BRP_CMD="${BRP_CMD:=$1}"

            shift 1
            OPTIND=1
        fi
    done
}

function brp_sanity_check_cli_options()
{
    if [ $# -eq 0 -o -z "$1" ]; then
        fail 'No command specified'
    elif [ "$1" = "run-hook" ] && [ $# -eq 1 -o -z "$2" ]; then
        fail 'No hook specified'
    fi
    if ! $(brp_is_new_command $1) && [ -n "$BR_PROJECT" ]; then
        warn 'The -p option is ignored by this command'
    fi
    if ! $(brp_is_new_command $1) && [ -n "$BR_COMPONENTS" ]; then
        warn 'The -c option is ignored by this command'
    fi
    debug "cmd: $1"
}

function brp_validate_cli_options()
{
    brp_sanity_check_cli_options "$@"
    if $(brp_is_new_command $BRP_CMD); then
        brp_validate_project_name
        brp_validate_component_names
        if [ -d $(br_brickstrap_conf_dir) ]; then
            if [ -z ${BR_FORCE} ]; then
                fail "$(br_brickstrap_conf_dir) already exists. Use -f to replace";
            else
                warn "Replacing $(br_brickstrap_conf_dir)"
                rm -rf $(br_brickstrap_conf_dir)
            fi
        fi
    else
        brp_assert_brickstrap_conf
    fi
    brp_validate_image_name
    brp_validate_qemu || [ $? -eq 255 ] # no QEMU specified = 255
}

#####################################################################
### Set up the variables for the commands

function brp_init_env()
{
    debug "SCRIPT_PATH: $(br_script_path)"

    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export LC_ALL=C LANGUAGE=C LANG=C
    export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

    #
    # Set the defaults for mirrors as promised by help, if these have not been
    # configured for the project yet.
    #
    if [ -z "${DEBIAN_MIRROR}" ]; then
        DEBIAN_MIRROR="http://httpredir.debian.org/debian"
    fi
    if [ -z "${RASPBIAN_MIRROR}" ]; then
        RASPBIAN_MIRROR="http://archive.raspbian.org/raspbian"
    fi
    if [ -z "${EV3DEV_MIRROR}" ]; then
        EV3DEV_MIRROR="http://archive.ev3dev.org/debian"
    fi
    if [ -z "${EV3DEV_RASPBIAN_MIRROR}" ]; then
        EV3DEV_RASPBIAN_MIRROR="http://archive.ev3dev.org/raspbian"
    fi

    for SYSTEM_KERNEL_IMAGE in /boot/vmlinuz-*; do
        [ -r "${SYSTEM_KERNEL_IMAGE}" ] \
            || fail "Cannot read ${SYSTEM_KERNEL_IMAGE} needed by guestfish." \
            "Set permission with 'sudo chmod +r /boot/vmlinuz-*'."
    done

    if [ "$(sysctl -ne kernel.unprivileged_userns_clone)" = "0" ]; then
        fail "Unprivileged user namespace clone is disabled. Enable it by running" \
            "'sudo sysctl -w kernel.unprivileged_userns_clone=1'."
    fi

    # brickstrap.conf may not exist yet if this is the first command
    if [ -f $(brp_brickstrap_conf) ]; then
        brp_init_env2
    fi

    brp_import_extra_components
}

#
# Finish setting up environment.
#
# This must be called after brickstrap.conf is created!
#
function brp_init_env2()
{
    . $(brp_brickstrap_conf)

    # source custom-image.sh driver scripts
    if br_list_paths custom-image.sh -r >/dev/null; then
        br_for_each_path "$(br_list_paths custom-image.sh -r)" \
            brp_run_hook_impl 'loading'
    fi

    brp_validate_image_configuration
}

function brp_read_package_file()
{
    # check that the package file hasn't been blacklisted
    if echo "$BLACKLIST_PACKAGE_FILES" | fgrep -q "$(basename "$1")" || \
        echo "$BR_PACKAGE_FILE_BLACKLIST" | fgrep -q "'$(basename "$1")'"; then
        info "Skipping blacklisted package file: '$1'"
        return 0
    fi
    while IFS='' read -r BRP_CUR_LINE || [ -n "$BRP_CUR_LINE" ]; do
        case "$BRP_CUR_LINE" in
        \#*|\;*) # permit comments: lines starting with # or ; are ignored.
        ;;
        *)
            # avoid redundant spaces, i.e.  empty lines are ignored.
            # also check that the package line hasn't been blacklisted
            if [ -z "$BRP_CUR_LINE" ]; then
                continue
            elif echo "$BLACKLIST_PACKAGES" | fgrep -q "$BRP_CUR_LINE" || \
                echo "$BR_PACKAGE_BLACKLIST" | fgrep -q "'$BRP_CUR_LINE'"; then
                info "Ignoring blacklisted package: '$BRP_CUR_LINE'"
                continue
            else
                PACKAGES="${PACKAGES} $BRP_CUR_LINE"
            fi
        ;;
        esac
    done < "$1"
}

function brp_read_multistrap_conf_file()
{
    while read BRP_CUR_LINE; do
        eval echo "$BRP_CUR_LINE" >> "$(br_multistrap_conf)"
    done < "$1"
}

function brp_create_conf() {
    debug 'brp_create_conf()'
    debug "br_project_dir: $(br_project_dir)"

    # Create the directory <destdir>/brickstrap.conf/
    mkdir -p $(br_brickstrap_conf_dir)

    info "Creating brickstrap configuration file..."
    debug "creating $(brp_brickstrap_conf)"
    br_cat_files 'config' > $(brp_brickstrap_conf)
    echo "BR_PROJECT=${BR_PROJECT}" >> $(brp_brickstrap_conf)
    echo "BR_COMPONENTS=${BR_COMPONENTS}" >> $(brp_brickstrap_conf)

    # Finish environment init now that we have brickstrap.conf
    brp_init_env2

    info "Creating multistrap configuration file..."
    if br_list_directories packages >/dev/null; then
        br_for_each_path_iterate_directories \
            "$(br_list_directories packages)" brp_read_package_file
    fi

    debug "creating $(br_multistrap_conf)"
    mkdir -p "$(dirname "$(br_multistrap_conf)")"
    echo -n > "$(br_multistrap_conf)"
    br_for_each_path "$(br_list_paths multistrap.conf -f)" \
        brp_read_multistrap_conf_file

    info "Merging components..."
    mkdir -p $(br_hooks_dir)
    mkdir -p $(br_root_overlay_dir)
    for component in $(brp_iterate_components 'echo'); do
        hooks_dir=$(br_project_dir)/$component/hooks
        if [ -d $hooks_dir ]; then
            hooks_dest_prefix=$(br_hooks_dir)/$component
            for hook in $hooks_dir/*; do
                cp --dereference $hook $hooks_dest_prefix.$(basename $hook)
            done
        fi

        root_dir=$(br_project_dir)/$component/root
        if [ -d $root_dir ]; then
            cp --recursive --dereference $root_dir/* $(br_root_overlay_dir)
        fi

        for f in "debconfseed.txt" "preinst.blacklist" "tar-exclude" \
                 "custom-report.sh" "custom-image.sh"
        do
            source=$(br_project_dir)/$component/$f
            dest=$(br_brickstrap_conf_dir)/$f

            if [ -f $source ]; then
                cat $source >> $dest
            fi
        done
    done

    # move debcofseed.txt inside of the root overlay
    BRP_DEBCONFSEED=$(br_brickstrap_conf_dir)/debconfseed.txt
    if [ -f $BRP_DEBCONFSEED ]; then
        mkdir -p $(br_root_overlay_dir)/$(br_chroot_brp_dir)/
        mv $BRP_DEBCONFSEED $(br_root_overlay_dir)/$(br_chroot_brp_dir)/
    fi
}

function brp_simulate_multistrap() {
    MSTRAP_SIM="--simulate"
    brp_run_multistrap
}

function brp_run_multistrap() {
    info "running multistrap..."
    debug "MULTISTRAPCONF: $(br_multistrap_conf)"
    debug "ROOTDIR: $(br_rootfs_dir)"
    if [ -d "$(br_rootfs_dir)" ]; then
        if [ -n "$BR_FORCE" ]; then
            warn "Removing existing rootfs $(br_rootfs_dir)"
            brp_unshare -- rm -rf "$(br_rootfs_dir)"
        else
            fail "$(br_rootfs_dir) already exists. Use -f option to overwrite."
        fi
    fi
    mkdir -p "$(br_rootfs_dir)"
    mkdir -p "$(br_brp_dir)"
    brp_unshare -- multistrap ${MSTRAP_SIM} --no-auth \
        --file "$(br_multistrap_conf)" \
        --dir "$(br_rootfs_dir)"
    brp_setup_qemu_in_rootfs
}

function brp_copy_root() {
    info "Copying root files from project definition..."
    debug "br_project_dir: $(br_project_dir)"
    debug "ROOTDIR: $(br_rootfs_dir)"
    brp_check_rootfs_dir
    cp --recursive --dereference "$(br_root_overlay_dir)/"* "$(br_rootfs_dir)/"
}

#
# Provide a standalone command version of brp_copy_root that creates the rootfs
# directory if necessary (when it does not exist).
#
function brp_copy_root_cmd() {
    mkdir -p "$(br_rootfs_dir)"
    brp_copy_root
}

#
# Ensure that a 'usable' /etc/shells file exists for the add-shell utility.
# This ensures that configuration of shell packages (dash in particular) do
# not fail with spurious error messages from misbehaving add-shell.
# The add-shell utility of debianutils (at least version 4.6) may fail on
# empty/missing /etc/shells file with a bogus error message.
#
function brp_fixup_etc_shells()
{
    info "Checking /etc/shells"
    if [ ! -f "$(br_rootfs_dir)/etc/shells" ] ||
        [ ! -s "$(br_rootfs_dir)/etc/shells" ]; then
        if [ -f "$(br_rootfs_dir)/usr/share/debianutils/shells" ] &&
            [ -s "$(br_rootfs_dir)/usr/share/debianutils/shells" ]; then
            info "Populating default /etc/shells from template"
            cp "$(br_rootfs_dir)/usr/share/debianutils/shells" \
                "$(br_rootfs_dir)/etc/shells"
        else
            warn "Generating dummy contents for: /etc/shells"
            echo "# Dummy comment to work around add-shell bug" >\
                "$(br_rootfs_dir)/etc/shells"
        fi
    else
        info "Default /etc/shells appears to be sane... skipping"
    fi
}

function brp_configure_packages () {
    info "Configuring packages..."
    brp_check_rootfs_dir
    BRP_OLD_PATH="$PATH"
    BRP_W_AWK_PATH="$PATH"

    # awk needs to be in the path, but Debian symlinks are not
    # configured yet, so make a temporary one in /$(br_chroot_brp_dir)/bin
    # then export the dir on the PATH.
    #
    if br_chroot which awk >/dev/null; then
        info "Using existing 'awk': $(br_chroot which awk)"
    elif [ -x "/$(br_chroot_brp_dir)/bin/awk" ]; then
        info "Reusing old temporary symlink: /$(br_chroot_brp_dir)/bin/awk"
        BRP_W_AWK_PATH="$BRP_W_AWK_PATH:/$(br_chroot_brp_dir)/bin"
    else
        info "Creating awk temporary symlink: /$(br_chroot_brp_dir)/bin/awk"
        br_chroot mkdir -p "/$(br_chroot_brp_dir)/bin"
        BRP_W_AWK_PATH="$BRP_W_AWK_PATH:/$(br_chroot_brp_dir)/bin"
        #
        # Do not hard-depend on gawk, because it is an optional package.
        # Someone might try to bootstrap Debian without it.
        # (By contrast: mawk has priority 'required').
        #
        if [ -e "$(br_rootfs_dir)/usr/bin/gawk" ]; then
            info "Using 'gawk' to provide /$(br_chroot_brp_dir)/bin/awk"
            br_chroot ln -sf /usr/bin/gawk "/$(br_chroot_brp_dir)/bin/awk"
        elif [ -e "$(br_rootfs_dir)/usr/bin/mawk" ]; then
            info "Using 'mawk' to provide /$(br_chroot_brp_dir)/bin/awk"
            br_chroot ln -sf /usr/bin/mawk "/$(br_chroot_brp_dir)/bin/awk"
        else
            fail "No 'awk' available in: $(br_rootfs_dir)
Tried: /usr/bin/gawk
Tried: /usr/bin/mawk"
        fi
    fi

    export PATH="$BRP_W_AWK_PATH"

    # preseed debconf
    if [ -f $(br_brp_dir)/debconfseed.txt ]; then
        info "Applying debconf preseed..."
        br_chroot debconf-set-selections /$(br_chroot_brp_dir)/debconfseed.txt
    fi

    # run preinst scripts
    info "running preinst scripts..."
    BRP_script_dir="$(br_rootfs_dir)/var/lib/dpkg/info"
    BRP_preinst_blacklist="$(br_cat_files preinst.blacklist)"
    for BRP_script in ${BRP_script_dir}/*.preinst; do
        if echo "$BRP_preinst_blacklist" | \
            fgrep -xq "$(basename "$BRP_script" .preinst)"; then
            info "skipping $(basename "$BRP_script") (blacklisted)"
        else
            info "running $(basename "$BRP_script")"
                DPKG_MAINTSCRIPT_NAME=preinst \
                DPKG_MAINTSCRIPT_PACKAGE="`basename ${BRP_script} .preinst`" \
                    br_chroot_bind ${BRP_script##$(br_rootfs_dir)} install
        fi
    done

    brp_fixup_etc_shells

    info "configuring packages..."
    br_chroot_bind /usr/bin/dpkg --configure -a

    export PATH="$BRP_OLD_PATH"

    # remove our temporary awk symlink as it is no longer required.
    if [ -x "/$(br_chroot_brp_dir)/bin/awk" ]; then
        info "Removing awk temporary symlink"
        br_chroot rm -f "/$(br_chroot_brp_dir)/bin/awk"
    fi
}

function brp_run_hook() {
    brp_check_rootfs_dir
    # completely bogus
    if [ $# -eq 0 -o -z "$1" ]; then
        fail "Empty hook names are invalid"
    else
        hook=$(br_hooks_dir)/$1

        info "running hook: $1"
        debug "$hook"
        . $hook

        exit_code=$?
        if [ $exit_code -ne 0 ]; then
            fail "$1 failed with $exit_code"
        fi
    fi
}

function brp_run_hooks() {
    brp_check_rootfs_dir
    for hook in $(br_hooks_dir)/*; do
        brp_run_hook $(basename $hook)
    done
}

# Runs a status/config info reporting hook, to be called at the end of the
# brickstrap process. This permits the user to aggregate important info about
# the build in a single, convenient report. (E.g. root passwd, default account
# username+password, hostname, key fingerprints?)
function brp_create_report() {
    BRP_CUSTOM_REPORT=$(br_brickstrap_conf_dir)/custom-report.sh

    if [ -f $BRP_CUSTOM_REPORT ]; then
        mkdir -p "$(br_report_dir)"
        info "Running custom reporting scripts..."
        . $BRP_CUSTOM_REPORT
        info "Done with custom reporting scripts."
    else
        info "Skipping custom report, no such scripts: custom-report.sh"
    fi
}

function brp_copy_to_tar_only() {
    cp -r "$1/." "$(br_brp_dir)/tar-only/"
}

function brp_create_tar() {
    info "Creating tar of rootfs"
    debug "ROOTDIR: $(br_rootfs_dir)"
    debug "TARBALL: $(br_tarball_path)"
    brp_check_rootfs_dir
    [ -z "$BR_FORCE" ] && [ -f "$(br_tarball_path)" ] \
	    && fail "$(br_tarball_path) exists. Use -f option to overwrite."
    info "creating tarball $(br_tarball_path)"

    BRP_EXCLUDE_LIST="$(br_brp_dir)/tar-exclude"
    BRP_EXCLUDE_SOURCE="$(br_brickstrap_conf_dir)/tar-exclude"
    if [ -f $BRP_EXCLUDE_SOURCE ]; then
        info "Excluding files: "
        cat $BRP_EXCLUDE_SOURCE | tee "$BRP_EXCLUDE_LIST" && echo "" # add newline
    fi

    brp_determine_qemu
    # test if QEMU should be excluded, if so, append it to exclude list
    if br_get_rootfs_qemu >/dev/null; then
        echo "" >> "$BRP_EXCLUDE_LIST"
        echo "$(br_get_rootfs_qemu)" >> "$BRP_EXCLUDE_LIST"
    fi

    # need to generate tar inside fakechroot
    # so that absolute symlinks are correct

    mkdir -p "$(dirname "$(br_tarball_path)")"
    br_chroot tar cpf "/$(br_chroot_hostfs_dir)/$(br_tarball_path)" \
        --exclude="$(br_chroot_brp_dir)" \
        --exclude-from="${BRP_EXCLUDE_LIST##$(br_rootfs_dir)}" .

    if [ -d "$(br_brp_dir)/tar-only" ]; then
        info "Adding tar-only files:"
        br_chroot tar rvpf "/$(br_chroot_hostfs_dir)/$(br_tarball_path)" \
            -C "/$(br_chroot_brp_dir)/tar-only" .
    fi
}

function brp_create_rootfs () {
    brp_create_conf
    brp_run_multistrap
    brp_copy_root
    brp_configure_packages
    brp_run_hooks
}

function brp_delete_all() {
    info "Deleting all files..."
    brp_unshare -- rm -rf "$(br_rootfs_dir)"
    rm -f "$(br_multistrap_conf)"
    rm -f "$(br_tarball_path)"
    rm -rf "$(br_image_dir)"
    rm -rf "$(br_report_dir)"
    BRP_PWD=$(pwd)

    # if the current working directory is at or underneath the destination
    # directory, do the safe thing: don't rm -rf, warn about it instead.
    if [ "${BRP_PWD##$(br_dest_dir)}" != "$BRP_PWD" ]; then
        warn "Not removing output destination directory: '$(br_dest_dir)'
To fix this manually, try: rm -rf '$(br_dest_dir)'"
    else
        rm -rf "$(br_dest_dir)"
    fi
    info "Done."
}

function brp_run_shell() {
    brp_check_rootfs_dir
    # permit the user to select the shell manually
    if [ -n "$1" ]; then
        info "Entering chosen shell: '$1'"
        debian_chroot="brickstrap" PROMPT_COMMAND="" HOME=/root \
            br_chroot_bind "$1"
    # by default assume bash as shell
    else
        info "Entering default shell"
        debian_chroot="brickstrap" PROMPT_COMMAND="" HOME=/root \
            br_chroot_bind bash
    fi
}

function brp_run_command()
{
    [ $# -ge 1 ] && case "$1" in
        create-conf)         brp_create_conf;;
        simulate-multistrap) brp_simulate_multistrap;;
        run-multistrap)      brp_run_multistrap;;
        copy-root)           brp_copy_root_cmd;;
        configure-packages)  brp_configure_packages;;
        run-hook)            brp_run_hook "$2";;
        run-hooks)           brp_run_hooks;;
        create-rootfs)       brp_create_rootfs;;
        create-tar)          brp_create_tar;;
        create-image)        brp_create_image;;
        create-report)       brp_create_report;;
        delete)              brp_delete_all;;
        shell)               brp_run_shell "$2";;

        all)
            brp_create_rootfs
            brp_create_tar
            brp_create_image
            brp_create_report
        ;;

        *)
            brp_help "Unknown command: '$1'."
            exit 1
        ;;
    esac
}

function brp_run()
{
    brp_image_drv_register_defaults
    brp_parse_cli_options "$@"
    brp_set_destination_defaults
    brp_validate_cli_options "$BRP_CMD" "$BRP_CMD_ARG"
    brp_init_env
    brp_run_command "$BRP_CMD" "$BRP_CMD_ARG"
}

brp_run "$@"
