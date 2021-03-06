# Changelog

## v3.26.0

* Added function for counting files size and quantity.

## v3.25

* Fixed format parsing error (Pushgateway).

## v3.24

* Updated Pushgateway URL (resolved conflicts between scripts with the same name in difrent containers on the server).

## v3.23

* Updated Pushgateway function
* Fixed error handling

## v3.22

* Adjusted metrics generation for pushgateway.

## v3.21

* Renamed script_failure to backup_script_failure for consistency.

## v3.20

* Updated Pushgateway function
* Bugs fixed

## v3.19

* Added pushgateway functions

## v3.18

* Added rabbitmq_backup function. It installs rabbitmqadmin if necessary, exports RabbitMQ configuration, and compresses RabbitMQ datadir.
* Fixed password extraction from /root/.my.cnf for mysql_xtra_backup_db and mysql_xtra_backup_all functions

## v3.17

* Added a new version of mongo_dump_all function. The old version was renamed to mongo_dump_all_old. The new version works faster and requires less disk space and disk utilization for the dumping process.

## v3.16

* Added mysql_xtra_backup_opts array to the mysql_xtra_backup_db and mysql_xtra_backup_all functions

## v3.15

Updated rclone_purge function (added rclone_purge_opts array)
Updated excludes for shellcheck

## v3.14

* Added mysql_lxc_hotcopy_all function
* Updated rclone_sync function
* Fixed shellcheck issues

## v3.13

* Updated pg_dump_all function

## v3.12

* Deleted deprecated functions for: s3cmd, swift and supload
* Added pg_repl_ctl function (set/remove replication pause for PostgreSQL)
* Updated PostgreSQL functions (added pg_repl_ctl usage)

## v3.11

* Added new functions inc_compress_dir, consul_backup and rsync_dir
* Marked as deprecated functions for s3cmd, swift and supload utilities
* Remade detect_type function
* Updated Rclone functions

## v3.10

* Added default backup scheme to the library: 1 local backup, 7 daily backups in storage, 4 weekly backups in storage, 3 monthly backups in storage
* Added clickhouse_dump_all function
* Fixed bug in selectel_upload function
* Remade archiver choosing mechanism, added pbzip2 threads autoscaling
* Fixed bug because of which number of pbzip2 threads can't be setted
* Updated custom.backup template

## v3.06

* Added opportunity to disable archiving for MySQL dumps
* Added make_flock, detect_type and main functions
* Added custom.backup template
* Updated installer

## v3.05

* Added functions for rdiff-backup (increment backups)
* Added functions for elasticsearch backup
* Improved mongo_dump_all function (the excludes of DB list)

## v3.04

* A lot of variables changed to arrays (tar_opts e.g.)
* Fixed ShellCheck issues
* Added gitlab_backup function
* Fixed awscli_sync, ftp_clean_dir and mysql_xtra_backup_* functions
