FROM atlasadc/atlas-grid-centos7-base

# Install CVMFS. Mounting has to be done at runtime if required
RUN yum -y install https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm
RUN yum -y install cvmfs cvmfs-config-default

# Install unsquashfs tools for singularity image
# Not needed if the fs image is used
RUN yum -y install squashfs-tools

# Set ATLAS repositories and OpenHTC stratum 1 servers
COPY default.local /etc/cvmfs/default.local
COPY cern.ch.local /etc/cvmfs/domain.d/cern.ch.local
 
WORKDIR /var/lib/boinc

# Main script which starts boinc client
COPY boinc.sh .
ENTRYPOINT ["./boinc.sh"]

