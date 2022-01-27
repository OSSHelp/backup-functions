#!/bin/bash
# shellcheck disable=SC2015

umask 0077
export LANG=C
export LC_ALL=C

bfver=3.31.1
cbver=1.02.0

index_url="${REMOTE_URI:-https://oss.help/scripts/backup/backup-functions/.list}"
list_name=$(basename "${index_url}")
lib_name="backup-functions.sh"
lib_dir="/usr/local/include/osshelp"
default_backup_dir='/backup'
template_name='custom.backup'
script_dir='/usr/local/sbin'
logrotate_cfg_path='/etc/logrotate.d/custom'
tmpdir="${TEMP:=/tmp}"

library_was_installed=0
template_was_installed=0
logrotate_cfg_was_installed=0
default_backup_dir_was_created=0

shacmd=$(command -v sha256sum || command -v gsha256sum 2>/dev/null)
silent=no
err=0

function show_notice() { test "${silent}" != "yes" && echo -e "[NOTICE] ${*}"; return 0; }
function show_error() { echo -e "[ERROR] ${*}" >&2;  err=1; return 1; }
function logrotate_config_is_needed() { local cfg_exists=1; test -r "${logrotate_cfg_path}" || cfg_exists=0; return "${cfg_exists}"; }
function default_dir_is_needed() { local dir_exists=1; test -d "${default_backup_dir}" || dir_exists=0; return "${dir_exists}"; }
function template_installation_is_needed() {
  local script_exists=1
  script_exists=$(find "${script_dir}" -name "custom.*backup*" -type f | grep -cv mkconf)
  return "${script_exists}"
}
function fetch_files() {
  cd "${1}" && {
    {
      wget -q -P "${1}" "${index_url}" && \
        wget -q -i "${1}/${list_name}" -P "${1}"
    } && {
      "${shacmd}" -c --status SHA256SUMS 2> /dev/null || {
        show_error "Something went wrong, checksums of downloaded files mismatch."
        "${shacmd}" -c "${1}/SHA256SUMS"
        return 1
      }
    }
  }
}
function install_files() {
  test -d "${lib_dir}" || mkdir -p "${lib_dir}"
  default_dir_is_needed && {
    mkdir -p "${default_backup_dir}" && \
      chmod 700 "${default_backup_dir}" && \
        default_backup_dir_was_created=1
  }
  logrotate_config_is_needed && {
    mv "${tmp_dir}/logrotate.conf" "${logrotate_cfg_path}" && \
      logrotate_cfg_was_installed=1
  }
  template_installation_is_needed && {
    test -x "${script_dir}/${template_name}" || {
      mv "${tmp_dir}/${template_name}" "${script_dir}/${template_name}" && \
        chmod 700 "${script_dir}/${template_name}" && \
          template_was_installed=1
    }
  }
  mv -f "${tmp_dir}/${lib_name}" "${lib_dir}/${lib_name}" && \
    chmod 640 "${lib_dir}/${lib_name}" && \
      library_was_installed=1
}
function show_notices() {
  test "${default_backup_dir_was_created}" -eq 1 && \
    show_notice "Directory ${default_backup_dir} was created."
  test "${logrotate_cfg_was_installed}" -eq 1 && \
    show_notice "Logrotate config was installed as ${logrotate_cfg_path}."
  test "${template_was_installed}" -eq 1 && \
    show_notice "Backup script template (v${cbver}) was installed as ${script_dir}/${template_name}. Make sure it is set in order before adding a cron job!"
  test "${library_was_installed}" -eq 1 && {
    show_notice "Library ${lib_name} (v${bfver}) was installed as ${lib_dir}/${lib_name}."
    show_notice "Use \"osscli check backup\" when backup script is done. Check https://oss.help/kb1453 for additional information."
  }
}

uid=$(id -u)
test "${uid}" != 0 && { show_error "Sorry, but you must run this script as root."; exit 1; }

tmp_dir="${tmpdir}/backup-functions.${$}"
mkdir -p "${tmp_dir}" && \
  fetch_files "${tmp_dir}" && \
    install_files "${tmp_dir}" && \
      show_notices

test -d "${tmp_dir}" && rm -rf "${tmp_dir}"
test "${err}" -eq 1 && { show_error "Installation failed."; }
exit "${err}"
