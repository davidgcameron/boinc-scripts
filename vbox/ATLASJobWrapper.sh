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
    
    chpasswd <<< "${user_on_tty}:$(head -c 1 < <(tr -cd a-zA-Z < /dev/urandom))$(head -c ${pw_length} < <(tr -cd a-zA-Z0-9$%/=+~*#_,. < /dev/urandom))$(head -c 1 < <(tr -cd a-zA-Z0-9 < /dev/urandom))" 2>/dev/null
fi

cat > /usr/local/bin/moni_on_tty2 << 'EOF_moni_on_tty2'
#!/bin/bash

# ATLAS monitoring script to be run by user montty2 at console ALT-F2 of VirtualBox VMs


function get__n_events__n_workers {
    local ppid="${1}"
    local logfile="${2}"
    
    # wait until "pattrn" appears in logfile
    # run as background job that dies when it's parent "pid ${1}" exits
    pattrn="^.*maxEvents =[^0-9]*"
    logline="$(grep -E -m 1 -s "${pattrn}" <(tail -F -n +1 --pid ${ppid} ${logfile} 2>/dev/null) 2>/dev/null)"
    
    # a simple method to return a parameter back to the calling program
    n_events="$(sed -e "0,/${pattrn}/ s/${pattrn}\([0-9]\+\).*/\1/p" -n <<< "${logline}")"
    echo "n_events=\"${n_events}\"" >>${para_file}


    # it's a multicore if ATHENA_PROC_NUMBER is in the log before maxEvents
    pattrn="^.*ATHENA_PROC_NUMBER set to[^0-9]*"
    n_workers="$(sed -e "0,/${pattrn}/ s/${pattrn}\([0-9]\+\).*/\1/p" -n ${logfile})"
    # it's a singlecore if ATHENA_PROC_NUMBER is missing
    [[ ! "${n_workers}" ]] && n_workers="1"
    
    echo "n_workers=\"${n_workers}\"" >>${para_file}

    for (( i=0; i<n_workers; ++i ))
    do
        echo "w_msg_arr[${i}]=\"N/A\"" >>${para_file}
    done

}


function get_worker_status {
    local ppid="${1}"
    local logfile="${2}"
    local worker_index="${3}"
    
    # wait until "pattrn" appears in logfile
    # run as background job that dies when it's parent "pid ${1}" exits
    pattrn="^.*AthenaEventLoopMgr.*INFO.*start processing event"
    grep -E -m 1 -s "${pattrn}" <(tail -F -n +1 --pid ${ppid} ${logfile} 2>/dev/null) >/dev/null 2>&1

    # a simple method to return a parameter back to the calling program
    echo "w_msg_arr[${worker_index}]=\"Event nr. 1 processing\"" >>${para_file}
}


function format_timestring {
    time_s="${1}"
    
    time_d="$(( time_s / 86400 ))"
    time_s="$(( time_s - time_d * 86400 ))"
    
    time_h="$(( time_s / 3600 ))"
    time_s="$(( time_s - time_h * 3600 ))"
    
    time_m="$(( time_s / 60 ))"

    
    if (( time_d != 0 ))
    then
        time_string="$(printf "%5s d %2s h %2s min" "${time_d}" "${time_h}" "${time_m}")"
    else

        if (( time_h != 0 ))
        then
            time_string="$(printf "        %2s h %2s min" "${time_h}" "${time_m}")"
        else
            time_string="$(printf "             %2s min" "${time_m}")"
        fi
    
    fi

    echo "${time_string}"
}


function update_display_on_tty {
    # formatted output starts here
    # screen is already blank
    # don't blank it again to avoid flickering
    # instead start at upper left corner \033[0;0H
    # bold (sure this works on all terminals?): \033[1m
    # reset attributes: \033[0m
    # clear until end of line: \033[K
    # clear until end of page: \033[J
    # version string is hardcoded to ensure it is centered
    
    printf "\033[0;0H"
    printf "***************************************************\033[K\n"
    printf "*         \033[1mATLAS Event Progress Monitoring\033[0m         *\033[K\n"
    printf "*                     v3.2.0                      *\033[K\n"

    if [[ "${1}" == "starting" ]]
    then
        printf "*                    Starting                     *\033[K\n"
        printf "***************************************************\033[K\n"
    else
        printf "*     last display update (VM time): %8s     *\033[K\n" "$(date "+%T")"
        printf "***************************************************\033[K\n"
        printf "Number of events\033[K\n"
        printf "   total            :                       %7s\033[K\n" "${n_events}"
        printf "   already finished :                       %7s\033[K\n" "${n_finished_events}"
        printf "Event runtimes\033[K\n"
        printf "   arithmetic mean  :                       %7s\033[K\n" "${rntme_arth_mean}"
        printf "   min / max        :             %17s\033[K\n" "${rntme_min_max}"
        printf "Estimated time left\033[K\n"
        printf "   total            :  %8s %19s\033[K\n" "${msg_overtime}" "${time_left}"
        printf "   uncertainty      :           %19s\033[K\n" "${time_left_uncert}"
        printf "%s\033[K\n" "---------------------------------------------------"

        if [[ "${n_workers}" != "N/A" ]] &&
           [[ "${n_events}" != "N/A" ]]
        then
            printf "Status of last event per worker thread:\033[K\n"

            for (( i=1; i<=n_workers; i++ ))
            do
                printf "worker %${#n_workers}s: %s\033[K\n" "${i}" "${w_msg_arr[$(( i - 1 ))]}"
            done
        
        fi
    
        if (( n_events_left == 0 ))
        then
            printf "%s\033[K\n" "---------------------------------------------------"
            printf "Calculation completed. Preparing HITS file ...\033[K\n"
        fi
        
    fi
    
    # clear util end of page
    printf "\033[J"

    # avoids a blinking cursor
    tput civis
}


#######################
# start of main section
#######################

# basic terminal control to keep it alive
setterm -reset 2>/dev/null
setterm -powersave off 2>/dev/null
setterm -blank 0 2>/dev/null

# start with a blank screen
printf "\033c"

# avoids a blinking cursor
tput civis


# initialize global parameters
# requires complete path here. Doesn't work with "~"
para_file="/home/montty2/parameters.txt"
rm -f ${para_file}
touch ${para_file}

base_logpath="/home/montty2/RunAtlas"
main_log="${base_logpath}/log.EVNTtoHITS"
logname_1core="${main_log}"

# this must later be prefixed with a path like "${base_logpath}/worker_x/"
logname_mcore="AthenaMP.log"

n_workers="N/A"
n_events="N/A"
n_finished_events="N/A"
rntme_arth_mean="N/A"
rntme_min_max="N/A"
time_left="N/A"
time_left_uncert="N/A"
n_events_left="-1"
init_loop_counter="0"
n_finished_events_last="0"
w_status_started="0"

w_msg_headline="Event status per worker thread:"


# subfunction running asynchronously
get__n_events__n_workers ${$} ${main_log} &


# main loop starts here
while :
do
    # why? See end of the while loop
    next_loopstart="$(( $(date +%s) + 60 ))"
    
    # source parameters that were set by subfunctions
    . ${para_file}
    
    if [[ "${n_events}" != "N/A" ]] &&
       [[ "${n_workers}" != "N/A" ]]
    then

        if (( n_workers == 1 )) ||
           ( (( n_workers > 1 )) &&
             (( n_workers == $(wc -l < <(find -L ${base_logpath} -name "${logname_mcore}")) )) )
        then

            if (( w_status_started == 0 ))
            then
                # sometimes it takes very long to finish the 1st event
                # to calm down impatient volunteers get an intermediate status
        
                if (( n_workers == 1 ))
                then
                    logfile_arr[0]="${logname_1core}"
                    get_worker_status ${$} "${logname_1core}" 0 &
                else
            
                    for (( i=0; i<n_workers; ++i ))
                    do
                        logfile_arr[${i}]="${base_logpath}/worker_${i}/${logname_mcore}"
                        get_worker_status ${$} "${base_logpath}/worker_${i}/${logname_mcore}" ${i} &
                    done
                
                fi
            
                w_status_started="1"
            fi
        
            # clear runtimes array
            rntme_arr=()
        
            for (( i=0; i<n_workers; ++i ))
            do
                # get all events that are already finished
                evlist_per_worker="$(grep "^.*ISFG4SimSvc.*INFO.*Event nr.*took.*New average" ${logfile_arr[${i}]})"

                if [[ "${evlist_per_worker}" ]]
                then
                    # get the last event that has finished
                    w_msg_arr[${i}]="$(sed -e "0,/^.*Event.*took[^0-9]*[0-9]\+/ s/^.*\(Event.*took[^0-9]*[0-9]\+\).*/\1 s/p" -n <(tac <<< "${evlist_per_worker}"))"
                    
                    # collect runtimes from the logs so they can later be used to estimate time left
                    rntme_arr=("${rntme_arr[@]}" $(xargs -n 1 -I {} sh -c "echo {} |sed 's/^.*Event.*took[^0-9]*\([0-9]\+\).*/\1/'" <<< "${evlist_per_worker}"))
                fi
                
            done
        
            # if at least 1 event has finished
            if (( ${#rntme_arr[@]} > 0 ))
            then
                # don't do this outside "if" as it would overwrite "N/A"
                n_finished_events="${#rntme_arr[@]}"
            
                # min and max runtimes
                rntme_min="${rntme_arr[0]}"
                rntme_max="${rntme_arr[0]}"
            
                for rt in "${rntme_arr[@]}"
                do
                    (( rt < rntme_min )) && rntme_min="${rt}"
                    (( rt > rntme_max )) && rntme_max="${rt}"
                done
            
                rntme_min_max="${rntme_min} / ${rntme_max} s"

                # runtimes: global arithmetic mean
                rntme_arth_mean="$(awk '{ sum=0; for (i=1; i<=NF; i++) { sum+=$i } printf "%f", sum/NF }' <<< "${rntme_arr[@]}")"
        
                # runtimes: global standard deviation
                # place ${rntme_arr[@]} as last parameter as it has variable length
                rntme_sd="$(awk '{ ssq=0; for (i=3; i<=NF; i++) { ssq+=($i-$1)**2 } printf "%f", sqrt(ssq)/$2 }' <<< "${rntme_arth_mean} ${n_finished_events} ${rntme_arr[@]}")"

                # multiply with 3 to cover 99.73% (6 sigma) instead of 68.27% (2 sigma) of all runtime values.
                # see definition of "normal distribution"
                # round to integer value
                rntme_sd_six_sigma="$(awk '{ printf "%.0f", 3*$1 }' <<< "${rntme_sd}")"

                # round to integer value
                # avoid surprises due to language setting
                rntme_arth_mean="$(LC_NUMERIC="en_US.UTF-8"; printf "%.0f\n" "${rntme_arth_mean}")"
        
                if (( n_finished_events_last == n_finished_events ))
                then
                    (( time_left_reduction += 60 ))
                else
                    time_left_reduction="0"
                    n_finished_events_last="${n_finished_events}"
                fi
                
                n_events_left="$(( n_events - n_finished_events ))"
                time_left_s="0"
                (( n_events_left > 0 )) && time_left_s="$(( n_events_left * rntme_arth_mean / n_workers - time_left_reduction ))"

                if (( time_left_s < 0 ))
                then
                     msg_overtime="overtime"
                     time_left_s="$(( -time_left_s ))"
                else
                     msg_overtime=""
                fi
            
                # format rntme_arth_mean
                rntme_arth_mean="$(printf "%s s\n" "${rntme_arth_mean}")"
            
                time_left="$(format_timestring "${time_left_s}")"
                
                # estimate "uncertainty"
                time_left_uncert_s="$(( n_events_left * rntme_sd_six_sigma / n_workers ))"
                time_left_uncert="$(format_timestring "${time_left_uncert_s}")"
            fi
            
        fi

    fi
    
    # at start or restart the main loop needs a few laps to get the setup done
    if (( init_loop_counter < 3 ))
    then
        (( init_loop_counter ++ ))
        update_display_on_tty starting
        sleep 2
    else
        update_display_on_tty
        
        # regular display update every 60 s
        # avoid too much drifting on heavily loaded systems
        sleep $(( next_loopstart - $(date +%s) )) 2>/dev/null
    fi

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
main_log_name="log.EVNTtoHITS"
athena_log_name="AthenaMP.log"
athena_workers_dir="athenaMP-workers-EVNTtoHITS-sim"

# use "install -d" instead of mkdir, chown, chmod
install -d -o montty2 -g montty2 -m 777 ${target_location}


# trigger 1: main log exists
while :
do
    main_log="$(find -L ${source_location} -name "${main_log_name}")"
    
    [[ "${main_log}" != "" ]] && break

    # check all 10 s (we are not in a hurry)
    sleep 10
done

# tail complete file starting at line 1
tail -f -n +1 ${main_log} >${target_location}/${main_log_name} 2>/dev/null &


# check if ATLAS is running singlecore or multicore

# wait until maxEvents appears in main_log
grep -E -m 1 -s "^.*maxEvents =[^0-9]*[0-9]+" <(tail -F -n +1 --pid ${$} ${main_log} 2>/dev/null) 2>/dev/null

# it's a multicore if ATHENA_PROC_NUMBER is in the log before maxEvents
# it's a singlecore if ATHENA_PROC_NUMBER is missing
pattrn="^.*ATHENA_PROC_NUMBER set to[^0-9]*"
n_workers="$(sed -e "0,/${pattrn}/ s/${pattrn}\([0-9]\+\).*/\1/p" -n ${main_log})"
[[ ! "${n_workers}" ]] && n_workers="1"
    
# singlecore logs to main_log
# a tail for main_log is already running
# now start the tails for multicore
if (( n_workers > 1 ))
then

    for (( i=0; i<n_workers; ++i ))
    do
        mkdir -p ${target_location}/worker_${i}
        tail -F -n +1 $(dirname ${main_log})/${athena_workers_dir}/worker_${i}/${athena_log_name} >${target_location}/worker_${i}/${athena_log_name} 2>/dev/null &
    done
    
fi
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
    systemctl restart getty@tty2.service
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

    chpasswd <<< "${user_on_tty}:$(head -c 1 < <(tr -cd a-zA-Z < /dev/urandom))$(head -c ${pw_length} < <(tr -cd a-zA-Z0-9$%/=+~*#_,. < /dev/urandom))$(head -c 1 < <(tr -cd a-zA-Z0-9 < /dev/urandom))" 2>/dev/null
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
RestartSec=2
EOF_override_tty3_service


systemctl daemon-reload

if [[ "$(systemctl show -p ActiveState getty@tty3.service)" != "ActiveState=inactive" ]]
then
    systemctl restart getty@tty3.service
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

