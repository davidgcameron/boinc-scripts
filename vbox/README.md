Tools for handling tasks which run inside a virtual machine.

The ATLASbootstrap.sh script is placed in the VM image at /home/atlas/ATLASbootstrap.sh. It checks CVMFS is working, copies the job wrapper (ATLASJobWrapper.sh) from CVMFS and starts it.

The systemd unit atlas-app.service is configured to start the bootstrap script on boot.

The primary copy of the job wrapper is in afs: /afs/cern.ch/atlas/project/ADC/BOINC/cvmfssync and new versions are manually copied there from GitHub. The content of this directory is synched to this cvmfs location every hour: /cvmfs/atlas.cern.ch/repo/sw/BOINC. Since CVMFS is mounted inside the VM image, this means the wrapper can be changed without requiring a new image.
