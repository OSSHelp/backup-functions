#!/bin/bash
# shellcheck disable=SC2015

umask 0077
export LANG=C
export LC_ALL=C

bfver=3.30.2

script_name="backup-functions.sh"
script_path="/usr/local/include/osshelp"
logrotate_config_path='/etc/logrotate.d/custom'
index_url="${REMOTE_URI:-https://oss.help/scripts/backup/backup-functions/.list}"
list_name=$(basename "${index_url}")
tmpdir="${TEMP:=/tmp}"
shacmd=$(command -v sha256sum || command -v gsha256sum 2>/dev/null)
silent=no
err=0

function show_notice() { test "${silent}" != "yes" && echo -e "[NOTICE] ${*}"; return 0; }
function show_error() { echo -e "[ERROR] ${*}" >&2;  err=1; return 1; }
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
  test -d "${script_path}" || mkdir -p "${script_path}"
  cd "${script_path}" && \
    mv -f "${tmp_dir}/${script_name}" "${script_path}/${script_name}" && chmod 640 "${script_path}/${script_name}" && \
      mv -f "${tmp_dir}/logrotate.conf" "${logrotate_config_path}"
}

uid=$(id -u)
test "${uid}"  != 0 && { show_error "Sorry, but you must run this script as root."; exit 1; }

tmp_dir="${tmpdir}/backup-functions.${$}"
mkdir -p "${tmp_dir}" && \
  fetch_files "${tmp_dir}" && \
    install_files "${tmp_dir}" && {
      show_notice "Library backup-functions (v${bfver}) was updated."
      show_notice "Logrotate config ${logrotate_config_path} was updated."
    }

test -d "${tmp_dir}" && rm -rf "${tmp_dir}"
test "${err}" -eq 1 && { show_error "Installation failed."; }
exit "${err}"
