#!/bin/bash
###############################################################################
# Name: cdc_backup_md.sh                                                      #
# Description:                                                                #
# This script takes a periodic backup of the CDC metadata for all CDC         #
# instances and copies the backup to the shared file system, to be used when  #
# CDC is started on a different node than the current one.                    #
#                                                                             #
# --------------------------------------------------------------------------- #
# Change log                                                                  #
# Date     Who  Description                                                   #
# -------- ---- ------------------------------------------------------------- #
# 20160216 FK   Initial delivery                                              #
# 20160226 FK   Delete backups older than x days                              #
#                                                                             #
###############################################################################

# Initialization
SCRIPT_DIR=$( dirname $( readlink -f $0 ) )

# Read the settings from the properties file
source "$SCRIPT_DIR/conf/cdc_dr.properties"

# Import general functions
source "$SCRIPT_DIR/include/functions.sh"

# Which action must be taken (start/stop)
ACTION=$1

doLoop=1

# Temporary file for command output
cmdOut=`mktemp`

log INFO "Command $0 executed"
log INFO "Local file system: ${cdc_home_local_fs}"
log INFO "Shared file system: ${cdc_home_shared_fs}"

function exit_loop {
  log INFO "Stopping metadata backup background process"
  doLoop=0
}

trap exit_loop SIGHUP SIGINT SIGTERM

# Retrieve instances
log INFO "Retrieving CDC instances"
declare -a instances
i=0
for instance in `ls ${cdc_home_local_fs}/instance`;do
  if [ ${instance} != "new_instance" ];then
    log INFO "Instance found: ${instance}"
    instances[$i]=${instance}
    i+=1
  fi
done

# Run a periodic metadata backup against all instances and copy it over
# to the shared directory
while [ ${doLoop} -eq 1 ];do
  # Run backup against all instances
  for instance in ${instances[*]};do
    log INFO "Running metadata backup for instance ${instance} ..."
    ${cdc_home_local_fs}/bin/dmbackupmd -I ${instance} &> $cmdOut
    cmdExitCode=$?
    promoteLog $cmdOut
    # If the command was executed successfully, copy the backup to the shared volume
    if [ $cmdExitCode -eq 0 ];then
      backupDir=`ls -1rt ${cdc_home_local_fs}/instance/${instance}/conf/backup | tail -1`
      log INFO "Backup executed successfully, copying backup ${backupDir} to shared volume ${cdc_home_shared_fs}"
      mkdir -p ${cdc_home_shared_fs}/instance/${instance}/conf/backup
      cp -a ${cdc_home_local_fs}/instance/${instance}/conf/backup/${backupDir} ${cdc_home_shared_fs}/instance/${instance}/conf/backup/
      # Delete old backups from the shared volume
      log INFO "Deleting backups for instance ${instance} older than ${cdc_md_backup_retention_days} days from volume ${cdc_home_shared_fs}"
      find ${cdc_home_shared_fs}/instance/${instance}/conf/backup/* -mtime +${cdc_md_backup_retention_days} -print -delete > $cmdOut
      promoteLog $cmdOut
      # Delete old backups from the local volume
      log INFO "Deleting backups for instance ${instance} older than ${cdc_md_backup_retention_days} days from volume ${cdc_home_local_fs}"
      find ${cdc_home_local_fs}/instance/${instance}/conf/backup/* -mtime +${cdc_md_backup_retention_days} -print -delete > $cmdOut
      promoteLog $cmdOut
    else
      log ERROR "Backup of instance ${instance} did not complete successfully"
    fi
  done
  # Wait for the specified number of minutes before running a backup again
  log INFO "Waiting for ${cdc_md_backup_interval_min} minutes until next backup"
  # Sleep in a background process so that the current process can be trapped by a SIG
  cdc_md_backup_interval_sec=$((${cdc_md_backup_interval_min}*60))
  sleep ${cdc_md_backup_interval_sec} &
  wait
done

log INFO "Metadata backup background process stopped"

exit 0
