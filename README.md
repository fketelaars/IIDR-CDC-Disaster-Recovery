# CDC Disaster Recovery Scripts

## Overview
The scripts in this directory have been designed to be able to run InfoSphere CDC in an active-passive cluster configuration in which a shared volume between the cluster nodes is available to exchange metadata and installation binaries.

Specifically, the script facilitates CDC installations in an Oracle RAC where the ASM Cluster File System (ACFS) is running. InfoSphere CDC does not support running from an ACFS due to limitations in the file system pertaining to locking of portions of files. Running CDC on unsupport file systems could lead to corruption of the metadata.

We recommend to include the instance start/stop script in the cluster management software that also manages the virtual IP address which is always on the active cluster node. This IP address (or the host name which resolves to the IP address) should be configured in the CDC Access Manager so that the CDC instance(s) can always be found on the active node.

## Installation and configuration
Copy the entire directory to a location which can be reached by all nodes which could be running CDC. This ensures that the configuration and logs can be monitored more easily. After placing the directory, review the properties file in the conf directory and set the CDC local home (will be used to place the CDC installation on the cluster nodes) and the shared CDC home (central location accessible by all cluster nodes). Also, review the timing for running the backup scripts and the number of days the backups should be retained.

After configuration, go to the cluster node that is currently running CDC and run the cdc_instance.sh script with argument "init". Example:
/shared/CDC/cdc_dr_scripts/cdc_instance.sh init

This stops the CDC instances on the current server (if active) and fully replaces the CDC installation on the configured shared volume. You must run the "init" script also after you have upgraded the CDC installation (on the local file system).

## Starting the CDC instances
To start all CDC instances and subscriptions, run the cdc_instance.sh script with option "start". Example:
/shared/CDC/cdc_dr_scripts/cdc_instance.sh start

First the script replaces the local CDC installation with the copy kept on the shared volume. Subsequently, the latest metadata backup is restarted and all subscriptions are started. Additionally, the cdc_backup_md.sh script is run as a background process; this script takes a backup of the metadata on a regular basis (configurable) and copies it to the shared volume.

## Stopping the CDC instances
To stop all CDC instances and subscriptions, run the cdc_instance.sh script with option "stop". Example:
/shared/CDC/cdc_dr_scripts/cdc_instance.sh stop

First, the script stops the cdc_backup_md.sh script that is running in the background. Subsequently, it stops all subscriptions (first controlled, and then immediately) and finally it stops the instances.