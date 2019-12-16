Run ATLAS@Home on Docker
========================

**Note** Currently under development - and connecting to the [LHC-dev project](https://lhcathomedev.cern.ch/lhcathome-dev/). Please use the BOINC authenticator from LHC-dev to test.

Docker images for running ATLAS@Home tasks. When the image starts it will attach a BOINC client to the [LHC@Home](https://lhcathome.cern.ch/lhcathome/) project and start running ATLAS tasks. When the image is stopped (`docker stop`) it will automatically abort and report remaining tasks.

There are two options for managing CVMFS:
* CVMFS already exists on the host. It must be already configured with the repos required for ATLAS tasks and can be bind-mounted into the image with the `-v` option
* CVMFS does not exist on the host. When the image starts it will manually mount the required repos, however this requires that the `--privileged` option for `docker run` is used.

Building
--------

`docker image build -t davidgcameron/boinc-atlas:1.0 .`

Running
-------

The boinc authenticator must be given as the first argument to the docker run command.

If CVMFS already exists on the host:

`docker run -v /cvmfs:/cvmfs:shared -v /var/cache/cvmfs:/var/cache/cvmfs:shared davidgcameron/boinc-atlas:1.0 <boinc_authenticator>`

If the host does not have CVMFS, the container must be run in privileged mode to allow mounting CVMFS:

`docker run --privileged davidgcameron/boinc-atlas:1.0 <boinc_authenticator>`
