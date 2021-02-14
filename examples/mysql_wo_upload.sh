#!/bin/bash
# shellcheck disable=SC2059,SC1091,SC2034,SC2154
. /usr/local/include/osshelp/backup-functions.sh

cbver=1.01
# general options
# functions options, excludes, etc

# main functions
function make_backup() {
   show_notice "Backup process started..."
    test -d "${backup_dir}" && clean_dir "${backup_dir}" "${local_days}"

    check_free_space "${backup_dir}" && {
        mysql_dump_all "${backup_dir}/${current_date:?}/db"
        save_backup_size "${backup_dir}/${current_date}"
    }
}

function upload_backup() {
    show_notice "Upload disabled"
}

main "${@}"
