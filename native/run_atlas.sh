#!/bin/bash

# Copyright 2019 CERN for the benefit of the ATLAS collaboration.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Bootscript script for running native ATLAS@Home tasks

# Prefix stdout and stderr with timestamp; redirect all otutput to stderr
# flush awk's buffers after each printed line
exec &> >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush(); }' 1>&2)

cleanexit() {
  exitcode=$1
  find . -name "*log*" | xargs tar cvf shared/result.tar.gz 2>/dev/null
  sleep 600
  exit $exitcode
}

echo "Arguments: $@"

# Get number of threads
threads=1
if [ "$1" = "--nthreads" ]; then
  threads=$2
fi

echo "Threads: $threads"

# Check if job has been restarted
if [ -f runtime_log ]; then
  echo "This job has been restarted, cleaning up previous attempt"
  rm -rf output.list PanDA_Pilot*
fi

# Check CVMFS
echo "Checking for CVMFS"
if ! which cvmfs_config &>/dev/null; then
  echo "No cvmfs_config command found, will try listing directly"
  if ! timeout 60 ls -d /cvmfs/atlas.cern.ch/repo/sw > /dev/null; then
    echo "Failed to list /cvmfs/atlas.cern.ch/repo/sw"
    echo "** It looks like CVMFS is not installed on this host."
    echo "** CVMFS is required to run ATLAS native tasks and can be installed following https://cvmfs.readthedocs.io/en/stable/cpt-quickstart.html"
    echo "** and setting 'CVMFS_REPOSITORIES=atlas.cern.ch,atlas-condb.cern.ch' in /etc/cvmfs/default.local"
    cleanexit 1
  fi
else
  if ! cvmfs_config probe atlas.cern.ch atlas-condb.cern.ch; then
    echo "cvmfs_config probe atlas.cern.ch atlas-condb.cern.ch failed, aborting the job"
    cleanexit 1
  fi
  echo "Running cvmfs_config stat atlas.cern.ch"
  cvmfs_config_stat="$(cvmfs_config stat atlas.cern.ch)"
  echo "$cvmfs_config_stat"
  if [[ "$?" != "0" ]]; then
    echo "cvmfs_config stat atlas.cern.ch failed, aborting the job"
    cleanexit 1
  fi
fi
echo "CVMFS is ok"

# check from cvmfs_config output whether openhtc is used and whether a local proxy is used.
openhtc_is_used="$(grep -c '\.openhtc\.io' <<<"$cvmfs_config_stat")"
local_proxy_not_used="$(grep -c 'DIRECT' <<<"$cvmfs_config_stat")"

if [[ "$openhtc_is_used" == "0" ]] || [[ "$local_proxy_not_used" != "0" ]]; then
    echo "Efficiency of ATLAS tasks can be improved by the following measure(s):"
    if [[ "$openhtc_is_used" == "0" ]]; then
        echo "The CVMFS client on this computer should be configured to use Cloudflare's openhtc.io."
    fi
    if [[ "$local_proxy_not_used" != "0" ]]; then
        echo "Small home clusters do not require a local http proxy but it is suggested if"
        echo "more than 10 cores throughout the same LAN segment are regularly running ATLAS like tasks."
    fi
    echo "Further information can be found at the LHC@home message board."
fi

# Check if singularity is required
# Plain CentOS7 doesn't work (SIGBUS errors) without certain packages installed
# so always use singularity
sin_required=yes

if [ "$sin_required" = "yes" ]; then
  # Check singularity executable
  sin_image="/cvmfs/atlas.cern.ch/repo/containers/fs/singularity/x86_64-centos7"
  echo "Using singularity image $sin_image"

  sin_binary="/cvmfs/atlas.cern.ch/repo/containers/sw/singularity/x86_64-el7/current/bin/singularity"
  echo "Checking for singularity binary..."
  if sin_location=$(which singularity); then
    echo "Using singularity found in PATH at ${sin_location}"
    echo "Running ${sin_location} --version"
    if ! ${sin_location} --version; then
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
  if ! output=$(${sin_binary} exec -B /cvmfs ${sin_image} hostname 2>&1); then
    if [[ "${sin_binary}" == "/cvmfs/"* ]] && [ $(echo "$output" | grep -c "Failed to create user namespace") = "1" ]; then
      echo 'It looks like user namespaces are not enabled, which are required when running singularity from CVMFS.'
      echo 'Please run the following command as root to enable them:'
      echo ' echo "user.max_user_namespaces = 15000" > /etc/sysctl.d/90-max_user_namespaces.conf; sysctl -p /etc/sysctl.d/90-max_user_namespaces.conf'
    fi
    echo "Singularity isnt working: ${output}"
    cleanexit 1
  fi
  echo ${output}
  echo "Singularity works"
fi

# Copy input files from shared
ln -f shared/* .

# Create a copy of the job description
tar -O --strip-components=5 -xzf input.tar.gz --wildcards '*/pandaJobData.out' > pandaJob.out
if [ ! -s pandaJob.out ]; then
  echo "Failed to extract job description from input tarball"
  cleanexit 1
fi

# Set threads for ATLAS job to use
if [ $threads -ne 1 ]; then
  echo "Set ATHENA_PROC_NUMBER=$threads"
  export ATHENA_PROC_NUMBER=$threads
fi

# Prepare the command to run
pandaid=$(zgrep -ao PandaID=.......... input.tar.gz)
echo "Starting ATLAS job with ${pandaid}"

sin_cmd=""
if [ "$sin_required" = "yes" ]; then
  cwdroot=/$(pwd | cut -d/ -f2)
  sin_cmd="${sin_binary} exec --pwd $PWD -B /cvmfs,${cwdroot} ${sin_image} "
fi
cmd="${sin_cmd}sh start_atlas.sh"
echo "Running command: $cmd"
$cmd > runtime_log 2> runtime_log.err

# Check result and output files
if [ $? -ne 0 ]; then
  echo "Job failed"
  cat runtime_log.err
  cleanexit 1
fi

# Print some information from logs
echo " *** The last 200 lines of the pilot log: ***"
logfile=$(cat pandaJob.out | sed 's/.*logFile=\([[:alnum:]._-]*\)\+.*/\1/i' | sed 's/.tgz//')
tail -200 "$logfile" | cut -c-200

if [ -f heartbeat.json ]; then
  echo " *** Error codes and diagnostics ***"
  grep -E "[pilot|exe]Error" heartbeat.json
fi

echo " *** Listing of results directory ***"
ls -lrt

# Move results to shared
mv result.tar.gz shared/ 2>/dev/null
# Extract file from job description
hits=$(cat pandaJob.out | sed 's/.*outputHitsFile[\+%3D]\([[:alnum:]._-]*\)\+.*/\1/i' | sed 's/^3D//')
if [ -z "$hits" ]; then
  echo "Could not find HITS file from job description"
elif ls -l "$hits" 1> /dev/null 2>&1; then
  mv "$hits" shared/HITS.pool.root.1 2>/dev/null
  echo "HITS file was successfully produced:"
  ls -l shared/HITS.pool.root.1
else
  echo "No HITS result produced"
fi

echo " *** Contents of shared directory: ***"
ls -lrt shared/

# spend a second to work against the race condition introduced by output redirection
sleep 1

exit 0

