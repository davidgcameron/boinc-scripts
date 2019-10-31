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
# Copy input files from shared dir to run dir

echo "Mounting shared directory" | vboxmonitor
sudo mount -t vboxsf shared /home/atlas/shared

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
    echo "set up http_proxy $http_proxy"|vboxmonitor
    if [ "${proxy_port}" -eq "3128" ]; then
      echo "Detected squid proxy ${hproxy} - will set in /etc/cvmfs/default.local"|vboxmonitor
      sudo sh -c "echo \"CVMFS_HTTP_PROXY='${hproxy};DIRECT'\" > /etc/cvmfs/default.local"
      sudo sh -c "echo \"CVMFS_REPOSITORIES='atlas.cern.ch,atlas-condb.cern.ch,grid.cern.ch'\" >> /etc/cvmfs/default.local"
      sudo cvmfs_config reload
    fi
  else
    echo "This vm does not need to setup an http proxy"|vboxmonitor
  fi
else
  echo "miss $init_data"|vboxmonitor
fi

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

# tty2: ATLAS Event Monitoring

cat > /home/atlas/setup_moni_on_tty2 << 'EOF_setup_moni_on_tty2'
#!/bin/bash

# add a user with limited privileges
# new user accounts are not activated by default
# activation can be done by setting a password
# here a random password is used that is only valid during the VM's lifetime
# instead of /bin/bash the new user's login shell will be /usr/local/bin/moni_on_tty2

user_on_tty="montty2"

if [[ "$(grep "^${user_on_tty}:" /etc/passwd)" == "" ]]
then
    useradd -m -k '' -s /usr/local/bin/moni_on_tty2 -U ${user_on_tty} >/dev/null 2>&1

    # setting a (random) password activates the user
    pw_length_min="17"
    pw_length_max="31"
    pw_length="$(( pw_length_min + RANDOM % $(( pw_length_max - pw_length_min )) - 2 ))"
    
    echo "${user_on_tty}:$(tr -cd a-zA-Z < /dev/urandom |head -c 1)$(tr -cd a-zA-Z0-9$%/=+~*#_,. < /dev/urandom |head -c ${pw_length})$(tr -cd a-zA-Z0-9 < /dev/urandom |head -c 1)" |chpasswd 2>/dev/null
fi

cat > /usr/local/bin/moni_on_tty2 << 'EOF_moni_on_tty2'
#!/bin/bash

# ATLAS monitoring script to be run by user montty2 at console ALT-F2 of VirtualBox VMs

# basic terminal control to keep it alive
setterm -reset 2>/dev/null
setterm -powersave off 2>/dev/null
setterm -blank 0 2>/dev/null

# start with a blank screen
printf "\033c"

# avoids a blinking cursor
tput civis


# base_location needs to be set to a place where we have read access.
base_location="/home/montty2/RunAtlas"
n_events="N/A"
n_workers="N/A"
n_finished_events="N/A"
n_finished_events_last="0"
n_events_left="-1"
time_left_reduction="0"
msg_overdue=""

pattrn1="maxEvents"
pattrn2="ISFG4SimSvc.*INFO.*Event nr.*took.*New average"


while true
do
    # collect all information that should be displayed
    # information is spread over a couple of logfiles
    # singlecore and multicore tasks use a different logfile structure
    
    main_log="$(find -L ${base_location} -name "log.EVNTtoHITS")"
    
    if [[ "${main_log}" != "" ]]
    then
        # Get total number of events from main_log
        n_events_log="$(sed -e 's/^.*maxEvents[^0-9]*\([0-9]*\)/\1/p' -n ${main_log})"
        
        if [[ "${n_events_log}" != "" ]]
        then
            n_events="${n_events_log}"
            n_workers_guess="$(find -L ${base_location} -name "AthenaMP.log" |grep -c '/worker_.*/')"

            # No worker directories? --> guess it's a singlecore setup
            # In this case event results are also written to main_log
            # but might be that the structure is not yet complete!!
            
            if (( n_workers_guess == 0 ))
            then
                n_workers_guess="1"
                athena_worker_logs="${main_log}"
            else
                # ensures the correct sort order
                athena_worker_logs1="$(find -L ${base_location} -name "AthenaMP.log" |sort |grep '/worker_./')"
                athena_worker_logs2="$(find -L ${base_location} -name "AthenaMP.log" |sort |grep '/worker_../')"
                athena_worker_logs="$(echo "${athena_worker_logs1} ${athena_worker_logs2}")"
            fi

            worker_arr=(${athena_worker_logs})
            n_finished_events_logs="$(cat $athena_worker_logs |grep -c "${pattrn2}")"
            
            if (( n_finished_events_logs > 0 ))
            then
                n_workers="${n_workers_guess}"
                n_finished_events="${n_finished_events_logs}"
                
                if (( n_finished_events == n_finished_events_last ))
                then
                    (( time_left_reduction += 60 ))
                else
                    time_left_reduction="0"
                    n_finished_events_last="${n_finished_events}"
                fi
                
                # As ETA will never be accurate I estimate it from the logfile averages values
                calc_average_logs="0"
                active_workers="0"
                
                for worker in "${worker_arr[@]}"
                do
                    # get the most recent line that includes a finished event
                    calc_average_worker="$(tac ${worker} |sed -n -e "0,/${pattrn2}/ s/^.*${pattrn2}[^0-9]*\([0-9]*\).*/\1/p")"
                    
                    if [[ "${calc_average_worker}" != "" ]]
                    then
                        (( calc_average_logs += calc_average_worker ))
                        (( active_workers ++ ))
                    fi
                    
                done

                calc_average_logs="$(( calc_average_logs / active_workers ))"
                n_events_left="$(( n_events - n_finished_events ))"

                time_left_s="$(( n_events_left * calc_average_logs / n_workers - time_left_reduction ))"
                
                if (( time_left_s < 0 ))
                then
                     msg_overdue="overdue"
                     time_left_s="$(( -time_left_s ))"
                else
                     msg_overdue=""
                fi
                
                time_left_d="$(( ${time_left_s} / 86400 ))"
                time_left_s="$(( ${time_left_s} - ${time_left_d} * 86400 ))"

                time_left_h="$(( ${time_left_s} / 3600 ))"
                time_left_s="$(( ${time_left_s} - ${time_left_h} * 3600 ))"

                time_left_m="$(( ${time_left_s} / 60 ))"

            fi
            
        fi
        
    fi
    
    
    # formatted output starts here
    # screen is already blank
    # start at upper left corner \033[0;0H
    # bold (sure this works on all terminals?): \033[1m
    # reset attributes: \033[0m
    # clear until end of line: \033[K
    # clear until end of page: \033[J

    printf "\033[0;0H"
    printf "**********************************************************************\033[K\n"
    printf "*               \033[1mATLAS (vbox) Event Progress Monitoring\033[0m               *\033[K\n"
    printf "*                               v2.0.1                               *\033[K\n"
    printf "*              last display update (VM time):  %8s              *\033[K\n" "$(date "+%T")"
    printf "**********************************************************************\033[K\n"
    printf "Number of events to be processed  :                     %14s\033[K\n" "${n_events}"
    printf "Number of events already finished :                     %14s\033[K\n" "${n_finished_events}"
    printf "Time left (rough estimate)        :             %7s " "${msg_overdue}"

    if [[ "${n_finished_events}" == "N/A" ]]
    then
        printf "           N/A\033[K\n"
    else
        printf "%5sd %2sh %2sm\033[K\n" "${time_left_d}" "${time_left_h}" "${time_left_m}"
    fi
    
    printf "%s\033[K\n" "----------------------------------------------------------------------"

    if (( n_events_left == 0 ))
    then
        printf "Calculation completed. Preparing HITS file ...\033[K\n"
    else
        printf "Last finished event(s) from %s worker logfile(s):\033[K\n" "${n_workers}"

        if [[ "${n_workers}" != "N/A" ]]
        then
            extra_space="1"; (( n_workers > 9 )) && extra_space="2"
            terminal_lines="$(( $(tput lines) - 10 ))"

            for worker_index in "${!worker_arr[@]}"
            do
                (( worker_index > terminal_lines )) && break
            
                # strip timestamps from loglines to avoid confusion
                message="$(sed -e "/${pattrn2}/ s/^.*\(Event.*\)/\1/ p" -n ${worker_arr[worker_index]} |tail -n 1)"
                [[ "${message}" == "" ]] && message="N/A"
                printf "worker %${extra_space}s: %s\033[K\n" "$(( ${worker_index} + 1 ))" "${message}"
            done
        
        fi
    
    fi
    
    # clear util end of page
    printf "\033[J"

    # avoids a blinking cursor
    tput civis

    # screen updates every 60 s
    sleep 60
done
EOF_moni_on_tty2

# must be made executable to work as shell
chmod 750 /usr/local/bin/moni_on_tty2
chown ${user_on_tty}:${user_on_tty} /usr/local/bin/moni_on_tty2


cat > /usr/local/bin/dump_atlas_logs << 'EOF_dump_atlas_logs'
#!/bin/bash

# ATLAS logs don't grant read access to other accounts but atlas
# Hence we need to dump the logs to a file where the monitoring user can read them

source_location="/home/atlas/RunAtlas"
target_location="/home/montty2/RunAtlas"

pattrn1="ISFG4SimSvc.*INFO.*Event nr.*took.*New average"

# use "install -d" instead of mkdir, chown, chmod
install -d -o montty2 -g montty2 -m 777 ${target_location}


# trigger 1: main log exists
while true
do
    main_log="$(find -L ${source_location} -name "log.EVNTtoHITS")"
    [[ "${main_log}" != "" ]] && break

    # check all 10 s (we are not in a hurry)
    sleep 10
done

# tail complete file starting at line 1
tail -f -n +1 ${main_log} >${target_location}/log.EVNTtoHITS 2>/dev/null &


# trigger 2: check if ATLAS is running singlecore or multicore
# it's singlecore if an event is logged in main_log
# it's multicore if worker dirs exist

while true
do
    # work is done if it's a singlecore
    [[ "$(grep "${pattrn1}" ${main_log})" ]] && exit 0
    
    
    # to get the correct sort order first search all /worker_x/, then all /worker_xy/
    
    athena_worker_logs1="$(find -L ${source_location} -name "AthenaMP.log" |sort |grep '/worker_./')"
    athena_worker_logs2="$(find -L ${source_location} -name "AthenaMP.log" |sort |grep '/worker_../')"
    athena_worker_logs="$(echo "${athena_worker_logs1} ${athena_worker_logs2}")"
    
    # break if it's multicore
    [[ "${athena_worker_logs}" ]] && break
    
    # check all 10 s
    sleep 10
done


# trigger 3:
# to avoid a race condition stay patient until at least 1 event has been finished
worker_arr=(${athena_worker_logs})

while true
do
    for worker_log in "${worker_arr[@]}"
    do
        [[ "$(grep "${pattrn1}" ${worker_log})" ]] && break 2
    done
    
    # check all 10 s
    sleep 10
    
    # scan for additional workers
    
    athena_worker_logs1="$(find -L ${source_location} -name "AthenaMP.log" |sort |grep '/worker_./')"
    athena_worker_logs2="$(find -L ${source_location} -name "AthenaMP.log" |sort |grep '/worker_../')"
    athena_worker_logs="$(echo "${athena_worker_logs1} ${athena_worker_logs2}")"
    
    worker_arr=(${athena_worker_logs})
done


    
# setup target dirs and start tail commands
for worker_index in "${!worker_arr[@]}"
do
    mkdir -p ${target_location}/worker_${worker_index}
    tail -f -n +1 ${worker_arr[${worker_index}]} >${target_location}/worker_${worker_index}/AthenaMP.log 2>/dev/null &
done
EOF_dump_atlas_logs

chmod 750 /usr/local/bin/dump_atlas_logs
chown root:root /usr/local/bin/dump_atlas_logs


# systemd's default service on tty2 must be modified to avoid conflicts.
# The modified service will then take care of (re)starting the top monitoring

mkdir -p /etc/systemd/system/getty@tty2.service.d


cat > /etc/systemd/system/getty@tty2.service.d/override.conf << EOF_override_tty2_service
[Unit]
Description=ATLAS (vbox) Event Monitoring - Foreground Service
BindsTo=atlasmonitoring_bg.service

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${user_on_tty} %I \$TERM
RestartSec=2
EOF_override_tty2_service


# define background service to run "dump_atlas_logs"
cat > /etc/systemd/system/atlasmonitoring_bg.service << EOF_atlasmonitoring_bg_service
[Unit]
Description=ATLAS (vbox) Event Monitoring - Background Service
BindsTo=getty@tty2.service
After=getty@tty2.service

[Service]
Type=oneshot
ExecStartPre=/bin/rm -rf /home/${user_on_tty}/RunAtlas
ExecStart=/usr/local/bin/dump_atlas_logs
RemainAfterExit=yes
ExecStopPost=/bin/rm -rf /home/${user_on_tty}/RunAtlas
EOF_atlasmonitoring_bg_service


systemctl daemon-reload

if [[ "$(systemctl show -p ActiveState getty@tty2.service)" != "ActiveState=inactive" ]] ||
   [[ "$(systemctl show -p ActiveState atlasmonitoring_bg.service)" != "ActiveState=inactive" ]]
then
        systemctl stop getty@tty2.service
        systemctl start getty@tty2.service
fi
EOF_setup_moni_on_tty2

sudo sh /home/atlas/setup_moni_on_tty2


# tty3: top
cat > /home/atlas/top_on_tty3 << 'EOF_top_on_tty3'
#!/bin/bash

# add a user with limited privileges
# new user accounts are not activated by default
# activation can be done by setting a password
# here a random password is used that is only valid during the VM's lifetime
# instead of /bin/bash the new user's login shell will be /usr/bin/topwrapper

# Thanks to volunteer computezrmle for providing this script:
# https://lhcathomedev.cern.ch/lhcathome-dev/forum_thread.php?id=494

user_on_tty="montty3"

if [[ "$(grep "^${user_on_tty}:" /etc/passwd)" == "" ]]
then
    useradd -m -k '' -s /usr/local/bin/topwrapper -U ${user_on_tty} >/dev/null 2>&1

    # setting a (random) password activates the user
    pw_length_min="17"
    pw_length_max="31"
    pw_length="$(( pw_length_min + RANDOM % $(( pw_length_max - pw_length_min )) - 2 ))"

    echo "${user_on_tty}:$(tr -cd a-zA-Z < /dev/urandom |head -c 1)$(tr -cd a-zA-Z0-9$%/=+~*#_,. < /dev/urandom |head -c ${pw_length})$(tr -cd a-zA-Z0-9 < /dev/urandom |head -c 1)" |chpasswd 2>/dev/null
fi


# a wrapper is used to execute some terminal commands before top
cat > /usr/local/bin/topwrapper << 'EOF_topwrapper'
#!/bin/bash

setterm -reset 2>/dev/null
setterm -powersave off 2>/dev/null
setterm -blank 0 2>/dev/null

top
EOF_topwrapper

chmod 750 /usr/local/bin/topwrapper
chown ${user_on_tty}:${user_on_tty} /usr/local/bin/topwrapper


# set top's secure mode as default together with an update delay of 7 seconds
cat > /etc/toprc << 'EOF_toprc'
s
7.0
EOF_toprc


# systemd's default service on tty3 must be modified to avoid conflicts.
# The modified service will then take care of (re)starting the top monitoring

mkdir -p /etc/systemd/system/getty@tty3.service.d

cat > /etc/systemd/system/getty@tty3.service.d/override.conf << EOF_override_tty3_service
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${user_on_tty} %I \$TERM
RestartSec=1
EOF_override_tty3_service


systemctl daemon-reload

if [[ "$(systemctl show -p ActiveState getty@tty3.service)" != "ActiveState=inactive" ]]
then
        systemctl stop getty@tty3.service
        systemctl start getty@tty3.service
fi
EOF_top_on_tty3

sudo sh /home/atlas/top_on_tty3


########################################
# Start the job

if [ -f /home/atlas/RunAtlas/start_atlas.sh ];then
    cd /home/atlas/RunAtlas/
    pandaid=$(tar xzf input.tar.gz -O | grep --binary-file=text -m1 -o PandaID=..........)
    taskid=$(tar xzf input.tar.gz -O | grep --binary-file=text -m1 -o taskID=........)
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
        hits=$(cat pandaJobData.out | sed 's/.*outputHitsFile[\+%3D]\([[:alnum:]._-]*\)\+.*/\1/i' | sed 's/^3D//')
        echo "Looking for outputfile $hits" | vboxmonitor
        if ls -l /home/atlas/RunAtlas/$hits 1> /dev/null 2>&1; then
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

