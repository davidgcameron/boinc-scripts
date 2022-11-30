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

if [ ! -z "$ATLAS_BRANCH_SUFFIX" ]; then
    echo "This is the ${ATLAS_BRANCH_SUFFIX} version of the ATLAS job wrapper" | vboxmonitor
fi

#############################################
# Copy input files from shared dir to run dir

echo "Copying input files" | vboxmonitor
rm -rf /home/atlas/RunAtlas
mkdir -p /home/atlas/RunAtlas
sudo find /home/atlas/shared/ -type f -exec cp {} /home/atlas/RunAtlas/ \;
sudo chown -R atlas:atlas /home/atlas/

# Move inputs into /data so that container works. Requires container_options: -B /data in AGIS
sudo mkdir /data
sudo chown atlas:atlas /data
find /home/atlas/RunAtlas -name "ATLAS.root_0" -exec mv {} /data/ \;
find /data -type f -execdir ln -s /data/{} /home/atlas/RunAtlas/{} \;
echo "Copied input files into RunAtlas." | vboxmonitor

#############################################
# add required repositories to the CVMFS configuration

sudo sh -c "echo \"CVMFS_REPOSITORIES=atlas.cern.ch,atlas-condb.cern.ch\" >> /etc/cvmfs/default.local"

#############################################
# set up http proxy for hosts behind firewall

init_data=/home/atlas/shared/init_data.xml
if [ -f $init_data ];
then
  use_proxy=`grep use_http_proxy/ $init_data`
  proxy_server=` grep http_server_name $init_data |awk -F '>' '{print $2}'|awk -F "<" '{print $1}'|sed -e "s# #_#g"`
  proxy_port=` grep http_server_port $init_data |awk -F '>' '{print $2}'|awk -F "<" '{print $1}'|sed -e "s# #_#g"`
  if [ ! -z "$use_proxy" -a ! -z "$proxy_server" -a ! -z "$proxy_port" ];
  then 
    hproxy=http://$proxy_server:$proxy_port
    export http_proxy=$hproxy
    echo "Detected user-configured HTTP proxy at ${hproxy} - will set in /etc/cvmfs/default.local"|vboxmonitor
    sudo sh -c "echo \"CVMFS_HTTP_PROXY=\\\"${hproxy};DIRECT\\\"\" >> /etc/cvmfs/default.local"
  else
    echo "This VM did not configure a local http proxy via BOINC."|vboxmonitor
    echo "Small home clusters do not require a local http proxy but it is suggested if"|vboxmonitor
    echo "more than 10 cores throughout the same LAN segment are regularly running ATLAS like tasks."|vboxmonitor
    echo "Further information can be found at the LHC@home message board."|vboxmonitor
  fi
  sudo cvmfs_config reload
  echo "Running cvmfs_config stat atlas.cern.ch"|vboxmonitor
  cvmfs_config stat atlas.cern.ch|vboxmonitor
else
  echo "miss $init_data"|vboxmonitor
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
echo "copied the webapp to /var/www"|vboxmonitor

##############################################
# Cron to generate info for graphics interface

sudo sh -c 'echo "* * * * * root cd /var/www/html; python extract_info.py" > /etc/cron.d/atlas-top'

#############################################
# set up env for running Mcore job

core_number=`nproc`
if [ $core_number -gt 1 ];then
  export ATHENA_PROC_NUMBER=$core_number
  echo ATHENA_PROC_NUMBER=$ATHENA_PROC_NUMBER | vboxmonitor
else
  echo core_number=$core_number | vboxmonitor
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

if [ -f /home/atlas/RunAtlas/start_atlas.sh ];then
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
