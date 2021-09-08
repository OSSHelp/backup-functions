# backup-functions

[![Build Status](https://drone.osshelp.ru/api/badges/OSSHelp/backup-functions/status.svg)](https://drone.osshelp.ru/OSSHelp/backup-functions)

## About

This library is used for backup purposes.

Supported software:

* MySQL
* PostgreSQL
* MongoDB
* Redis
* Elasticsearch
* Clickhouse
* RabbitMQ
* SQLite
* Consul
* Gitab
* Files and directories

Upload to a remote storage:

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html)
* [Rclone](https://rclone.org/docs/)
* [lftp](https://lftp.yar.ru/lftp-man.html)
* [rsync](https://linux.die.net/man/1/rsync)

So, you can use the following protocols:

* FTP/SFTP/LFTP
* rsync
* AWS S3 (or any S3-compatible)
* OpenStack Swift
* Backblaze B2
* DigitalOcean Spaces
* Dropbox
* Google Cloud Storage
* Google Drive
* Microsoft Azure Blob Storage
* Microsoft OneDrive
* WebDAV
* Yandex Disk

It also supports:

* Compressing (zip, bzip2, pbzip2)
* Encryption
* Files splitting

### How to use it

The library must be included in the backup scripts. In the examples folder you can find examples based on `backup-functions/custom.backup` template.

How to use the library:

1. Place backup-functions.sh library in the `/usr/local/include/osshelp/` path
1. Make a backup script from the template `/usr/local/sbin/custom.backup` or from examples (or use your own ideas)
1. Run your script and check the results of it works (are there any errors?)
1. Add script to Cron job with needed schedule
1. Make sure that the script works as you expected by schedule

There’re install/update scripts in the repository. Command for installation (backup-function.sh, custom.backup template and logrotate config):

```shell
curl -s https://oss.help/scripts/backup/backup-functions/install.sh | bash
```

Or you can use this [Ansible role](https://github.com/OSSHelp/ansible-backup-functions) to install it.

If you need, you can run the custom.backup template by hands with following keys:

* `-b` or `--backup` -- runs only `make_backup` function
* `-u` or `--upload` -- runs only `upload_backup` function

This is functionality of main function. If you run custom.backup without keys it runs both functions (make_backup and upload_backup).

## FAQ

### Metrics were not sent to pushgateway. What is it and how to disable it?

By default this library tries to send metrics to local [Pushgateway](https://github.com/prometheus/pushgateway) service. If you want to disable Pushgateway usage, you can add `no_pushgateway=1` to the options section in the script.

### Default backup scheme and how can I change it?

Default backup scheme:

* 1 local copy in the `/backup` folder
* 7 daily copies in the storage
* 4 weekly copies in the storage
* 3 monthly copies in the storage

You can override it by this variables in the script:

* local_days -- how many days local copy must be kept
* remote_backups_daily -- how many daily copies you need in storage
* remote_backups_weekly -- how many weekly copies you need in storage
* remote_backups_monthly -- how many monthly copies you need in storage

### In the local backup folder one more copy than I setted. What's wrong?

That happened because of local copies being cleaned before making a new backup. So if you set the variable `local days=2` you can see 2 copies remain after cleaning + one new copy (3 local copies total).

## Author

OSSHelp Team, see <https://oss.help>
