## OSSHelp backup functions library.
# shellcheck disable=SC2128,SC2191,SC2207,SC2164,SC1090,SC2219,SC2206,SC2086,SC2065,SC2034,SC2015,SC2154,SC2094
## TODO
## https://oss.help/57009
## https://oss.help/25714
## https://oss.help/38494

umask 0077
export LANG=C
export LC_ALL=C
bfver=4.0.5

## default variables
myhostname=$(hostname -f)
source=$(hostname)
script_name=${0##*/}
log_file=/var/log/${0##*/}.log
lock_file=/tmp/${0##*/}.lock
current_date=$(date '+%Y%m%d')
hourly_date=$(date '+%Y%m%d%H%M')
backup_dir='/backup'
stderr_exclude='(here_is_excluded_warning1|here_is_exluded_warning2)'
nproc=$(command -v nproc)
curl=$(command -v curl)
test -x "${nproc}" && core_num=$("${nproc}" 2>/dev/null)

## Pushgateway section
pf_lib="/usr/local/include/osshelp/pushgateway-functions.sh"
function need_metrics() { test "${no_pushgateway:-0}" == "0"; }
need_metrics && {
    test -r "${pf_lib}" -a -s "${pf_lib}" || {
        echo "Library ${pf_lib} doesn't exist!"
        exit 1
    }
    pushgateway_default_labels=(script_name="${script_name}")
    . "${pf_lib}"
}

## scheme vars
local_days=0
remote_backups_daily=7 # default if backup_type array is empty
remote_backups_weekly=4 # don't use if empty
remote_backups_monthly=3 # don't use if empty
backup_type=() # backup_type=(weekly monthly)
backup_inc_type=() # backup_inc_type=(inc full)
backup_count=() # backup_count=(4 12)
backup_date_pattern=() # backup_date_pattern=(default "$(date +%d) = 01")
backup_days_multiplier=() # backup_days_multiplier=(7 30)

## clean_dir regex var
clean_dir_regex='20[0-9][0-9][0-1][0-9][0-9][0-9]'

## enable compressing in mysql_dump_db, mysql_dump_db_tables, mongo_dump_all, sqlite_dump_db, pg_dump_all and pg_dump_db functions by default
no_compress=0

## variables for checking free space
backup_size_file=/var/backups/${0##*/}.size
backup_size_percent=10
minimum_free_space_percent=5
freespace_ratio=1

## mysql vars and arrays
mysql_ignore_databases='information_schema|performance_schema|pinba|phpmyadmin|sys'
mysql_ignore_tables=''
mysql_opts=()
mysqlopts=()
db_tables=()
#mysql_dump_opts=(-F -x --opt --events --routines --triggers)
mysql_dump_opts=(-F --opt --events --routines --triggers) ##no global locks for hostings
mysql_defaults='/etc/mysql/my.cnf'
## mysqlhotcopy arrays
mysql_hotcopy_opts=()
mysql_hotcopy_ssh_cmd=()
mysql_lxc_hotcopy_opts=()
mysql_xtra_backup_opts=()

## mongo array and var
## example: mongo_ignore_databases='config|some_db'
mongo_opts=()
mongo_ignore_databases=''

## tar arrays
tar_exclude=() #tar_exclude=(--exclude=*cache*/* --exclude=*log*/*)
tar_opts=(--ignore-failed-read "--warning=no-file-changed")

## increment tar arrays=()
inc_tar_opts=(--ignore-failed-read "--warning=no-file-changed")
inc_tar_exclude=("--exclude=var/log/*")
snap_file_dir='/backup/snap'
archive_type='' # inc or full, inc = increment type of backup

## split file size
split_file_size='1024m'

## postgres vars and arrays
pg_ignore_databases='template'
psql_opts=( -t --pset "pager=off" -A -F ' ' )
pg_dump_opts=()
pg_peplica_pause=0

## redis vars and arrays
redis_cli_opts=(--raw)
redis_rdp_location='/var/lib/redis/dump.rdb'
redis_bgsave_timeout=300
redis_bgsave_one_try_timeout=15

## vars for gitlab_backup
gitlab_skip=''        # list of what's supposed to be skipped, items separated by commas (without spaces)
gitlab_rails_env=''   # it sets evironment (production, dev, etc)
gilab_rake_bin='/usr/bin/gitlab-rake'

## gitlab_backup function usage.
##
## Check element of array gitlab_rails['backup_path'] in /etc/gitlab/gitlab.rb. It must be equals backup_dir variable in our backup script. In general this variable equals /backup, like this:
##
## gitlab_rails['backup_path'] = "/backup"
##
## Example of functions usage:
##
## backup_file=$backup_dir/$(backup_gitlab)    # extract backup filename from gitlab-rake output
## mkdir -p "$backup_dir/$current_date/"; chmod 775 "$backup_dir/$current_date/"; chown :git "$backup_dir/$current_date/"
##    { test -f "$backup_file" && mv "$backup_file" "$backup_dir/$current_date/" &&  show_notice "Moving backup file to it's folder..."; } \
##        || show_error "Backup file not found, check logs."

## lftp vars
lftp_parallel=1
test "${core_num:-1}" -gt 2 && lftp_parallel=$(( core_num / 2 ))

## example of lftp_mirror_exclude array:
## (--exclude-glob osshelp* --exclude-glob folder/folder/*)
lftp_mirror_exclude=()
lftp_mirror_opts=(-cvR --delete-first "--parallel=${lftp_parallel}" --use-cache)
lftp_opts=()
## ftp credentials
ftp_user=''
ftp_host=''
ftp_pass=''

## awscli arrays
awscli_sync_opts=()
awscli_purge_opts=()
awscli_exclude=()

## minio client arrays
minio_mirror_opts=()
minio_rm_opts=()
minio_exclude=()

## rclone vars & arrays, see https://oss.help/kb917 for ignore_codes.
rclone_alternative_conf=''
rclone_sync_opts=()
rclone_purge_opts=()
rclone_ignore_codes=()

## rdiff arrays
rdiff_opts=(-v5)
rdiff_excludes=()

## elasticsearch vars
elastic_host='localhost'
elastic_port='9200'

## clickhouse array & vars
ch_opts=("--max_threads=1")
ch_host="localhost"
ch_port="8124"
ch_user="default"
ch_pass=""

## consul shapshot saving options. e.g. -stale
consul_opts=()

## rabbitmq vars and array
rabbitmq_host="locahost:15672"
rabbitmq_datadir='/var/lib/rabbitmq/mnesia'
rabbitmqadmin_opts=()

## rsync function options array
rsync_opts=(-av)

## archiver options
## for pbzip2 you can use lower value of cores if LA is high
## use -p№, where № is the number of processors cores
archiver_opts=()

## reset global flags
glbl_backup_size=0
glbl_backup_files_cnt=0
glbl_err=0

function show_error() {
    local message="${1}"; local funcname="${2}"; log_date=$(date '+%Y/%m/%d:%H:%M:%S')
    echo -e "[ERROR.${funcname} ${log_date}] ${message}" >&2
    glbl_err=1
}

function show_notice() {
    local message="${1}"; local funcname="${2}"; log_date=$(date '+%Y/%m/%d:%H:%M:%S')
    echo -e "[NOTICE.${funcname} ${log_date}] ${message}"
}

function have_binary() { command -v "${1}" >/dev/null 2>&1; }

function pushgateway_register_metrics() {
    pushgateway_register_metric backup_is_running gauge "Сurrent state of the backup script (1 = running, 0 = exited)"
    pushgateway_register_metric backup_is_executing gauge "Сurrent state of the backup executing (1 = running, 0 = exited)"
    pushgateway_register_metric upload_is_executing gauge "Сurrent state of the backup executing (1 = running, 0 = exited)"
    pushgateway_register_metric backup_script_info gauge "Information about script and libraries."
    pushgateway_register_metric backup_script_failure gauge "Script exit status (1 = error, 0 = success)"
    pushgateway_register_metric backup_duration_seconds gauge "Script execution time, in seconds."
    pushgateway_register_metric backup_scheme gauge "Backup scheme."
    pushgateway_register_metric backup_size_bytes gauge "Last backup size in bytes."
    pushgateway_register_metric backup_files_quantity gauge "Total quantity of files in the backup."
    pushgateway_register_metric backup_required_space_bytes gauge "Required space in bytes for the backup plus some free space."
    pushgateway_register_metric backup_executing_duration_seconds gauge "Backup execution time, in seconds."
    pushgateway_register_metric backup_start_time_seconds counter "Unix timestamp of the backup script execution start."
    pushgateway_register_metric backup_end_time_seconds counter "Unix timestamp of the backup script execution end."
    pushgateway_register_metric remote_backup_size_bytes gauge "Last remote backup size in bytes."
    pushgateway_register_metric backup_uploading_duration_seconds gauge "Backup uploading time, in seconds."
    pushgateway_register_metric remote_backup_files_quantity gauge "Total quantity of files in the remote backup."
}

function pushgateway_send_backup_start() {
    backup_start_time=$(date +%s)
    pushgateway_set_value backup_is_executing 1 "${pushgateway_default_labels[@]}"
    pushgateway_send_metrics
}

function pushgateway_send_backup_end() {
    backup_end_time=$(date +%s)
    pushgateway_set_value backup_is_executing 0 "${pushgateway_default_labels[@]}"
    pushgateway_send_metrics
}

function pushgateway_send_upload_start() {
    pushgateway_set_value upload_is_executing 1 "${pushgateway_default_labels[@]}"
    pushgateway_send_metrics
}

function pushgateway_send_upload_end() {
    pushgateway_set_value upload_is_executing 0 "${pushgateway_default_labels[@]}"
    pushgateway_send_metrics
}

function pushgateway_send_upload_details() {
    local util="${1}"
    local protocol="${2}"
    local domain="${3}"
    local duration="${4}"
    local remote_size="${5}"
    local files_quantity="${6}"
    local upload_labels=(upload_util="${util}" upload_protocol="${protocol}")

    test "${domain:-unknown}" != "unknown" && \
        upload_labels+=(upload_domain="${domain}")
    test "${remote_size:-unknown}" != "unknown" && \
        pushgateway_set_value remote_backup_size_bytes ${remote_size} "${pushgateway_default_labels[@]}" "${upload_labels[@]}"
    test "${files_quantity:-unknown}" != "unknown" && \
        pushgateway_set_value remote_backup_files_quantity ${files_quantity} "${pushgateway_default_labels[@]}" "${upload_labels[@]}"
    pushgateway_set_value backup_uploading_duration_seconds ${duration} "${pushgateway_default_labels[@]}" "${upload_labels[@]}"
    pushgateway_send_metrics upload_domain="${domain}"
}

function backup_size_and_files_count() {
    local file="${1}"; local err=0
    test -f "${file}" || { show_error "Can not access ${file}!"; err=1; }
    test -f "${file}" && {
        backup_size=$(du -sb "${file}" | awk '{print $1}')
        glbl_backup_size=$((glbl_backup_size + backup_size))
        glbl_backup_files_cnt=$((glbl_backup_files_cnt + 1))
    }
    return "${err}"
}

function pushgateway_send_result() {
    local backup_err_code="${1}"
    local script_end_time
    local err=0
    script_end_time=$(date +%s)

    need_metrics || {
        show_notice "Pushgateway usage disabled."
        return "${err}"
    }
    last_backup_size_bytes=$((last_backup_size*1024*1024))
    pushgateway_set_value backup_script_info 1 "${pushgateway_default_labels[@]}" pfver="${pfver}" cbver="${cbver}" bfver="${bfver}"
    pushgateway_set_value backup_is_running 0 "${pushgateway_default_labels[@]}"
    pushgateway_set_value backup_script_failure "${backup_err_code}" "${pushgateway_default_labels[@]}"
    pushgateway_set_value backup_duration_seconds "$((script_end_time-script_start_time))" "${pushgateway_default_labels[@]}"
    pushgateway_set_value backup_scheme "${local_days}" "${pushgateway_default_labels[@]}" backup_type="local"
    pushgateway_set_value backup_scheme "${remote_backups_daily:-0}" "${pushgateway_default_labels[@]}" backup_type="daily"
    pushgateway_set_value backup_scheme "${remote_backups_weekly:-0}" "${pushgateway_default_labels[@]}" backup_type="weekly"
    pushgateway_set_value backup_scheme "${remote_backups_monthly:-0}" "${pushgateway_default_labels[@]}" backup_type="monthly"
    pushgateway_send_metrics || err=1

    test "${script_mode}" == "default" -o "${script_mode}" == "backup_only" && {
        pushgateway_set_value backup_size_bytes "${glbl_backup_size:-0}" "${pushgateway_default_labels[@]}" backup_dir="${backup_dir}"
        pushgateway_set_value backup_files_quantity "${glbl_backup_files_cnt:-0}" "${pushgateway_default_labels[@]}" backup_dir="${backup_dir}"
        test ${last_backup_size:-0} -gt 0 && \
            pushgateway_set_value backup_required_space_bytes "$((last_backup_size_bytes+last_backup_size_bytes*backup_size_percent/100))" "${pushgateway_default_labels[@]}" backup_dir="${backup_dir}" backup_size_percent="${backup_size_percent}" minimum_free_space_percent="${minimum_free_space_percent}" freespace_ratio="${freespace_ratio}"
        pushgateway_set_value backup_executing_duration_seconds "$((backup_end_time-backup_start_time))" "${pushgateway_default_labels[@]}"
        pushgateway_set_value backup_start_time_seconds "${backup_start_time}" "${pushgateway_default_labels[@]}"
        pushgateway_set_value backup_end_time_seconds "${backup_end_time}" "${pushgateway_default_labels[@]}"
        pushgateway_send_metrics || err=1
    }

    return "${err}"
}

## choosing compress
gzip=$(command -v gzip 2>/dev/null); bzcompress=$(command -v bzip2 2>/dev/null)
test "${core_num:-1}" -gt 2 && { pbzip=$(command -v pbzip2 2>/dev/null) && { archiver_opts=(-p$(( core_num / 2 ))); bzcompress="${pbzip}"; }; }
archiver_prog="${bzcompress:-${gzip}}"
test -x "${archiver_prog}" > /dev/null 2>&1 || { show_error "No compress util or ${archiver_prog} has no execution flag."; pushgateway_send_result "${glbl_err:?}"; exit 1; }

case "${archiver_prog##*/}" in
    'pbzip2' ) compress_ext='bz2' ;;
    'bzip2'  ) compress_ext='bz2' ;;
    'gzip'   ) compress_ext='gz' ;;
esac

function make_flock() {
    have_binary flock || { show_error "No flock installed. You need to install flock first."; pushgateway_send_result "${glbl_err:?}"; exit 1; }
    exec 9>> "${lock_file:?}"
    flock -n 9 || {
        show_error "Sorry, ${0##*/} is already running. Please, wait until it's finished:\n"
        have_binary pstree && pstree -Alpacu "$(cat "${lock_file}")"
        have_binary pstree || { pid=$(cat "${lock_file}"); ps f "${pid}" -"${pid}"; }
        pushgateway_send_result "${glbl_err:?}"
        exit 1
    }
    echo ${$} > "${lock_file}"
}

function detect_type() {
    test "${#backup_type[*]}" -eq 0 && {
        test -z "${remote_backups_daily}" || {
            type='daily'
            remote_backups="${remote_backups_daily:-7}"
            inc_type='inc'
            backup_days="${remote_backups}"
        }
        test "$(date +%u)" = "7" && { test -z "${remote_backups_weekly}" || {
            type='weekly'
            inc_type='full'
            remote_backups="${remote_backups_weekly}"
            backup_days=$((remote_backups_weekly*7))
        } }
        test "$(date +%d)" = "01" && { test -z "${remote_backups_monthly}" || {
            type='monthly'
            inc_type='full'
            remote_backups="${remote_backups_monthly}"
            backup_days=$((( $(date -d "${remote_backups_monthly} months" +%s) - $(date +%s)) / (60*60*24)))
        } }
    }

    test "${#backup_type[*]}" -eq 0 || {
        test "${!backup_type[*]}" = "${!backup_inc_type[*]}" || { show_error "Number of elements in the backup_type array differs from the number of elements in the backup_inc_type array. Exiting..."; pushgateway_send_result "${glbl_err:?}"; exit 1; }
        test "${!backup_type[*]}" = "${!backup_count[*]}" || { show_error "Number of elements in the backup_type array differs from the number of elements in the backup_count array. Exiting..."; pushgateway_send_result "${glbl_err:?}"; exit 1; }
        test "${!backup_type[*]}" = "${!backup_date_pattern[*]}" || { show_error "Number of elements in the backup_type array differs from the number of elements in the backup_date_pattern array. Exiting..."; pushgateway_send_result "${glbl_err:?}"; exit 1; }
        test "${!backup_type[*]}" = "${!backup_days_multiplier[*]}" || { show_error "Number of elements in the backup_type array differs from the number of elements in the backup_days_multiplier array. Exiting..."; pushgateway_send_result "${glbl_err:?}"; exit 1; }
        for index in "${!backup_type[@]}"; do
                test ${backup_date_pattern[$index]} && {
                    type="${backup_type[$index]}"
                    inc_type="${backup_inc_type[$index]}"
                    remote_backups="${backup_count[$index]}"
                    backup_days=$((remote_backups*${backup_days_multiplier[$index]}))
                }
        done
   }

   test -z "${type}" && { show_error "An error occurred while detecting backup type, check patterns in backup_date_pattern array!"; pushgateway_send_result "${glbl_err:?}"; exit 1; }
   show_notice "Backup type: ${type}, remote backups count: ${remote_backups} (${backup_days} days)."
   show_notice "Backup increment type: ${inc_type}."
}

function main() {
    {
        show_notice "Backup script started."
        need_metrics && {
            script_start_time=$(date +%s)
            pushgateway_register_metrics
            pushgateway_set_value backup_is_running 1 "${pushgateway_default_labels[@]}"
            pushgateway_send_metrics
        }
        detect_type
        make_flock

        case "${1}" in
            "--backup"|"-b")
                script_mode="backup_only"
                need_metrics && pushgateway_send_backup_start
                make_backup
                need_metrics && pushgateway_send_backup_end
            ;;
            "--upload"|"-u")
                script_mode="upload_only"
                need_metrics && pushgateway_send_upload_start
                upload_backup
                need_metrics && pushgateway_send_upload_end
            ;;
            *)
                script_mode="default"
                need_metrics && pushgateway_send_backup_start
                make_backup
                need_metrics && {
                    pushgateway_send_backup_end
                    pushgateway_send_upload_start
                }
                upload_backup
                need_metrics && pushgateway_send_upload_end
            ;;
        esac

        test "${glbl_err:?}" -eq 1 && { show_error "Script ${0##*/} failed. Please, check logs."; }
        show_notice "Backup script completed."
        pushgateway_send_result "${glbl_err}"
    } >> "${log_file}" 2>> >(tee -a "${log_file}" | grep -vE "${stderr_exclude:?}" >&2)
}

function check_free_space() {
    local dir="${1}"; local err=0
    test "${#}" -eq 1 || { show_error "Wrong function usage!" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}" || { show_error "Something is wrong with directory ${dir}" "${FUNCNAME}"; return 1; }
    test -f "${backup_size_file}" || { show_notice "File ${backup_size_file} doesn't exist! If it is first backup then it is OK." "${FUNCNAME}"; last_backup_size=0; return 0; }
    source "${backup_size_file}"
    free_space=$(df -P --block-size=1M "${dir}" | tail -1 | awk '{print $4}')
    disk_size=$(df -P --block-size=1M "${dir}" | tail -1 | awk '{print $2}')
    free_space_after_backup=$((free_space-freespace_ratio*(last_backup_size+last_backup_size*backup_size_percent/100)))
    test "${free_space_after_backup}" -gt $((disk_size*minimum_free_space_percent/100)) && \
    show_notice "Current free space: ${free_space}MB, last backup size: ${last_backup_size}MB, after backup should be avail: ${free_space_after_backup}MB. freespace_ratio=$freespace_ratio. Check OK." || \
    { show_error "Current free space: ${free_space}MB, last backup size: ${last_backup_size}MB, after backup should be avail: ${free_space_after_backup}MB. freespace_ratio=$freespace_ratio. Check FAIL."; local err=1; }
    return "${err}"
}

function save_backup_size() {
    local dir="${1}"; local err=0
    test "${#}" -eq 1 || { show_error "Wrong function usage!" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || { show_error "\"${dir}\" - it is not a directory!"; return 1; }
    backup_size=$(du --block-size=1M -s "${dir}" | awk '{print $1}')
    show_notice "Backup size is ${backup_size}MB." "${FUNCNAME}"
    echo "last_backup_size=${backup_size}" > "${backup_size_file}" || { show_error "Can't save backup size into ${backup_size_file}!" "${FUNCNAME}"; local err=1; }
    return "${err}"
}

function check_and_gen_key() {
    test -f ~/.ssh/id_rsa || ssh-keygen -f ~/.ssh/id_rsa -P ''
    test -f ~/.ssh/public.pem || { openssl rsa -in ~/.ssh/id_rsa -pubout -out ~/.ssh/public.pem > /dev/null 2>&1 && show_notice "Key has been generated." "${FUNCNAME}" && return 0; }
    key_from_id=$(openssl rsa -in ~/.ssh/id_rsa -pubout 2>/dev/null)
    curr_key=$(cat ~/.ssh/public.pem)
    test "${key_from_id}" == "${curr_key}" && { show_notice "Key has been checked. Key is correct." "${FUNCNAME}"; return 0; }
    show_error "Something is wrong with the keys. Fix them first!" "${FUNCNAME}"; return 1
}

function encrypt_files_in_dir() {
    check_and_gen_key || return 1
    local source="${1%/}"; local target="${2%/}"; local err=0
    src_dir_list=$(find "${source}" -type d); dir_list=(${src_dir_list//${source}/})
    src_file_list=$(find "${source}" -type f); file_list=(${src_file_list//${source}/})
    show_notice "Generating session.key and crypt in ${target}/session.key.enc." "${FUNCNAME}"
    session_key=$(openssl rand -base64 32); export session_key
    test -d "${target}" || mkdir -p "${target}"
    openssl rsautl -encrypt -inkey ~/.ssh/public.pem -out "${target}"/session.key.enc -pubin << EOF
${session_key}
EOF
    show_notice "Creating directory structure - ${target}" "${FUNCNAME}"
    for curr_dir in "${dir_list[@]}"; do
        test -d "${target}${curr_dir}" || mkdir -p "${target}${curr_dir}"
    done
    for curr_file in "${file_list[@]}"; do
        show_notice "Encrypting file ${source}${curr_file}" "${FUNCNAME}"
        openssl enc -aes-256-cbc -pass env:session_key -in "${source}${curr_file}" -out "${target}${curr_file}.enc" || { show_error "Something wrong with encrypt file ${source}${curr_file}" "${FUNCNAME}"; local err=1; }
    done
    return "${err}"
}

function clean_dir() {
    local err=0; local dir="${1}"; local days="${2}"
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    show_notice "Cleaning directory ${dir} older than ${days}" "${FUNCNAME}"
    test -d "${dir}" || { show_notice "Dir ${dir} doesn't exist. Skipping."; return 0; }
    find "${dir}" -maxdepth 1 -type d -mmin +$((days*60*24)) -regex "${dir}/${clean_dir_regex}" -exec rm -vrf "{}" \; || \
    { show_error "Something was wrong on clean ${dir} older than ${days}" "${FUNCNAME}"; local err=1; }
    return "${err}"
}

function mysql_dump_all() {
    local err=0; local dir="${1}"
    have_binary mysqldump || { show_error "No mysqldump installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    for current_db in $(mysql "${mysql_opts[@]}" -B -N -e "show databases;" | grep -vE "^(${mysql_ignore_databases})$"); do
        {
            show_notice "Dumping database ${current_db}" "${FUNCNAME}"
            mysqldump "${mysql_opts[@]}" "${mysql_dump_opts[@]}" "${current_db}" -r "${dir}/${current_db}.sql" && \
            nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${current_db}.sql"
        } || { show_error "Error on dumping database ${current_db}" "${FUNCNAME}"; local err=1; }
        backup_size_and_files_count "${dir}/${current_db}.sql"* || local err=1;
    done
    return "${err}"
}

function mysql_dump_db() {
    local err=0; local dir="${1}"; local db="${2}"; local prefix="${3}"
    have_binary mysqldump || { show_error "No mysqldump installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    show_notice "Dumping database ${db}" "${FUNCNAME}"
    {
        mysqldump "${mysqlopts[@]}" "${mysql_dump_opts[@]}" "${db}" "${db_tables[@]}" -r "${dir}/${db}${prefix}.sql" && \
        { test "${no_compress}" -ne 1 && { nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${db}${prefix}.sql" || local err=1; } || true; } || local err=1
        test "${err}" -eq 0 && true || false
    } || show_error "Error on dumping database ${db}" "${FUNCNAME}"
    backup_size_and_files_count "${dir}/${db}${prefix}.sql"* || local err=1;
    return "${err}"
}

function mysql_dump_all_tables() {
    local err=0; local dir="${1}"
    have_binary mysqldump || { show_error "No mysqldump installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    for current_db in $(mysql "${mysql_opts[@]}" -B -N -e "show databases;" | grep -vE "^(${mysql_ignore_databases})$"); do
        db_tables_list=($(mysql "${mysql_opts[@]}" -B -N -e "show tables;" "${current_db}" | sed "s/^/${current_db}./" | grep -vE "^($mysql_ignore_tables)$" | sed "s/^${current_db}\.//"))
        test "${#db_tables_list[*]}" -eq 0 && { show_notice "Database ${current_db} is empty, nothing to dump"; continue; }
        show_notice "Dumping database ${current_db} to separated table files" "${FUNCNAME}"
        for db_table in "${db_tables_list[@]}"; do
            show_notice "Dumping table ${db_table}"
            test -d "${dir}/${current_db}" || mkdir -p "${dir}/${current_db}"
            mysqldump "${mysqlopts[@]}" "${mysql_dump_opts[@]}" "${current_db}" "${db_table}" -r "${dir}/${current_db}/${db_table}.sql" || \
                { show_error "Error on dumping table ${current_db}.${db_table}" "${FUNCNAME}"; local err=1; }
        done
        show_notice "Compressing tables..."
        nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${current_db}"/*.sql
        for file in "${dir}/${current_db}"/*.sql*; do
            backup_size_and_files_count "${file}" || local err=1;
        done
    done
    return "${err}"
}

function mysql_dump_db_tables() {
    local err=0; local dir="${1}"; local db="${2}"; local prefix="${3}"
    have_binary mysqldump || { show_error "No mysqldump installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test "${#db_tables[*]}" -eq 0 && { db_tables=($(mysql "${mysql_opts[@]}" -B -N -e "show tables;" "${db}" | sed "s/^/${db}./" | grep -vE "^(${mysql_ignore_tables})$" | sed "s/^${db}\.//")); }
    show_notice "Dumping database ${db} to separated table files" "${FUNCNAME}"
    for db_table in "${db_tables[@]}"; do
        show_notice "Dumping table ${db_table}"
        test -d "${dir}/${db}${prefix}" || mkdir -p "${dir}/${db}${prefix}"
        mysqldump "${mysqlopts[@]}" "${mysql_dump_opts[@]}" "${db}" "${db_table}" -r "${dir}/${db}${prefix}/${db_table}${prefix}.sql" || \
            { show_error "Error on dumping table ${db_table}" "${FUNCNAME}"; local err=1; }
    done
    test "${no_compress}" -ne 1 && { nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${db}${prefix}"/*"${prefix}.sql" || local err=1; } || true
    for file in "${dir}/${db}${prefix}"/*"${prefix}.sql"*; do
        backup_size_and_files_count "${file}" || local err=1;
    done
    test "${err}" -eq 0 && true || false
    return "${err}"
}

function mysql_xtra_backup_db() {
    local err=0; local dir="${1}"; local db="${2}"
    have_binary innobackupex || { show_error "No innobackupex installed!" "${FUNCNAME}"; return 1; }
    test -f "/root/.my.cnf" || { show_error "No /root/.my.cnf file with access credintials!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    show_notice "Dumping database ${db}" "${FUNCNAME}"
    {
        innobackupex --defaults-file="${mysql_defaults}" \
        --no-timestamp --databases "${db}" --password="$(grep password /root/.my.cnf | sed -E 's/[[:space:]]*password[[:space:]]*=[[:space:]]*//g')" \
        --rsync "${mysql_xtra_backup_opts[@]}" "${dir}/${db}" 2>&1 && \
        nice -n 19 ionice -c 3 tar -cP "${tar_opts[@]}" "${dir}/${db}" | "${archiver_prog}" "${archiver_opts[@]}" > "${dir}/${db}.tar.${compress_ext}" && \
        test -d "${dir}/${db}" && rm -rf "${dir:?}/${db}"
    } || { show_error "Error on dumping database ${db}" "${FUNCNAME}"; local err=1; }
    backup_size_and_files_count "${dir}/${db}.tar.${compress_ext}" || local err=1;
    return "${err}"
}

function mysql_xtra_backup_all() {
    local err=0; local dir="${1}"
    have_binary innobackupex || { show_error "No innobackupex installed!" "${FUNCNAME[0]}"; return 1; }
    test -f "/root/.my.cnf" || { show_error "No /root/.my.cnf file with access credintials!" "${FUNCNAME[0]}"; return 1; }
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME[0]}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    show_notice "Dumping all databases" "${FUNCNAME[0]}"
    {
        innobackupex --defaults-file="${mysql_defaults}" \
            --password="$(grep password /root/.my.cnf | sed -E 's/[[:space:]]*password[[:space:]]*=[[:space:]]*//g')" \
            --no-timestamp --rsync "${mysql_xtra_backup_opts[@]}" "${dir}/alldb/mysql" 2>&1 && \
        { show_notice "Applying logs"; innobackupex --apply-log "${dir}/alldb/mysql" 2>&1; } && \
        nice -n 19 ionice -c 3 tar -cP "${tar_opts[@]}" "${dir}/alldb" | "${archiver_prog}" "${archiver_opts[@]}" > "$dir/alldb.tar.${compress_ext}" && \
        test -d "${dir}/alldb" && rm -rf "${dir:?}/alldb"
    } || { show_error "Error on making full dump" "${FUNCNAME[0]}"; local err=1; }
    backup_size_and_files_count "$dir/alldb.tar.${compress_ext}" || local err=1;
    return "${err}"
}

function sqlite_dump_db() {
    local err=0; local dir="${1}"; local db_path="${2}"; local dump_name=${3:-$(basename "${db_path}")}
    have_binary sqlite3 || { show_error "No sqlite3 installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong usage of the function! Args=${*}" "$FUNCNAME"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    show_notice "Dumping sqlite database ${db}" "${FUNCNAME}"
    {
        sqlite3 "${db_path}" .dump > "${dir}/${dump_name}.sql" && \
        { test "${no_compress}" -ne 1 && { nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${dump_name}.sql" || local err=1; } || true; } || local err=1
        test "${err}" -eq 0 && true || false
    } || show_error "Error on dumping database ${db_path}" "${FUNCNAME}"
    backup_size_and_files_count "${dir}/${dump_name}.sql"* || local err=1;
    return "${err}"
}

function mongo_dump_all() {
    local err=0; local dir="${1}"
    have_binary mongodump || { show_error "No mongodump installed." "${FUNCNAME}"; return 1;}
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    for current_db in $(echo 'show dbs' | mongo "${mongo_opts[@]}" --quiet | awk '{print $1}' | grep -vE "^(${mongo_ignore_databases})$"); do
        {
            show_notice "Dumping database ${current_db}" "${FUNCNAME}"
            test "${no_compress}" -ne 0 && nice -n 19 ionice -c 3 mongodump "${mongo_opts[@]}" --quiet -d "${current_db}" --archive="${dir}/${current_db}.dump"
            test "${no_compress}" -eq 0 && nice -n 19 ionice -c 3 mongodump "${mongo_opts[@]}" --quiet -d "${current_db}" --archive | \
            "${archiver_prog}" "${archiver_opts[@]}" > "${dir}/${current_db}.${compress_ext}"
            backup_size_and_files_count "${dir}/${current_db}"* || local err=1;
        } || { show_error "Error on dumping database ${current_db}" "${FUNCNAME}"; local err=1; }
    done
    return "${err}"
}

function mongo_dump_all_old() {
    local err=0; local dir="${1}"
    have_binary mongodump || { show_error "No mongodump installed." "${FUNCNAME}"; return 1;}
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    for current_db in $(echo 'show dbs' | mongo "${mongo_opts[@]}" --quiet | awk '{print $1}' | grep -vE "^(${mongo_ignore_databases})$"); do
        {
            show_notice "Dumping database ${current_db}" "${FUNCNAME}"
            nice -n 19 ionice -c 3 mongodump "${mongo_opts[@]}" --quiet -d "${current_db}" -o "${dir}/${current_db}" && \
            nice -n 19 ionice -c 3 tar -C "${dir}" -c "${current_db}" | "${archiver_prog}" "${archiver_opts[@]}" > "${dir}/${current_db}.tar.${compress_ext}" && \
            test -d "${dir}/${current_db}" && rm -rf "${dir:?}/${current_db}"
            backup_size_and_files_count "${dir}/${current_db}"* || local err=1;
        } || { show_error "Error on dumping database ${current_db}" "${FUNCNAME}"; local err=1; }
    done
    return "${err}"
}

function compress_dir() {
    local err=0; local source=${1:1}; local target="${2}"; target_dir=$(dirname "${target}")
    test "${#}" -eq 2 || { show_error "Wrong function usage!" "${FUNCNAME}"; return 1; }
    test -d "/${source}" || { show_error "Directory /${source} does not exist!" "${FUNCNAME}"; return 1; }
    test -d "${target_dir}" || mkdir -p "${target_dir}"
    show_notice "Compress ${source} to ${target}" "${FUNCNAME}"
    nice -n 19 ionice -c 3 tar -cC / "${tar_opts[@]}" "${tar_exclude[@]}" "${source}" | "${archiver_prog}" "${archiver_opts[@]}" > "${target}" || \
    { show_error "Error on: tar -cC / ${tar_opts[*]} ${tar_exclude[*]} ${source} | ${archiver_prog} ${archiver_opts[*]} > ${target} ${FUNCNAME}"; local err=1; }
    backup_size_and_files_count "${target}" || local err=1;
    return "${err}"
}

function inc_compress_dir() {
    local err=0; local source=${1}; local target="${2}"; local arc_type="${3}"
    target_dir=$(dirname "${target}"); mask="${target%%.*}"; snap_file="${snap_file_dir}/${mask##*/}.snap"; suffix='full'
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong function usage!" "${FUNCNAME}"; return 1; }
    test -d "${source}" || { show_error "Directory ${source} does not exist!" "${FUNCNAME}"; return 1; }
    test "${arc_type}" != "inc" && test -f "${snap_file}" && rm "${snap_file}"
    test "${arc_type}" = "inc" && test -f "${snap_file}" && suffix='increment'
    test -d "${snap_file_dir}" || mkdir -p "${snap_file_dir}"
    test -d "${target_dir}" || mkdir -p "${target_dir}"
    show_notice "Making ${suffix} archive from ${source} to ${target%%.*}.${suffix}.tar.${compress_ext}" "${FUNCNAME}"
    nice -n 19 ionice -c 3 tar -cg "${snap_file}" "${inc_tar_opts[@]}" "${inc_tar_exclude[@]}" -C "${source}" . | "${archiver_prog}" "${archiver_opts[@]}" > "${target%%.*}.${suffix}.tar.${compress_ext}" || \
    { show_error "Error on: tar -cg ${snap_file} ${inc_tar_opts[*]} ${inc_tar_exclude[*]} -C ${source} . | ${archiver_prog} ${archiver_opts[*]} > ${target%%.*}.${suffix}.tar.${compress_ext}" "${FUNCNAME}"; local err=1; }
    backup_size_and_files_count "${target}" || local err=1;
    return "${err}";
}

function split_file() {
    local err=0; local target="${1}"; suffix="$(basename "${target}")-"
    test "${#}" -eq 1 || { show_error "Wrong usage of the function!" "${FUNCNAME}"; return 1; }
    show_notice "Split file started \"split -b ${split_file_size} -d ${target} ${suffix}\"" "${FUNCNAME}"
    cd "$(dirname "${target}")"
    nice -n 19 ionice -c 3 split -b "${split_file_size}" -d "${target}" "${suffix}" || { show_error "Error on: split -b ${split_file_size} -d ${target} ${suffix}" "${FUNCNAME}"; return 1; }
    test -f "${target}" && rm -f "${target}" || { show_error "Error on: test -f ${target} && rm -f ${target}" "${FUNCNAME}"; local err=1; }
    return "${err}"
}

function pg_repl_ctl {
    local err=0; local rpl_status="${1}"; local psql_ver='unknown'
    local repl_stop_command='pg_xlog_replay_pause'; repl_resume_command='pg_xlog_replay_resume'; repl_status_command='pg_is_xlog_replay_paused'
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}. Use this function with pause/resume arg only." "${FUNCNAME}"; return 1; }
    have_binary psql || { show_error "No psql installed!" "${FUNCNAME}"; return 1; }
    psql_ver=$(psql -V | grep -Po '\s\d+.\d+\s' | cut -d. -f1)
    test "${psql_ver}" = "unknown" && { show_error "Can't get PostgreSQL version!" "${FUNCNAME}"; return 1; }
    test "${psql_ver}" -ge "10" && { repl_stop_command="pg_wal_replay_pause"; repl_resume_command="pg_wal_replay_resume"; repl_status_command="pg_is_wal_replay_paused"; }
    test "${rpl_status}" == "pause" && {
        show_notice "Pausing the replication" "${FUNCNAME}"
        psql "${psql_opts[@]}" -c "SELECT ${repl_stop_command}();" >/dev/null
        psql "${psql_opts[@]}" -c "SELECT ${repl_status_command}();" | grep -q '^t$' || {
                show_error "Error while pausing the replication!" "${FUNCNAME}"; local err=1
        }
        test "${err}" == "0" && show_notice "The replication is now on pause" "${FUNCNAME}"
    }
    test "${rpl_status}" == "resume" && {
        show_notice "Resuming the replication" "${FUNCNAME}"
        psql "${psql_opts[@]}" -c "SELECT ${repl_resume_command}();" >/dev/null
        psql "${psql_opts[@]}" -c "SELECT ${repl_status_command}();" | grep -q '^f$' || {
            show_error "Error while resuming the replication!" "${FUNCNAME}"; local err=1
        }
        test "${err}" == "0" && show_notice "The replication is now off pause" "${FUNCNAME}"
    }
    return "${err}"
}

function pg_dump_all() {
    local err=0; local dir="${1}"
    have_binary pg_dump || { show_error "No pg_dump installed!" "${FUNCNAME}"; return 1; }
    have_binary psql || { show_error "No psql installed!" "${FUNCNAME}"; return 1; }
    have_binary pg_dumpall || { show_error "No pg_dumpall installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    test "${pg_peplica_pause}" -ne 0 && { pg_repl_ctl pause || local err=1; }
    for current_db in $(psql "${psql_opts[@]}" -c 'SELECT datname from pg_database' | grep -vE ${pg_ignore_databases}); do
        {
            show_notice "Dumping database ${current_db}" "${FUNCNAME}"
            pg_dump "${pg_dump_opts[@]}" -Fc "${current_db}" > "${dir}/${current_db}.pgdmp" || local err=1
            test "${no_compress}" -ne 1 && { nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${current_db}.pgdmp" || local err=1; }
            test "${err}" -eq 0 && true || false
            backup_size_and_files_count "${dir}/${current_db}"* || local err=1;
        } || { show_error "Error on dumping database ${current_db}" "${FUNCNAME}"; local err=1; }
    done
    show_notice "Dumping global objects" "${FUNCNAME}"
    pg_dumpall "${pg_dump_opts[@]}" --globals-only > "${dir}/globals.sql" && \
    nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/globals.sql" || \
    { show_error "Error on dumping global objects" "${FUNCNAME}"; local err=1; }
    backup_size_and_files_count "${dir}/globals.sql"* || local err=1;
    test "${pg_peplica_pause}" -ne 0 && { pg_repl_ctl resume || local err=1; }
    return "${err}"
}

function pg_dump_db() {
    local err=0; local dir="${1}"; local db="${2}"; local prefix="${3}"
    have_binary pg_dump || { show_error "No pg_dump installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    show_notice "Dumping database ${db}" "${FUNCNAME}"
    {
        test "${pg_peplica_pause}" -ne 0 && { pg_repl_ctl pause || local err=1; }
        pg_dump "${pg_dump_opts[@]}" -Fc "${db}" > "${dir}/${db}${prefix}.pgdmp" || local err=1
        test "${no_compress}" -ne 1 && { nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${db}${prefix}.pgdmp" || local err=1; }
        test "${err}" -eq 0 && true || false
        backup_size_and_files_count "${dir}/${db}${prefix}"* || local err=1;
    } || { show_error "Error on dumping database ${db}" "${FUNCNAME}"; local err=1; }
    test "${pg_peplica_pause}" -ne 0 && { pg_repl_ctl resume || local err=1; }
    return "${err}"
}

function redis_rdb_backup() {
    local err=0; local dir="${1}"; local seconds=0
    have_binary redis-cli || { show_error "Not found redis-cli." "${FUNCNAME}"; return 1;}
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    lastsave_before=$(echo lastsave | redis-cli "${redis_cli_opts[@]}")
    echo bgsave | redis-cli "${redis_cli_opts[@]}"
    while [ "${seconds}" -lt "${redis_bgsave_timeout}" ]; do
        sleep "${redis_bgsave_one_try_timeout}"
        let seconds=seconds+"${redis_bgsave_one_try_timeout}"
        lastsave_after=$(echo lastsave | redis-cli "${redis_cli_opts[@]}")
        show_notice "Curent seconds: ${seconds}. Lastsave before: ${lastsave_before}, lastsave after: ${lastsave_after}." "${FUNCNAME}"
        test "x${lastsave_before}" != "x${lastsave_after}" && {
            show_notice "Saving ${redis_rdp_location} to ${dir}/${current_date}-redis.rdb, and compress" "${FUNCNAME}"
            cp "${redis_rdp_location}" "${dir}/${current_date}-redis.rdb" && \
            nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${current_date}-redis.rdb" || \
            { show_error "Error on copy and compress ${redis_rdp_location}" "${FUNCNAME}"; local err=1; }
            backup_size_and_files_count "${dir}/${current_date}-redis.rdb"* || local err=1;
            return "${err}"
        }
    done
    show_error "Attempt to backup redis rdb has ended by timeout: ${redis_bgsave_timeout} seconds!" "${FUNCNAME}"; return 1
}

function backup_gitlab() {
    "${gilab_rake_bin}" gitlab:backup:create \
        ${gitlab_skip:+SKIP\=$gitlab_skip} \
        ${gitlab_rails_env:+RAILS_ENV\=$gitlab_rails_env} | tee -a "${log_file}" | grep -Po '\S+\.tar' \
            || { show_error "${FUNCNAME[0]} error, check logs"; return 1; }
}

function rclone_sync() {
    local source="${1}"
    local target="${2}"
    local mode="${3:-default}"
    local err=0
    local start_time
    local end_time
    local duration
    local protocol
    local detected_domain
    local upload_domain
    local remote_backup_values
    local remote_files
    local remote_size
    have_binary rclone || { show_error "Install rclone first!" "${FUNCNAME[0]}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME[0]}"; return 1; }
    show_notice "Sync ${source} to ${target}" "${FUNCNAME[0]}"
    start_time=$(date +%s)
    rclone -v "${rclone_sync_opts[@]}" sync "${source}" "${target}" 2>&1 || {
        local rclone_error=$?; local ignore_error=0
        for code in "${rclone_ignore_codes[@]}"; do
            test "${code}" -eq "${rclone_error}" && { ignore_error=1; break; }
        done
        test "${ignore_error}" -eq 0 && show_error "Error on rclone_sync ${source} to ${target} with code ${rclone_error}" "${FUNCNAME[0]}"; err=1
    }
    test "${mode}" != "no_check" && {
        remote_backup_values=$(rclone size "${target}")
        remote_files=$(echo "${remote_backup_values}" | grep 'Total objects:' | awk '{print $3}')
        remote_size=$(echo "${remote_backup_values}" | grep -oP '\(\d+\sByte.*?\)' | grep -oP '\d+')
    }
    need_metrics && {
        end_time=$(date +%s)
        duration=$((end_time-start_time))
        protocol=$(rclone config show ${target%:*} | grep -m1 'type' | awk '{print $3}')
        detected_domain=$(rclone config show ${target%:*} | grep -Em1 'endpoint|host' | awk '{print $3}' | sed -r 's/(\w+:\/\/)?([a-z0-9\.\-]+)(\/?.+)?/\2/')
        test -z "${detected_domain}" || upload_domain="${detected_domain}"
        test "${protocol}" == "b2" && upload_domain="backblaze.com"
        pushgateway_send_upload_details "rclone" "${protocol}" "${upload_domain:-unknown}" "${duration}" "${remote_size:-unknown}" "${remote_files:-unknown}"
    }
    return "${err}"
}

function rclone_purge() {
    local err=0; local target="${1}"; local count="${2}"; local rclone_conf="${rclone_alternative_conf:-/root/.config/rclone/rclone.conf}"
    have_binary rclone || { show_error "Install rclone first!" "${FUNCNAME}"; return 1; }
    test -f "${rclone_conf}" || { show_error "Can't find rclone configuration file (${rclone_conf}), you need to configure rclone or set alternative path to config by rclone_alternative_conf variable." "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    rclone -q lsd "${target}"> /dev/null 2>&1 || { show_error "Smth went wrong while listing rclone storages."; local err=1; }
    total=$(rclone -q lsd "${target}" | wc -l)
    to_delete=$((total - count))
    test "${to_delete}" -gt 0 && {
        for var in $(rclone -q lsd "${target}" | grep -E '20[0-9][0-9][0-1][0-9][0-9][0-9]' | head -n "${to_delete}" | awk '{print $5}'); do
            show_notice "Deleting ${var}" "${FUNCNAME}"
            rclone --config "${rclone_conf}" -v "${rclone_purge_opts[@]}" purge "${target}/${var}" 2>&1 || { show_error "Error on rclone purge ${var}" "${FUNCNAME}"; local err=1; }
        done
    } || show_notice "Nothing to purge." "${FUNCNAME}"
    return "${err}"
}

function awscli_sync() {
    local source="${1}"
    local target="${2}"
    local profile="${3}"
    local mode="${4:-default}"
    local awscli_profile=()
    local err=0
    local start_time
    local end_time
    local duration
    local detected_domain
    local upload_domain
    local remote_files
    local remote_size
    local protocol
    have_binary aws || { show_error "Install awscli first!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || test "${#}" -eq 4 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${source}" || { show_error "Directory ${source} does not exist!" "${FUNCNAME}"; return 1; }
    show_notice "Upload ${source} to ${target}" "${FUNCNAME}"
    test -n "${profile}" && awscli_profile=(--profile "${profile}")
    start_time=$(date +%s)
    nice -n 19 ionice -c 3 aws s3 sync "${source}" "${target}" "${awscli_profile[@]}" "${awscli_sync_opts[@]}" "${awscli_exclude[@]}" || {
        test "${?}" == "1" && { show_error "Error on awscli_sync ${source} to ${target}" "${FUNCNAME}"; local err=1; }
    }
    test "${mode}" != "no_check" && {
        rmt_bckp_values=$(aws s3 ls --recursive --summarize "${target}" "${awscli_profile[@]}" | tail -2)
        remote_files=$(echo "${rmt_bckp_values}" | grep 'Total Objects:' | grep -oP '\d+')
        remote_size=$(echo "${rmt_bckp_values}" | grep 'Total Size:' | grep -oP '\d+')
    }
    need_metrics && {
        end_time=$(date +%s)
        duration=$((end_time-start_time))
        detected_domain=$(aws configure get s3.endpoint_url "${awscli_profile[@]}" | sed -r 's/(\w+:\/\/)?([a-z0-9\.\-]+)(\/?.+)?/\2/')
        test -z "${detected_domain}" || upload_domain="${detected_domain}"
        pushgateway_send_upload_details "awscli" "s3" "${upload_domain:-unknown}" "${duration}" "${remote_size:-unknown}" "${remote_files:-unknown}"
    }
    return "${err}"
}

function awscli_clean() {
    local err=0; local target="${1}"; local count="${2}"; local profile="${3}"
    have_binary aws || { show_error "Install awscli first!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -n "${profile}" && awscli_purge_opts+=(--profile "${profile}")
    total=$(aws s3 ls "${target}"/ "${awscli_purge_opts[@]}" | grep -cE '20[0-9][0-9][0-1][0-9][0-9][0-9]')
    to_delete=$((total - count))
    test "${to_delete}" -gt 0 && {
    for var in $(aws s3 ls "${target}"/ "${awscli_purge_opts[@]}" | grep -E '20[0-9][0-9][0-1][0-9][0-9][0-9]' | sort | head -n "${to_delete}" | awk '{print $2}' | cut -d / -f 1); do
        show_notice "Deleting ${var}" "${FUNCNAME}"
        aws --recursive s3 rm "${target}/${var}" "${awscli_purge_opts[@]}" 2>&1 || { show_error "Error on awscli remove ${var}" "${FUNCNAME}"; local err=1; }
    done
    } || show_notice "Nothing to delete." "${FUNCNAME}"
    return "${err}"
}

function minio_mirror() {
    local source="${1}"
    local target="${2}"
    local mode="${3:-default}"
    local err=0
    local start_time
    local end_time
    local duration
    local protocol
    local detected_domain
    local upload_domain
    local remote_files
    local remote_size
    have_binary minio-client || { show_error "No minio-client binary found, skipping mirroring." "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || test "${#}" -eq 3 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${source}" || { show_error "Directory ${source} does not exist!" "${FUNCNAME}"; return 1; }
    show_notice "Mirroring ${source} to ${target}" "${FUNCNAME}"
    start_time=$(date +%s)
    nice -n 19 ionice -c 3 minio-client mirror --quiet --overwrite --remove "${minio_mirror_opts[@]}" "${minio_exclude[@]}" "${source}" "${target}" || {
        test "${?}" == "1" && { show_error "An error occured on mirroring ${source} to ${target}" "${FUNCNAME}"; err=1; }
    }
    test "${mode}" != "no_check" && {
        have_binary jq || { show_error "No jq binary found. Install jq or set mode to no_check." "${FUNCNAME}"; return 1; }
        minio_json=$(minio-client ls -r --summarize --json "${target}")
        remote_files=$(jq '. | select(.totalObjects | length >= 1) | .totalObjects' <<< "${minio_json}")
        remote_size=$(jq '. | select(.totalObjects | length >= 1) | .totalSize' <<< "${minio_json}")
    }
    need_metrics && {
        have_binary jq || { show_error "No jq binary found. Can't collect metrics properly." "${FUNCNAME}"; return 1; }
        detected_domain=$(minio-client alias list ${target%%/*} --json | jq -r .URL | sed -r 's/(\w+:\/\/)?([a-z0-9\.\-]+)(\/?.+)?/\2/')
        end_time=$(date +%s)
        duration=$((end_time-start_time))
        test -z "${detected_domain}" || upload_domain="${detected_domain}"
        pushgateway_send_upload_details "minio-client" "s3" "${upload_domain:-unknown}" "${duration}" "${remote_size:-unknown}" "${remote_files:-unknown}"
    }
    return "${err}"
}

function minio_clean() {
    local err=0; local target="${1}"; local count="${2}"
    have_binary minio-client || { show_error "No minio-client binary found, skipping cleaning." "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    total=$(minio-client ls "${target}"  | grep -cE '20[0-9][0-9][0-1][0-9][0-9][0-9]')
    to_delete=$((total - count))
    test "${to_delete}" -gt 0 && {
    for var in $(minio-client ls "${target}" | grep -oE '20[0-9][0-9][0-1][0-9][0-9][0-9]' | sort | head -n "${to_delete}"); do
        show_notice "Deleting ${var}" "${FUNCNAME}"
        minio-client rm --recursive --force "${minio_rm_opts[@]}" "${target}/${var}" 2>&1 || { show_error "An error has occur when removing ${var}" "${FUNCNAME}"; local err=1; }
    done
    } || show_notice "Nothing to delete." "${FUNCNAME}"
    return "${err}"
}

function ftp_mirror_dir() {
    local err=0; local source="${1}"; local target="${2}"
    have_binary lftp || { show_error "Install lftp first!" "$FUNCNAME"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -z "${ftp_host}" && test -z "${ftp_user}" && test -z "${ftp_pass}" && { show_error "Wrong usage of the function! Set \$ftp_host, \$ftp_user, \$ftp_pass variables." "${FUNCNAME}"; return 1; }
    show_notice "Mirroring ${source} to ftp://${ftp_host}${target}" "${FUNCNAME}"
    lftp -e "set ftp:list-options -a ${lftp_opts[*]}; mirror ${lftp_mirror_opts[*]} ${lftp_mirror_exclude[*]} ${source} ${target}; exit" -u "${ftp_user}","${ftp_pass}" "${ftp_host}" || { show_error "Error on ftp_upload ${source} to ftp://${ftp_host}${target}" "${FUNCNAME}"; local err=1; }
    return "${err}"
}

function ftp_put_file() {
    local err=0; local source="${1}"; local target="${2}"
    have_binary lftp || { show_error "Install lftp first!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -z "${ftp_host}" && test -z "${ftp_user}" && test -z "${ftp_pass}" && { show_error "Wrong usage of the function! Set \$ftp_host, \$ftp_user, \$ftp_pass variables." "${FUNCNAME}"; return 1; }
    show_notice "Uploading ${source} to ftp://${ftp_host}${target}" "${FUNCNAME}"
    lftp -e "put -a ${source} -o ${target}; exit" -u "${ftp_user}","${ftp_pass}" "${ftp_host}" || { show_error "Error on ftp_upload ${source} to ftp://${ftp_host}${target}" "${FUNCNAME}"; local err=1; }
    return "${err}"
}

function ftp_clean_dir() {
    local total=0; local err=0; local total=0; local target="${1}"; local count="${2}"
    have_binary lftp || { show_error "Install lftp first!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -z "${ftp_host}" || test -z "${ftp_user}" || test -z "${ftp_pass}" && { show_error "Wrong usage of the function! Set \$ftp_host, \$ftp_user, \$ftp_pass variables." "${FUNCNAME}"; return 1; }
    lftp -e "cd ${target}; exit" -u ${ftp_user},${ftp_pass} ${ftp_host} > /dev/null 2>&1 || { show_error "No folder ${target} in ${ftp_user}@${ftp_host} or wrong connection options!" "${FUNCNAME}"; return 1; }
    show_notice "Cleaning dir ftp://${ftp_host}${target}" "${FUNCNAME}"
    total=$(lftp -e "cls -1 --sort=name $target; exit" -u ${ftp_user},${ftp_pass} ${ftp_host} | grep -cE '20[0-9][0-9][0-1][0-9][0-9][0-9]')
    local to_delete=$((total - count))
    test "${to_delete}" -gt 0 && {
            for var in $(lftp -e "cls -1 --sort=name ${target}; exit" -u ${ftp_user},${ftp_pass} ${ftp_host} | grep -E '20[0-9][0-9][0-1][0-9][0-9][0-9]' | head -n ${to_delete}); do
                    show_notice "Deleting ${var}" "${FUNCNAME}"
                    lftp -e "rm -r ${var}; exit" -u ${ftp_user},${ftp_pass} ${ftp_host} || { show_error "Somthing wrong on delete ftp://${ftp_host}${target}" "${FUNCNAME}"; local err=1; }
            done
    } || show_notice "Nothing to delete from ftp://${ftp_host}${target}" "${FUNCNAME}"
    return "${err}"
}

function rdiff_backup() {
    local err=0; local src="${1}"; local dst="${2}"
    have_binary rdiff-backup || { show_error "No rdiff-backup installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dst}" || mkdir -p "${dst}"
    show_notice "Making rdiff backup" "${FUNCNAME}"
    nice -n 19 ionice -c 3 rdiff-backup "${rdiff_opts[@]}" "${rdiff_excludes[@]}" "${src}" "${dst}" || local err=1
    return "${err}"
}

function rdiff_clean_by_quantity() {
    local err=0; local target="${1}"; local quantity="${2}"
    have_binary rdiff-backup || { show_error "No rdiff-backup installed!" "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${target}" || { show_error "Directory not found: ${target}" "${FUNCNAME}"; return 1; }
    show_notice "Cleaning rdiff backup if more then ${quantity} copies are available" "${FUNCNAME}"
        total=$(rdiff-backup --list-increments "${target}" | grep -cE '20[0-9][0-9]-[0-1][0-9]-[0-9][0-9]')
        local to_delete=$((total - quantity +1))
        test "${to_delete}" -gt 1 && {
                    bck_date=$(rdiff-backup --list-increments "${target}" | grep -oE '20[0-9][0-9]-[0-1][0-9]-[0-9][0-9]' | head -n ${to_delete} | tail -1)
                    show_notice "Deleting backups older than ${bck_date}" "${FUNCNAME}"
                    rdiff-backup --remove-older-than "${bck_date}" --force --print-statistics "${target}" || { show_error "Something went wrong on deleting copies older than ${bck_date}." "${FUNCNAME}"; local err=1; }
        } || show_notice "Nothing to delete." "${FUNCNAME}"
    return "${err}"
}

function elastic_backup() {
    local err=0; local elastic_repo="${1}"; local elastic_url="http://${elastic_host}:${elastic_port}"
    test -z "${elastic_host}" || test -z "${elastic_port}" && { show_error "Wrong usage of the function! Set \$elastic_host and \$elastic_port variables." "${FUNCNAME}"; return 1; }
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    have_binary curl || { show_error "Curl binary is not available, check it."; return 1; }
    show_notice "Creating snapshots in repository \"${elastic_repo}\"" "${FUNCNAME}"
    for indice in $(curl -XGET "${elastic_url}/_cat/indices" 2>/dev/null | awk '{print $3}'); do
        show_notice "Creating snapshot_${indice}_${current_date}" "${FUNCNAME}"
        curl -s -H 'Content-Type: application/json' -XPUT "${elastic_url}/_snapshot/${elastic_repo}/snapshot_${indice}_${current_date}?wait_for_completion=true" -d '{"indices":"'"${indice}"'"}' | grep -q 'SUCCESS' || {
            show_error "Smth went wrong while creating \"snapshot_${indice}_${current_date}\", manual check needed. Maybe, you tried to make backup second time on the same day?" "${FUNCNAME}"
            local err=1
        }
    done
    return "${err}"
}

function elastic_clean() {
    local err=0; local elastic_repo="${1}"; local elastic_url="http://${elastic_host}:${elastic_port}"; local snapshot_lifelimit=$((${2}*86400))
    test -z "${elastic_host}" || test -z "${elastic_port}" && { show_error "Wrong usage of the function! Set \$elastic_host and \$elastic_port variables." "${FUNCNAME}"; return 1; }
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    have_binary curl || { show_error "Curl binary is not available, check it."; return 1; }
    show_notice "Deleting old snapshots from repository \"${elastic_repo}\"" "${FUNCNAME}"
    for snapshot in $(curl -s -XGET "${elastic_url}/_cat/snapshots/${elastic_repo}" | awk '{print $1}'); do
        snapshot_timestamp=$(curl -s -XGET "${elastic_url}/_cat/snapshots/${elastic_repo}" | grep -E "^${snapshot}\s" | awk '{print $3}')
        current_timestamp=$(date +%s)
        snapshot_lifetime=$((current_timestamp-snapshot_timestamp))
        test "${snapshot_lifelimit}" -le "${snapshot_lifetime}" && {
            show_notice "Deleting ${snapshot}" "${FUNCNAME}"
            curl -s -H 'Content-Type: application/json' -XDELETE "${elastic_url}/_snapshot/${elastic_repo}/${snapshot}?pretty" | grep -q 'true' || {
                show_error "Smth went wrong while deleting \"${snapshot}\" from repository \"${elastic_repo}\", manual check needed." "${FUNCNAME}"
                local err=1
            }
        }
    done
    return "${err}"
}

function clickhouse_dump_all() {
    local err="0"; local dir="${1}";
    have_binary clickhouse-client || { show_error "No clickhouse-client installed!" "${FUNCNAME}"; return "1"; }
    test "${#}" -eq "1" || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return "1"; }
    test -z "${ch_host}" || test -z "${ch_user}" && { show_error "Wrong usage of the function! Set at least \$ch_host and \$ch_user variables." "${FUNCNAME}"; return 1; }
    test -z "${ch_pass}" || ch_credentials=(--host="${ch_host}" --port="${ch_port}" --user="${ch_user}" --password="${ch_pass}")
    test -z "${ch_pass}" && ch_credentials=(--host="${ch_host}" --port="${ch_port}" --user="${ch_user}")
    test -d "${dir}" || mkdir -p "${dir}"
    local db_list=($(clickhouse-client "${ch_credentials[@]}" "${ch_opts[@]}" --query="SHOW DATABASES"))
    test -z "${db_list[0]}" && { show_notice "No clickhouse databases found!" "${FUNCNAME}"; return 1; }
    for current_db in "${db_list[@]}"; do
        test "${current_db}" == "system" && continue
        show_notice "Getting list of tables in database \"${current_db}\"" "${FUNCNAME}"
        local table_list=($(clickhouse-client "${ch_credentials[@]}" --query="SHOW TABLES FROM ${current_db}"))
        test -z "${table_list[0]}" && { show_notice "No tables found in database \"${current_db}\"" "${FUNCNAME}"; continue; }
        for current_table in "${table_list[@]}"; do
            [[ "${current_table}" == ".inner."* ]] && continue
            show_notice "Dumping table \"${current_table}\"" "${FUNCNAME}"
            { clickhouse-client "${ch_credentials[@]}" "${ch_opts[@]}" --query="SHOW CREATE TABLE ${current_db}.${current_table}" > "${dir}/${current_db}.${current_table}.sql" && \
                nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${current_db}.${current_table}.sql"; } || {
                    show_error "Smth went wrong while running SHOW CREATE TABLE ${current_db}.${current_table}"; local err=1; }
            { clickhouse-client "${ch_credentials[@]}" "${ch_opts[@]}" --query="SELECT * FROM ${current_db}.${current_table} FORMAT CSVWithNames" > "${dir}/${current_db}.${current_table}.csv" && \
                nice -n 19 ionice -c 3 "${archiver_prog}" "${archiver_opts[@]}" -f "${dir}/${current_db}.${current_table}.csv"; } || {
                    show_error "Smth went wrong while running SELECT * FROM ${current_db}.${current_table} FORMAT CSVWithNames"; local err=1; }
            backup_size_and_files_count "${dir}/${current_db}.${current_table}.sql"* || local err=1;
            backup_size_and_files_count "${dir}/${current_db}.${current_table}.csv"* || local err=1;
        done
    done
    return "${err}";
}

function consul_backup() {
    local dir="${1}"
    have_binary consul || { show_error "Not found consul." "${FUNCNAME}"; return 1;}
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    show_notice "Start saving consul shapshot into the ${dir}..."
    consul snapshot save "${consul_opts[@]}" "${dir}/consul.snap" || { show_error "An error has occurred while saving the snapshot." "${FUNCNAME}"; return 1;}
    backup_size_and_files_count "${dir}/consul.snap" || local err=1;
    show_notice "Process has been completed successfully."
}

function rsync_dir() {
    local err=0; local source=${1}; local target="${2}"
    test "${#}" -eq 2 || { show_error "Wrong function usage!" "${FUNCNAME}"; return 1; }
    have_binary rsync || { show_error "Rsync utility didn't found!" "${FUNCNAME}"; return 1; }
    test -d "${target}" || mkdir -p "${target}"
    show_notice "Syncing ${source} to ${target} with rsync..." "${FUNCNAME}"
    nice -n 19 ionice -c 3 rsync "${rsync_opts[@]}" "${source}" "${target}" || \
    { show_error "Error has occurred while syncing ${source} to ${target} with rsync ${FUNCNAME}"; local err=1; }
    return "${err}"
}

function mysql_lxc_hotcopy_all() {
    local err=0; local dir="${1}"; local tmpdir="${2}"
    test "${#}" -eq 2 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    test -d "${tmpdir}" || mkdir -p "${tmpdir}"
    for current_db in $(mysql "${mysql_lxc_hotcopy_opts[@]}" -B -N -e "show databases;" | grep -vE "^(${mysql_ignore_databases})$"); do
        {
            show_notice "Creating backup of database ${current_db}" "${FUNCNAME}"
            "${mysql_hotcopy_ssh_cmd[@]}" "mysqlhotcopy ${mysql_hotcopy_opts[*]} ${current_db} ${tmpdir}" && \
            nice -n 19 ionice -c 3 tar -cP "${tar_opts[@]}" "${tmpdir}/${current_db}" | "${archiver_prog}" "${archiver_opts[@]}" > "${dir}/${current_db}.tar.${compress_ext:?}" && \
            test -d "${tmpdir}/${current_db}" && rm -rf "${tmpdir:?}/${current_db}"
            backup_size_and_files_count "${dir}/${current_db}.tar.${compress_ext:?}" || local err=1;
        } || { show_error "An error has occurred when creating backup of database ${current_db}" "${FUNCNAME}"; local err=1; }
    done
    return "${err}"
}

function rabbitmq_backup() {
    local err=0; local dir="${1}"
    have_binary rabbitmqadmin || {
        wget -q "http://${rabbitmq_host}/cli/rabbitmqadmin" -O /usr/local/sbin/rabbitmqadmin || {
            show_error "No rabbitmqadmin installed and downloading it from http://${rabbitmq_host}/cli/rabbitmqadmin imposible!" "${FUNCNAME}"
            return 1
        }
        test -x /usr/local/sbin/rabbitmqadmin || chmod 700 /usr/local/sbin/rabbitmqadmin
    }
    test "${#}" -eq 1 || { show_error "Wrong usage of the function! Args=${*}" "${FUNCNAME}"; return 1; }
    test -d "${dir}" || mkdir -p "${dir}"
    show_notice "Exporting RabbitMQ and making an archive of mnesia directory..." "${FUNCNAME}"
    rabbitmqadmin export "${rabbitmqadmin_opts[@]}" "${dir}/rabbitmq_configuration.json" || {
        show_error "An error occurred while exporting RabbitMQ!" "${FUNCNAME}"
        local err=1
    }
    compress_dir "${rabbitmq_datadir}" "${dir}/rabbitmq_data.tar.${compress_ext}" || {
        show_error "An error occurred while archiving ${rabbitmq_datadir}!" "${FUNCNAME}"
        local err=1
    }
    backup_size_and_files_count "${dir}/rabbitmq_configuration.json" || local err=1;
    return "${err}"
}
