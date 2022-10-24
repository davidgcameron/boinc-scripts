#!/bin/sh
# Bootstrap ATLAS job. Called by atlas systemd unit
# Checks init_data and cvmfs are ok, copies and launches ATLASJobWrapper.sh
#

function early_exit {
    echo 0 > /home/atlas/ATLASJobAgent.pid
    echo "VM early shutdown initiated" | vboxmonitor
    sleep 900
    sudo shutdown now
}


echo "Mounting shared directory" | vboxmonitor
sudo mount -t vboxsf shared /home/atlas/shared
if [ "$?" -ne "0" ]; then
    echo "Failed to mount shared directory" | vboxmonitor
    early_exit
fi
  

echo "Checking for init_data.xml" | vboxmonitor
init_data="/home/atlas/shared/init_data.xml"
if [ ! -f $init_data ]; then
    echo "init_data.xml can't be found" | vboxmonitor
    early_exit
fi


echo "Checking CVMFS..." | vboxmonitor
cvmfs_config probe >/home/atlas/cvmfs_probe_log 2>&1
if [ "$?" -ne "0" ]; then
    echo "Failed to check CVMFS" | vboxmonitor
    cat /home/atlas/cvmfs_probe_log | vboxmonitor
    early_exit
fi

echo "CVMFS is ok" | vboxmonitor


if grep '<project_dir>[^<]*/lhcathomedev.cern.ch_lhcathome-dev<' $init_data; then
    jobwrapper_name="ATLASJobWrapper-dev.sh"
else
    jobwrapper_name="ATLASJobWrapper-prod.sh"
fi

rm -f /home/atlas/ATLASJobWrapper.sh
cp /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/${jobwrapper_name} /home/atlas/ATLASJobWrapper.sh
if [ "$?" -ne "0" ]; then
    echo "Failed to copy ${jobwrapper_name}" | vboxmonitor
    early_exit
fi

chown atlas:atlas /home/atlas/ATLASJobWrapper.sh
chmod +x /home/atlas/ATLASJobWrapper.sh

/home/atlas/ATLASJobWrapper.sh &
echo $! > /home/atlas/ATLASJobAgent.pid
