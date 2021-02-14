#!/bin/bash
# shellcheck disable=SC2059,SC1091,SC2034,SC2154,SC2010
. /usr/local/include/osshelp/backup-functions.sh

cbver=1.01
# general options
rclone_storage='selectel:storage'
# functions options, excludes, etc

# main functions
function make_backup() {
   show_notice "Backup process started..."
    test -d "${backup_dir}" && clean_dir "${backup_dir}" "${local_days}"

    check_free_space "${backup_dir}" && {
        mysql_dump_all "${backup_dir}/${current_date:?}/db"

        for cur_dir in $(ls -1 /home | grep -vE "${excluded_dirs}"); do
          test -d "/home/${cur_dir}" || continue
          compress_dir "/home/${cur_dir}" "${backup_dir}/${current_date}/home_${cur_dir##*/}.tar.${compress_ext:?}"
        done

        save_backup_size "${backup_dir}/${current_date}"
    }
}

function upload_backup() {
    show_notice "Upload process started..."
    rclone_sync "${backup_dir}/${current_date}" "${rclone_storage}/${type}/${current_date}"
    rclone_purge "${rclone_storage}/${type}" "${remote_backups}"
    show_notice "Upload process ended."
}

main "${@}"
