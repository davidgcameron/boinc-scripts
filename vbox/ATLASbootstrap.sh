#!/bin/sh
# Bootstrap ATLAS job. Called by atlas systemd unit
# Checks init_data and cvmfs are ok, copies and launches ATLASJobWrapper.sh
#

function early_exit {
    echo 0 > /home/atlas/ATLASJobAgent.pid
    echo "VM shutdown initiated" | vboxmonitor
    sleep 600
    sudo touch /home/atlas/shared/atlas_done 2>/dev/null
    sudo shutdown now
    exit 0
}


echo "Mounting shared directory" | vboxmonitor
sudo mount -t vboxsf shared /home/atlas/shared
if [ "$?" -ne "0" ]; then
    echo "Failed to mount shared directory" | vboxmonitor
    early_exit
fi
  

echo "Checking for init_data.xml..." | vboxmonitor
init_data="/home/atlas/shared/init_data.xml"
if [ -f $init_data ]; then
    echo "init_data.xml can't be found" | vboxmonitor
    early_exit
fi


echo "Checking CVMFS..." | vboxmonitor
cvmfs_config probe

if [ "$?" -ne "0" ]; then
    echo "Failed to check CVMFS:" | vboxmonitor
    cvmfs_config probe 2>&1 | vboxmonitor
    early_exit
fi

echo "CVMFS is ok" | vboxmonitor


if grep '<project_dir>[^<]*/lhcathomedev.cern.ch_lhcathome-dev<' init_data; then
    jobwrapper_name="ATLASJobWrapper-test.sh"
else
    jobwrapper_name="ATLASJobWrapper-prod.sh"
fi

cp /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/${jobwrapper_name} /home/atlas/ATLASJobWrapper.sh

if [ "$?" -ne "0" ]; then
    echo "Failed to copy ${jobwrapper_name}" | vboxmonitor
    early_exit
fi

chmod +x /home/atlas/ATLASJobWrapper.sh
/home/atlas/ATLASJobWrapper.sh &
echo $! > /home/atlas/ATLASJobAgent.pid
