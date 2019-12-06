#!/bin/bash

# Redirect output to stderr with timestamp
log() {
    d=$(date)
    IFS=''
    while read line
    do
        echo $d: $line 1>&2
    done
}
exec &> >(log)

cleanexit() {
  exitcode=$1
  find . -name "*log*" | xargs tar cvf shared/result.tar.gz 2>/dev/null
  sleep 600
  exit $exitcode
}

sin_image="/cvmfs/atlas.cern.ch/repo/containers/images/singularity/x86_64-centos7.img"
echo "Using singularity image $sin_image"
echo "Arguments: $@"

# Get number of threads
threads=1
if [ "$1" == "--threads" ]; then
  threads=$2
fi

echo "Threads: $threads"

# Check if job has been restarted
if [ -f runtime_log ]; then
  echo "This job has been restarted, cleaning up previous attempt"
  rm -rf output.list PandDA_Pilot*
fi

# Check CVMFS
echo "Checking for CVMFS"
which cvmfs_config &>/dev/null
if [ $? -ne 0 ]; then
  echo "No cvmfs_config command found, will try listing directly"
  timeout 60 ls -d /cvmfs/atlas.cern.ch/repo/sw > /dev/null
  if [ $? -ne 0 ]; then
    echo "Failed to list /cvmfs/atlas.cern.ch/repo/sw"
    cleanexit 1
  fi
else
  cvmfs_config probe
  if [ $? -ne 0 ]; then
    echo "cvmfs_config probe failed, aborting the job"
    cleanexit 1
  fi
  cvmfs_config stat atlas.cern.ch
  if [ $? -ne 0 ]; then
    echo "cvmfs_config stat atlas.cern.ch failed, aborting the job"
    cleanexit 1
  fi
fi
echo "CVMFS is ok"

# Check singularity executable
sin_binary="/cvmfs/atlas.cern.ch/repo/containers/sw/singularity/x86_64-el7/current/bin/singularity"
echo "Checking for singularity binary..."
sin_location=$(which singularity)
if [ $? -eq 0 ]; then
  echo "Using singularity found in PATH at ${sin_location}"
  echo "Running ${sin_location} --version"
  ${sin_location} --version
  if [ $? -ne 0 ]; then
    echo "Singularity seems to be installed but not working"
    echo "Will use version from CVMFS"
  else
    sin_binary=${sin_location}
  fi
else
  echo "Singularity is not installed, using version from CVMFS"
fi

# Check singularity works
echo "Checking singularity works with ${sin_binary} exec -B /cvmfs ${sin_image} hostname"
output=$(${sin_binary} exec -B /cvmfs ${sin_image} hostname 2>&1)
if [ $? -ne 0 ]; then
  if [[ "${sin_binary}" == "/cvmfs/"* ]] && [ `grep -c "Failed to create user namespace" ${output}` == "1" ]; then
    echo 'It looks like user namespaces are not enabled, which are required when running singularity from CVMFS.'
    echo 'Please run the following command as root to enable them:'
    echo ' echo "user.max_user_namespaces = 15000" > /etc/sysctl.d/90-max_user_namespaces.conf; sysctl -p /etc/sysctl.d/90-max_user_namespaces.conf\n'
  fi
  echo "Singularity isnt working: ${output}"
fi
echo ${output}
echo "Singularity works"

# Copy input files from shared
cp shared/* .

# Set threads for ATLAS job to use
if [ $threads -ne 1 ]; then
  echo "Set ATHENA_PROC_NUMBER=$threads"
  sed -i -e '/set -x/a\export ATHENA_PROC_NUMBER='$threads start_atlas.sh
fi

# Prepare the command to run
pandaid=$(zgrep -ao PandaID=.......... input.tar.gz)
echo "Starting ATLAS job with ${pandaid}"
cwdroot=/$(pwd | cut -d/ -f2)

cmd="${sin_binary} exec --pwd $PWD -B /cvmfs,${cwdroot} ${sin_image} sh start_atlas.sh"
echo "Running command: $cmd"
$cmd > runtime_log 2> runtime_log.err
if [ $? -ne 0 ]; then
  echo "Job failed"
  cat runtime_log.err
mv result.tar.gz shared/ 2>dev/null
  








