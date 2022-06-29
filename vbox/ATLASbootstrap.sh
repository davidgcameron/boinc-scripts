#!/bin/sh
# Bootstrap ATLAS job. Called by atlas systemd unit
# Checks cvmfs is ok, copies and launches ATLASJobWrapper.sh
#

echo "Checking CVMFS..." | vboxmonitor
cvmfs_config probe

if [ "$?" -ne "0" ]; then
  echo 0 > /home/atlas/ATLASJobAgent.pid
  echo "Failed to check CVMFS:" | vboxmonitor
  cvmfs_config probe 2>&1 | vboxmonitor
  sleep 600
  sudo touch /home/atlas/shared/atlas_done
  sudo shutdown now
fi

echo "CVMFS is ok" | vboxmonitor
cp /cvmfs/atlas.cern.ch/repo/sw/BOINC/agent/ATLASJobWrapper-test.sh /home/atlas/ATLASJobWrapper.sh
chmod +x /home/atlas/ATLASJobWrapper.sh
/home/atlas/ATLASJobWrapper.sh &
echo $! > /home/atlas/ATLASJobAgent.pid
