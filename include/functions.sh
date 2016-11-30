# Function to log messages to the designated log
function log {
  msgType=$1
  msg=$2
  curDate=`date +%Y-%m-%d`
  hostName=`hostname -s`
  timeStamp=`date +"%Y-%m-%d %H:%M:%S"`
  echo $hostName $timeStamp $1 $2
  echo $hostName $timeStamp $1 $2 >> ${logdir}/`basename $0`_${curDate}.log
}

# Function to read the output of a command and promote it to
# the designated log file
function promoteLog {
  inputLogFile=$1
  IFS=$'\n'
  for line in `cat ${inputLogFile}`;do
    if [ "${line}" != "" ];then
      log CMDINFO ${line}
    fi
  done
}
