#!/bin/bash
# shellcheck disable=SC2059,SC1091,SC2034,SC2154
. /usr/local/include/osshelp/backup-functions.sh

cbver=1.01
# general options
backup_dir='/mnt/backup'
rclone_storage='selectel:storage'
local_days=2
remote_backups_daily=''
remote_backups_weekly=12
remote_backups_monthly=12
# functions options, excludes, etc

# main functions
function make_backup() {
   show_notice "Backup process started..."
    test -d "${backup_dir}" && clean_dir "${backup_dir}" "${local_days}"

    check_free_space "${backup_dir}" && {
        pg_dump_all "${backup_dir}/${current_date:?}"
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
