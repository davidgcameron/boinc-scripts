Run ATLAS@Home on Docker
========================

Docker images for running ATLAS@Home tasks. When the image starts it will attach a BOINC client to the [LHC@Home](https://lhcathome.cern.ch/lhcathome/) project and start running ATLAS tasks. When the image is stopped (`docker stop`) it will automatically abort and report remaining tasks.

There are two options for managing CVMFS:
* CVMFS already exists on the host. It must be already configured with the repos required for ATLAS tasks and can be bind-mounted into the image with the `-v` option
* CVMFS does not exist on the host. When the image starts it will manually mount the required repos, however this requires that the `--privileged` option for `docker run` is used.

Setting up an account
---------------------

Head over to https://lhcathome.cern.ch/lhcathome/ and click the join button. Once you have created an account, on the account information page click on "LHC@Home preferences". Click on "Edit preferences" and make sure the ATLAS Simulation application is checked along with "Run native if available".

Back on the account info page click on the "Account keys: view" link. There you will find the authenticator key which you need to give to docker run to connect the BOINC client running on your hosts to your account.

Building
--------

`docker image build -t davidgcameron/boinc-atlas:1.0 .`

Running
-------

The BOINC authenticator must be given as the first argument to the docker run command.

If CVMFS already exists on the host:

`docker run -v /cvmfs:/cvmfs:shared -v /var/cache/cvmfs:/var/cache/cvmfs:shared -d davidgcameron/boinc-atlas:1.0 <boinc_authenticator>`

If the host does not have CVMFS, the container must be run in privileged mode to allow mounting CVMFS:

`docker run --privileged -d davidgcameron/boinc-atlas:1.0 <boinc_authenticator>`

Debugging
---------

BOINC client logs to stdout so can be seen with `docker log <container_id>`

To debug running tasks, open a shell inside the container with `docker exec -it <container_id> /bin/bash`

Tasks run inside `slots/n` directories. `stderr.txt` may give information on why a task doesn't start. You can also see the content of `stderr.txt` for each task on the LHC@Home webpages under your account. The task itself logs to a file like `log.1234._5678.job.log.1`.
