#!/bin/sh

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

# Bootscript script for running ATLAS@Home tasks inside a virtual machine


#############################################
# set the VM's I/O scheduler to the most simple one
# this avoids I/O requests being resorted twice (guest/host)

io_scheduler_location="/sys/block/sda/queue/scheduler"
# newer kernels
if grep 'none' ${io_scheduler_location} >/dev/null 2>&1; then
    sudo sh -c "echo 'none' >${io_scheduler_location}"
else
    # older kernels
    if grep 'noop' ${io_scheduler_location} >/dev/null 2>&1; then
        sudo sh -c "echo 'noop' >${io_scheduler_location}"
    fi
fi


#############################################
# Copy input files from shared dir to run dir
# can take a while to copy many files or large files
# hence, do it as bg process, remember it's pid
# and "wait" for that pid later

function cp_input_files {
    rm -rf /home/atlas/RunAtlas
    mkdir -p /home/atlas/RunAtlas
    sudo find /home/atlas/shared/ -type f -exec cp {} /home/atlas/RunAtlas/ \;
    sudo chown -R atlas:atlas /home/atlas/

    # Move inputs into /data so that container works. Requires container_options: -B /data in AGIS
    sudo mkdir /data
    sudo chown atlas:atlas /data
    find /home/atlas/RunAtlas -name "ATLAS.root_0" -exec mv {} /data/ \;
    find /data -type f -execdir ln -s /data/{} /home/atlas/RunAtlas/{} \;
}

stdbuf -oL echo "[INFO] Copying input files into RunAtlas..." | vboxmonitor
cp_input_files &
bg_pid_cp_input_files=$!


#############################################
# create a wpad file

rm -f /home/atlas/create_local_wpad
cp /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/create_local_wpad-${ATLAS_BRANCH_SUFFIX} -o /home/atlas/create_local_wpad
. /home/atlas/create_local_wpad
if [[ $? != 0 ]]; then
    stdbuf -oL echo "[ERROR] Failed to source 'create_local_wpad'" | vboxmonitor
    sleep 90
    sudo shutdown now
fi

bs_create_local_wpad


#############################################
# update and reload modified CVMFS configuration

stdbuf -oL echo "[INFO] Updating CVMFS configuration..." | vboxmonitor
sudo sh -c "echo \"CVMFS_REPOSITORIES=atlas.cern.ch,atlas-condb.cern.ch\" >> /etc/cvmfs/default.local"
sudo cvmfs_config reload

# print a hint to the logfile whether openhtc.io and/or a local proxy is used.
# required to identify possible misconfigurations
cvmfs_excerpt=($(cut -d ' ' -f 1,17,18 <<< "$(tail -n1 <<< "$(cvmfs_config stat atlas.cern.ch)")"))
stdbuf -oL echo "[INFO] Excerpt from \"cvmfs_config stat\": VERSION HOST PROXY" | vboxmonitor
stdbuf -oL echo "[INFO] $(echo "${cvmfs_excerpt[0]} ${cvmfs_excerpt[1]%"/cvmfs/atlas.cern.ch"} ${cvmfs_excerpt[2]}")" | vboxmonitor

if [[ "$http_proxy" != "" ]]; then
    stdbuf -oL echo "[INFO] Environment HTTP proxy: $http_proxy" | vboxmonitor
else
    stdbuf -oL echo "[INFO] Environment HTTP proxy: not set" | vboxmonitor
fi


################################################
# Copy data into web area for graphics interface

sudo cp -r /cvmfs/atlas.cern.ch/repo/sw/BOINC/www/interface/* /var/www/html
sudo cp /home/atlas/shared/init_data.xml /var/www/html/
sudo chmod a+r /var/www/html/init_data.xml
# Extract info from xml
username=`grep "<user_name" /var/www/html/init_data.xml | sed -e 's/<.*>\(.*\)<.*>/\1/'`
credit=`grep "<user_total_credit" /var/www/html/init_data.xml | sed -e 's/<.*>\(.*\)<.*>/\1/'`
sudo sh -c "echo $username > /var/www/html/user.txt"
sudo sh -c "echo $credit > /var/www/html/credit.txt"
sudo chmod a+r /var/www/html/user.txt /var/www/html/credit.txt
# Extract total number of events
sudo sh -c "tar xzf /home/atlas/RunAtlas/input.tar.gz -O | grep --binary-file=text -m1 -o -E maxEvents%3D[[:digit:]]+ | cut -dD -f2 > /var/www/html/totalevents.txt"

stdbuf -oL echo "[INFO] Copied the webapp to /var/www" | vboxmonitor


##############################################
# Cron to generate info for graphics interface

sudo sh -c 'echo "* * * * * root cd /var/www/html; python extract_info.py" > /etc/cron.d/atlas-top'


wait $bg_pid_cp_input_files
stdbuf -oL echo "[INFO] Copied input files into RunAtlas." | vboxmonitor

#############################################
# set up env for running Mcore job

core_number=`nproc`
if [ $core_number -gt 1 ];then
  export ATHENA_PROC_NUMBER=$core_number
  stdbuf -oL echo "[INFO] ATHENA_PROC_NUMBER=$ATHENA_PROC_NUMBER" | vboxmonitor
else
  stdbuf -oL echo "[INFO] core_number=$core_number" | vboxmonitor
fi

#######################################
# set up info to ttys

# Remove this cron which exists inside the vdi
sudo rm -f /etc/cron.d/atlas-events

# Get required files from cvmfs
cp -r /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/tty* /home/atlas/

# tty2: ATLAS Event Monitoring
monitor_script="/home/atlas/tty2monitor/setup_moni_on_tty2"
[[ -f "${monitor_script}" ]] && sudo sh ${monitor_script} &

# tty3: top
monitor_script="/home/atlas/tty3monitor/setup_top_on_tty3"
[[ -f "${monitor_script}" ]] && sudo sh ${monitor_script} &


########################################
# Start the job

function patch_start_atlas {
    stdbuf -oL echo "[DEVINFO] Apply experimental patch to start_atlas.sh" | vboxmonitor
    stdbuf -oL echo "[DEVINFO] To make it permanent modify the original source." | vboxmonitor
    
    rm -f /home/atlas/patchsnippet_start_atlas
    cp /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/patchsnippet_start_atlas_full-${ATLAS_BRANCH_SUFFIX} /home/atlas/patchsnippet_start_atlas
    # at least the lean patch MUST be used to make Frontier work with wpad.dat!
    # uncomment the next line if the lean patch should be used instead of the full patch
    #cp /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/patchsnippet_start_atlas_lean-${ATLAS_BRANCH_SUFFIX} /home/atlas/patchsnippet_start_atlas
    if [ "$?" -ne "0" ]; then
        stdbuf -oL echo "[ERROR] Failed to copy patchsnippet_start_atlas" | vboxmonitor
        sleep 90
        sudo shutdown now
    fi
    
    part1="$(sed '/Check for user-specific proxy/q' /home/atlas/RunAtlas/start_atlas.sh)"
    part2="$(sed -n '/Set CERN-internal proxy for CERN hosts/,$ p' /home/atlas/RunAtlas/start_atlas.sh)"

    echo "$part1" > /home/atlas/RunAtlas/start_atlas.sh
    cat /home/atlas/patchsnippet_start_atlas >> /home/atlas/RunAtlas/start_atlas.sh
    echo "$part2" >> /home/atlas/RunAtlas/start_atlas.sh
    ## cp the modification to the shared folder to allow monitoring from the host
    sudo sh -c "cp /home/atlas/RunAtlas/start_atlas.sh /home/atlas/shared/start_atlas.mod.txt"
}


if [ -f /home/atlas/RunAtlas/start_atlas.sh ];then
    patch_start_atlas
    cd /home/atlas/RunAtlas/
    pandaid=$(tar xzf input.tar.gz -O | grep --binary-file=text -m1 -o PandaID=..........)
    taskid=$(tar xzf input.tar.gz -O | grep --binary-file=text -m1 -o taskID=........)
    tar -O --strip-components=5 -xzf input.tar.gz */pandaJobData.out > pandaJob.out
    echo " *** Starting ATLAS job. ($pandaid $taskid) ***" | vboxmonitor
    sh start_atlas.sh > runtime_log 2> runtime_log.err
    RET=$?
    
    echo " *** Job finished ***" | vboxmonitor
    if [ -e /home/atlas/RunAtlas/result.tar.gz ];then
        echo " *** The last 20 lines of the pilot log: ***" | vboxmonitor
        tail -20 /home/atlas/RunAtlas/log.*.job.log.1 | vboxmonitor
    
        if [ -f /home/atlas/RunAtlas/heartbeat.json ]; then
            echo " *** Error codes and diagnostics ***" | vboxmonitor
            grep -E "[pilot|exe]Error" /home/atlas/RunAtlas/heartbeat.json | vboxmonitor
        fi
        
        echo " *** Listing of results directory ***" | vboxmonitor
        ls -lrt /home/atlas/RunAtlas/ | vboxmonitor
        
        # Check whether HITS file was produced and move it to shared
        # Extract file from job description
        hits=$(cat pandaJob.out | sed 's/.*outputHitsFile[\+%3D]\([[:alnum:]._-]*\)\+.*/\1/i' | sed 's/^3D//')
        echo "Looking for outputfile $hits" | vboxmonitor
        if [ -z "$hits" ]; then
            echo "Could not find HITS file from job description" | vboxmonitor
        elif ls -l /home/atlas/RunAtlas/$hits 1> /dev/null 2>&1; then
            echo "HITS file was successfully produced" | vboxmonitor
            ls -l /home/atlas/RunAtlas/$hits | vboxmonitor
            sudo mv /home/atlas/RunAtlas/$hits /home/atlas/shared/HITS.pool.root.1
            sudo chmod 644 /home/atlas/shared/HITS.pool.root.1
        else
            echo "No HITS file was produced" | vboxmonitor
        fi
        
        echo "Successfully finished the ATLAS job!" | vboxmonitor
        echo "Copying the results back to the shared directory!" | vboxmonitor
        sudo cp /home/atlas/RunAtlas/result.tar.gz /home/atlas/shared/
        sudo chmod 644 /home/atlas/shared/result.tar.gz
        echo " *** Contents of shared directory: ***" | vboxmonitor
        sudo ls -l /home/atlas/shared | vboxmonitor
        echo " *** Success! Shutting down the machine. ***"|vboxmonitor                
        if [ ! -f /home/atlas/noshutdown ]; then
            sudo touch /home/atlas/shared/atlas_done
            rm -f /home/atlas/RunAtlas/*
            sleep 5
        fi
    else
        echo "Failed to produce a result! Shutting down the machine." | vboxmonitor
        cat runtime_log.err runtime_log | vboxmonitor
        sleep 200
    fi
else
    echo "No ATLAS job found. Shutting down the machine." | vboxmonitor
    sleep 200
fi
rm -f /home/atlas/ATLASJobAgent.pid
if [ ! -f /home/atlas/noshutdown ]; then
    sudo shutdown now
fi
