#!/bin/bash
###############################################################################
# Name: cdc_instance.sh                                                       #
# Description:                                                                #
# This script takes care of starting and stopping all CDC instances           #
# in the specified CDC home. Before starting the instance(s), the CDC         #
# binaries are copied from the central location to the local disk and the     #
# latest backup of the metadata is restored.                                  #
# Before stopping the instance, the subscriptions which are active are        #
# stopped immediately.                                                        #
#                                                                             #
# The script takes 1 parameter, action, which specifies whether the instances #
# must be started (start) or stopped (stop)                                   #
# --------------------------------------------------------------------------- #
# Change log                                                                  #
# Date     Who  Description                                                   #
# -------- ---- ------------------------------------------------------------- #
# 20160202 FK   Initial delivery                                              #
# 20160216 FK   Removed sudo calls, assuming the script will run as the CDC   #
#               owner                                                         #
# 20160226 FK   Refactored the code to have functions for common tasks        #
#               Start and stop backup process automatically                   #
#               Added init parameter to initialized shared CDC installation   #
# 20160420 FK   Included "clean" and "status" actions                         #
# 20161130 FK   Clear the staging store after instance started                #
###############################################################################

# Declarations
declare -a instances

# Initialization
SCRIPT_DIR=$( dirname $( readlink -f $0 ) )

# Read the settings from the properties file
source "$SCRIPT_DIR/conf/cdc_dr.properties"

# Import general functions
source "$SCRIPT_DIR/include/functions.sh"

#
# Function definitions
#

# Retrieve all instances
retrieveInstances() {
  log INFO "Retrieving CDC instances"
  i=0
  for instance in `ls ${cdc_home_local_fs}/instance`;do
    if [ ${instance} != "new_instance" ];then
      log INFO "Instance found: ${instance}"
      instances[$i]=${instance}
      ((i++))
    fi
  done
}

# Check if instance is active, return 0 (true) if instance is active
instanceActive() {
  ${cdc_home_local_fs}/bin/dmshowevents -I $1 > /dev/null 2>&1
  if [ $? -le 1 ];then
    return 0
  else
    return 1
  fi
}

# Start all instances
startInstances() {
  returnCode=0
  retrieveInstances
  log INFO "Starting all instances"
  for instance in ${instances[*]};do
    rm -f $cmdOut
    touch $cmdOut
    if ! instanceActive $instance;then
      log INFO "Starting instance ${instance} ..."
      nohup ${cdc_home_local_fs}/bin/dmts64 -I ${instance} >> $cmdOut &
    else
      log INFO "Instance ${instance} is already active, start not attempted"
    fi
  done
  # Wait until instances are active (maximum 30 seconds)
  log INFO "Waiting for instances to become active"
  i=0
  instancesActive=0
  while [ $i -lt 30 ] && [ ${instancesActive} -lt ${#instances[@]} ];do
    instancesActive=0
    for instance in ${instances[*]};do
      if instanceActive $instance;then
        ((instancesActive++))
      fi
    done
    sleep 1
    ((i++))
  done
  if [ $instancesActive -ne ${#instances[@]} ];then
    log ERROR "Not all instances were started"
    returnCode=1
  fi
  promoteLog $cmdOut
  return $returnCode
}


# Clear the staging store of the instances
clearStagingStore() {
  returnCode=0
  retrieveInstances
  log INFO "Clear the staging store for all instances"
  for instance in ${instances[*]};do
    rm -f $cmdOut
    touch $cmdOut
    if instanceActive $instance;then
      log INFO "Clearing staging store for instance ${instance} ..."
      ${cdc_home_local_fs}/bin/dmclearstagingstore -I ${instance} >> $cmdOut
    else
      log INFO "Instance ${instance} is not active, staging store not cleared"
    fi
  done
  promoteLog $cmdOut
  return $returnCode
}

# Stop all instances, terminate after 5 seconds
function stopInstances {
  retrieveInstances
  for instance in ${instances[*]};do
    if instanceActive $instance;then
      log INFO "Stopping instance ${instance}"
      ${cdc_home_local_fs}/bin/dmshutdown -I ${instance} &> $cmdOut
      promoteLog $cmdOut
    fi
  done
  # Wait a few seconds, then terminate instances
  sleep 5
  terminateInstances
}

function terminateInstances {
 log INFO "Terminating all CDC instances"
  ${cdc_home_local_fs}/bin/dmterminate &> $cmdOut
  promoteLog $cmdOut
}

#
# Main functions
#

# Create or replace a copy of the local CDC installation on the shared volume
init() {
  # Confirm that it is ok to stop the active instances and overwrite the shared volume
  echo "All running CDC instances on the current server will be terminated and a copy of the local installation will be made."
  read -p "Are you sure you want to terminate the instances overwrite the shared CDC installation on ${cdc_home_shared_fs} (y/N)? " doOverwrite
  if [ ${doOverwrite} == "y" ] || [ ${doOverwrite} == "Y" ];then
    # Start all instances to allow for a backup of the metadata
    startInstances
    instancesStarted=$?
    if [ $instancesStarted -ne 0 ];then
      log ERROR "Not all CDC instances were started, cannot initialize"
      exit 1
    fi
    # Run backup against all instances
    for instance in ${instances[*]};do
      log INFO "Running metadata backup for instance ${instance} ..."
      ${cdc_home_local_fs}/bin/dmbackupmd -I ${instance} &> $cmdOut
      promoteLog $cmdOut
    done
    # Now stop instances
    stopInstances
    log INFO "Copying CDC installation to shared directory ${cdc_home_shared_fs}"
    rm -rf ${cdc_home_shared_fs}/*
    cp -a ${cdc_home_local_fs}/* ${cdc_home_shared_fs}
    log INFO "Shared directory ${cdc_home_shared_fs} initialized"
  else
    log WARNING "Operation aborted, shared directory ${cdc_home_shared_fs} not initialized"
  fi
}

# Start all instances and the subscriptions sourcing the instances on the installation
start() {
  # In case any instance is started, terminate
  stopInstances
  # Remove all files from the local CDC home
  log INFO "Removing local installation of CDC from directory ${cdc_home_local_fs}"
  rm -rf ${cdc_home_local_fs}/*
  log INFO "Copying CDC installation from shared directory ${cdc_home_shared_fs}"
  cp -a ${cdc_home_shared_fs}/* ${cdc_home_local_fs}
  # Restore latest version of the metadata
  for instance in ${instances[*]};do
    backupDir=`ls -1rt ${cdc_home_local_fs}/instance/${instance}/conf/backup | tail -1`
    log INFO "Restoring latest version of the metadata, ${backupDir}, for instance ${instance}"
    cp -a ${cdc_home_local_fs}/instance/${instance}/conf/backup/${backupDir}/* ${cdc_home_local_fs}/instance/${instance}/conf/
  done
  # Now start all instances
  startInstances
  # Clean the staging store for the instances that were started
  clearStagingStore
  # Now start all subscriptions in all instances
  for instance in ${instances[*]};do
    log INFO "Starting subscriptions for instance ${instance} ..."
    ${cdc_home_local_fs}/bin/dmstartmirror -I ${instance} -A > $cmdOut
    promoteLog $cmdOut
  done
  # Start the backup process in the background, and keep the PID
  nohup ${SCRIPT_DIR}/cdc_backup_md.sh > /dev/null 2>&1 &
  backupPID=$!
  echo ${backupPID} > ${SCRIPT_DIR}/pid/cdc_backup_md.pid
  log INFO "Metadata backup process started in background with PID ${backupPID}"
}

# Stop all subscriptions sourcing the local instances and stop the instances
stop() {
  # Stop the backup background process and remove the PID file
  backupPID=$(cat ${SCRIPT_DIR}/pid/cdc_backup_md.pid)
  log INFO "Stopping the background metadata backup process with PID ${backupPID}"
  if ! kill ${backupPID} > /dev/null 2>&1;then
    log WARNING "Background metadata backup process with PID ${backupPID} was not active"
  fi
  # Stop all subscriptions controlled
  for instance in ${instances[*]};do
    log INFO "Stopping subscriptions controlled for instance ${instance}"
    if instanceActive $instance;then
      ${cdc_home_local_fs}/bin/dmendreplication -I ${instance} -A -c &> $cmdOut
      promoteLog $cmdOut
    fi
  done
  # Wait a jiffy to allow subscriptions to stop controlled
  sleep 20
  # Now stop subscriptions immediately
  for instance in ${instances[*]};do
    log INFO "Stopping subscriptions immediately for instance ${instance}"
    if instanceActive $instance;then
      ${cdc_home_local_fs}/bin/dmendreplication -I ${instance} -A -i &> $cmdOut
      promoteLog $cmdOut
    fi
  done
  # Wait again, then stop and eventually terminate instances
  sleep 10
  stopInstances
}

# Function that retrieves the status of all instances
status() {
  retrieveInstances
  instancesActive=0
  for instance in ${instances[*]};do
    if instanceActive $instance;then
      ((instancesActive++))
    fi
  done
  log INFO "Number of CDC instances that are active: ${instancesActive}"
}

# Function that really doesn't do anything but is required by Oracle Cluster Manager
clean() {
  log INFO "All clean here!"
}

#
# Main line
#

# Which action must be taken (start/stop)
ACTION=$1

# Ensure the script is not started as root
if [ $(id -u) == 0 ];then
  echo "Script cannot be run as root user. Please run it as the owner of the CDC installation"
  exit 1
fi

# Temporary file for command output
cmdOut=`mktemp`

log INFO "Command $0 executed with action ${ACTION}"
log INFO "Local file system: ${cdc_home_local_fs}"
log INFO "Shared file system: ${cdc_home_shared_fs}"

# Execute function, dependent on action specified
case "$ACTION" in
start)
  start
;;

stop)
  stop
;;

init)
  init
;;

clean)
  clean
;;

status)
  status
;;

*)
  echo "Usage: $0 start|stop|init|status|clean"
  exit 1
;;
esac


exit 0

