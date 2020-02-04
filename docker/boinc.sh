#!/bin/sh
# Bootstrap script run when container starts. If CVMFS is not bind-mounted then
# it is mounted here. This requires the container to be started with
# --privileged. Then BOINC client is started. The first argument is the BOINC
# authenticator.

if ! findmnt /cvmfs >/dev/null; then 
  # Mounting CVMFS has to be done at runtime because building the image cannot
  # be done with elevated privileges
  mkdir /cvmfs/atlas.cern.ch /cvmfs/atlas-condb.cern.ch /cvmfs/grid.cern.ch
  mount -t cvmfs atlas.cern.ch /cvmfs/atlas.cern.ch
  mount -t cvmfs atlas-condb.cern.ch /cvmfs/atlas-condb.cern.ch
  mount -t cvmfs grid.cern.ch /cvmfs/grid.cern.ch
fi
cvmfs_config probe || exit 1

# Attach to project with the supplied authenticator
exec /cvmfs/atlas.cern.ch/repo/sw/BOINC/BOINC/boinc --abort_jobs_on_exit --attach_project https://lhcathome.cern.ch/lhcathome/ "$1"



