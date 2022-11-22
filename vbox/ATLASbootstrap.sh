#!/bin/sh
# Bootstrap ATLAS job. Called by atlas systemd unit
# Checks init_data and cvmfs are ok, copies and launches ATLASJobWrapper.sh
#


function early_exit {
    echo "[DEBUG] VM early shutdown initiated due to previous errors." | vboxmonitor
    echo "[DEBUG] Cleanup will take a few minutes..." | vboxmonitor
    rm -rfd $my_tmp_dir
    # on a modern multi CPU computer many tasks often start concurrently
    # if they fail ensure they shut down after a random delay to flatten load peaks
    sleep $(shuf -n 1 -i 720-900)
    echo 0 > /home/atlas/ATLASJobAgent.pid
    sudo shutdown now
}


function probe_atlas_repo {
    echo "[INFO] Probing /cvmfs/atlas.cern.ch..." | vboxmonitor
    cvmfs_config probe atlas.cern.ch >${my_tmp_dir}/probe_atlas_log 2>&1
    probe_atlas_ret=$?
    echo "[INFO] $(cat ${my_tmp_dir}/probe_atlas_log)"
    if [ "$probe_atlas_ret" -ne "0" ]; then
        early_exit
    fi
}


umask_bak="$(umask)"
umask 077
my_tmp_dir="$(mktemp -d)"
umask "${umask_bak}"

# clear the proxy setup at every VM restart
sudo sh -c "rm -f /var/www/html/wpad.dat"

# This can be time consuming
# do it in the bg
probe_atlas_repo &
bg_probe_atlas_repo=$!


echo "[INFO] Mounting shared directory" | vboxmonitor
sudo mount -t vboxsf shared /home/atlas/shared
if [ "$?" -ne "0" ]; then
    echo "[DEBUG] Failed to mount shared directory" | vboxmonitor
    early_exit
fi
  
echo "[INFO] Checking for init_data.xml" | vboxmonitor
init_data="/home/atlas/shared/init_data.xml"
if [ ! -f $init_data ]; then
    echo "[DEBUG] init_data.xml can't be found" | vboxmonitor
    early_exit
fi

wait $bg_probe_atlas_repo


if grep '<project_dir>[^<]*/lhcathomedev.cern.ch_lhcathome-dev<' $init_data; then
    jobwrapper_name="ATLASJobWrapper-dev.sh"
else
    jobwrapper_name="ATLASJobWrapper-prod.sh"
fi

rm -f /home/atlas/ATLASJobWrapper.sh
cp /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/${jobwrapper_name} /home/atlas/ATLASJobWrapper.sh
if [ "$?" -ne "0" ]; then
    echo "[DEBUG] Failed to copy ${jobwrapper_name}" | vboxmonitor
    early_exit
fi

chown atlas:atlas /home/atlas/ATLASJobWrapper.sh
chmod +x /home/atlas/ATLASJobWrapper.sh

/home/atlas/ATLASJobWrapper.sh &
echo $! > /home/atlas/ATLASJobAgent.pid
