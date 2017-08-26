#!/bin/bash
###############################################################################
function checkForConfigFile {
  if [[ ! -f "${PWD}/.env" ]]; then
    echo >&2 "ERROR: No config file found. Please create .env file."; exit 1;
  fi
}

# check if user is root
function checkForRoot {
  if [[ $EUID -ne 0 ]]; then
    echo >&2 "ERROR: We need root permissions to run. Aborting."; exit 1;
  fi
}

# check if needed commands exist
function checkForPrerequisites {
   if [ ! -d "${debuerreotypeDirectory}" ]; then
     git --version >/dev/null 2>&1 || { echo >&2 "ERROR: git is not installed.  Aborting."; exit 1; }

     # clone repository
     cloneRepository

     if [ $? -ne 0 ]; then
       echo >&2 "ERROR: Couldn't clone the debuerreotype repository. Please manually clone the repository"
       echo >&2 "ERROR: (git clone ${DEBUERREOTYPE_REPO} ${debuerreotypeDirectory}) and"
       echo >&2 "ERROR: run the build skript again."
       exit 1;
     fi
   fi
   debootstrap --version >/dev/null 2>&1 || { echo >&2 "ERROR: debootstrap is not installed.  Aborting."; exit 1; }
   mktemp --version >/dev/null 2>&1 || { echo >&2 "ERROR: mktemp is not installed.  Aborting."; exit 1; }
   tar --version >/dev/null 2>&1 || { echo >&2 "ERROR: tar is not installed.  Aborting."; exit 1; }
   docker version >/dev/null 2>&1 || { echo >&2 "ERROR: docker is not installed.  Aborting."; exit 1; }
}

# clone repository
function cloneRepository {
  rm -rf "${debuerreotypeDirectory}"
  git clone ${DEBUERREOTYPE_REPO} ${debuerreotypeDirectory}
}

# create working directory
function createWorkingDirectory {
  workingDirectory=$(mktemp -d -t tmp.XXXXXXXXXX)
  [[ "$debug" == "yes" ]] && echo "DEBUG: Created working directory: ${workingDirectory}"
}

# remove working directory
function cleanup {
  if [[ "$debug" == "yes" ]]; then
    echo "DEBUG: Clean up phase. Doing nothing in debug mode."
  else
    rm -rf "$workingDirectory"
  fi
}

# build clean debian docker image
function buildStableDebianImage {
  if [[ ! -d "${workingDirectory}" ]]; then
    [[ "$debug" == "yes" ]] && echo "DEBUG: Creating working directory."
    createWorkingDirectory
    debootstrap --variant=minbase stable ${workingDirectory}
  else
    [[ "$debug" == "yes" ]] && echo "DEBUG: Reusing working directory ${workingDirectory}."
    tar -cC ${workingDirectory} . | docker import - debian:stable-slim
  fi
}

# add the debuerreotype files to the build-image
function buildDebuerreotypeImage {
  docker build -t "${debuerreotypeDockerImage}" "${debuerreotypeDirectory}"
}

# build root filesystems
function buildRootFS {
  local outputDir="$1"; shift
  local suite="$1"; shift
  local timestamp="$1"; shift

  securityArgs="--cap-add SYS_ADMIN"
  # disable AppArmor
  if [[ $(docker info |grep apparmor) ]]; then
    securityArgs+=" --security-opt apparmor=unconfined"
  fi

  docker run --rm ${securityArgs} \
    --tmpfs /tmp:dev,exec,suid,noatime --workdir /tmp \
    --env suite="$suite" --env timestamp="$timestamp" --env TZ='UTC' --env LC_ALL='C' \
    "$debuerreotypeDockerImage" \
    bash -Eeuo pipefail -c '
    set -x

    epoch="$(date --date "$timestamp" +%s)"
    serial="$(date --date "@$epoch" +%Y%m%d)"
    dpkgArch="$(dpkg --print-architecture)"

    exportDir="output"
    outputDir="$exportDir/$serial/$dpkgArch/$suite"
    rootfsDir=rootfs

    touch_epoch() {
      while [ "$#" -gt 0 ]; do
        local f="$1"; shift
        touch --no-dereference --date="@$epoch" "$f"
      done
    }

    debuerreotypeScriptsDir="$(dirname "$(readlink -f "$(which debuerreotype-init)")")"

    for archive in "" security; do
      snapshotUrl="$("$debuerreotypeScriptsDir/.snapshot-url.sh" "@$epoch" "${archive:+debian-${archive}}")"
      snapshotUrlFile="$exportDir/$serial/$dpkgArch/snapshot-url${archive:+-${archive}}"
      mkdir -p "$(dirname "$snapshotUrlFile")"
      echo "$snapshotUrl" > "$snapshotUrlFile"
      touch_epoch "$snapshotUrlFile"
    done

    snapshotUrl="$(< "$exportDir/$serial/$dpkgArch/snapshot-url")"
    mkdir -p "$outputDir"

    wget -O "$outputDir/Release.gpg" "$snapshotUrl/dists/$suite/Release.gpg"
    wget -O "$outputDir/Release" "$snapshotUrl/dists/$suite/Release"
    gpgv \
      --keyring /usr/share/keyrings/debian-archive-keyring.gpg \
      --keyring /usr/share/keyrings/debian-archive-removed-keys.gpg \
      "$outputDir/Release.gpg" \
      "$outputDir/Release"

    {
      debuerreotype-init $rootfsDir "$suite" "@$epoch"
      debuerreotype-minimizing-config $rootfsDir
      debuerreotype-apt-get $rootfsDir update -qq
      debuerreotype-apt-get $rootfsDir dist-upgrade -yqq

      # prefer iproute2 if it exists
      iproute=iproute2
      if ! debuerreotype-chroot $rootfsDir apt-cache show iproute2 > /dev/null; then
        # poor wheezy
        iproute=iproute
      fi
      debuerreotype-apt-get $rootfsDir install -y --no-install-recommends inetutils-ping $iproute
      debuerreotype-slimify $rootfsDir

      create_artifacts() {
        local targetBase="$1"; shift
        local rootfs="$1"; shift
        local suite="$1"; shift

        # make a copy of the snapshot-facing sources.list file before we overwrite it
        cp "$rootfs/etc/apt/sources.list" "$targetBase.sources-list-snapshot"
        touch_epoch "$targetBase.sources-list-snapshot"

        debuerreotype-gen-sources-list "$rootfs" "$suite" http://deb.debian.org/debian http://security.debian.org
        debuerreotype-tar "$rootfs" "$targetBase.tar.xz"

        du -hsx "$targetBase.tar.xz"
        sha256sum "$targetBase.tar.xz" | cut -d" " -f1 > "$targetBase.tar.xz.sha256"
        touch_epoch "$targetBase.tar.xz.sha256"

        debuerreotype-chroot "$rootfs" dpkg-query -W > "$targetBase.manifest"
        echo "$epoch" > "$targetBase.debuerreotype-epoch"
        touch_epoch "$targetBase.manifest" "$targetBase.debuerreotype-epoch"

        for f in debian_version os-release apt/sources.list; do
          targetFile="$targetBase.$(basename "$f" | sed -r "s/[^a-zA-Z0-9_-]+/-/g")"
          cp "$rootfs/etc/$f" "$targetFile"
          touch_epoch "$targetFile"
        done
      }
      create_artifacts "$outputDir/rootfs" "$rootfsDir" "$suite"
  } >&2

  tar -cC "$exportDir" .
  ' | tar -xvC "$outputDir"
}

###############################################################################
# Always cleanup
trap cleanup SIGINT SIGTERM

# get current directory (normally it should set already)
[[ -z "$PWD" ]] || PWD=$(pwd)

# check if config file exists
checkForConfigFile

# include configuration variables
source "${PWD}/.env"

############################################################################
# initialize variables (yes / no)
debug=no

# Flags for building the docker images (yes / no)
buildCleanImg=yes
buildDebuerreotypeImg=yes
buildRootFS=yes

# reuse existing working directory.
workingDirectory=
debuerreotypeDirectory=/tmp/debuerreotype

############################################################################
# check prerequisites
checkForRoot
checkForPrerequisites

# version of debuerreotype scripts
debuerreotypeVersion="$(${debuerreotypeDirectory}/scripts/debuerreotype-version)"
debuerreotypeVersion="${debuerreotypeVersion%% *}"
debuerreotypeDockerImage="debuerreotype/debuerreotype:${debuerreotypeVersion}"

# build clean debian image with debootstrap
[[ "$buildCleanImg" == "yes" ]] && buildStableDebianImage && cleanup

# build image with debuerreotype scripts inside
[[ "$buildDebuerreotypeImg" == "yes" ]] && buildDebuerreotypeImage && cleanup

# build rootfs for all choosen suites
if [[ "buildRootFS" == "yes" ]]; then
  # remove even if old directory exists
  rm -rf ${PWD}/output
  mkdir -p ${PWD}/output
  for suite in ${DEBIAN_SUITES}; do
    buildRootFS "${PWD}/output" "${suite}" "${TIMESTAMP}"
  done
else
  # output directory doesn't exist, create new one
  if [[ ! -d ${PWD}/output ]]; then
    mkdir -p ${PWD}/output
    for suite in ${DEBIAN_SUITES}; do
      buildRootFS "${PWD}/output" "${suite}" "${TIMESTAMP}"
    done
  fi
  [[ "${debug}" == "yes" ]] && echo "DEBUG: Re-using existing output directory."
fi

# build base docker images
dockerhubProjectName=${DOCKER_REPO_USER}/${DOCKER_REPO_NAME}
for suite in ${DEBIAN_SUITES}; do
  epoch="$(date --date "${TIMESTAMP}" +%s)"
  serial="$(date --date "@$epoch" +%Y%m%d)"
  dpkgArch="$(dpkg --print-architecture)"

  releaseFile=${PWD}/output/${serial}/${dpkgArch}/${suite}/Release
  codename=$(grep "Codename" ${releaseFile} | cut -d' ' -f 2)
  version=$(grep "Version" ${releaseFile} | cut -d' ' -f 2)
  majorversion=${version%%.*}
  debianSuite=$(grep "Suite" ${releaseFile} | cut -d' ' -f 2)
  echo $debianSuite $version $majorversion $codename

  dockerhubProjectName=${DOCKER_REPO_USER}/${DOCKER_REPO_NAME}
  dockerOptions=
  [[ -n ${debianSuite} ]] && dockerOptions+="-t ${dockerhubProjectName}:${debianSuite} "
  [[ ${debianSuite} == "stable" ]] && dockerOptions+="-t ${dockerhubProjectName}:latest "
  [[ -n ${codename} ]] && dockerOptions+="-t ${dockerhubProjectName}:${codename} "
  [[ -n ${majorversion} ]] && dockerOptions+="-t ${dockerhubProjectName}:${majorversion} "
  [[ -n ${version} ]] && dockerOptions+="-t ${dockerhubProjectName}:${version} "
  [[ "${debug}" == "yes" ]] && echo "DEBUG: Docker options: ${dockerOptions}"

  # prepare docker build context
  outputDir=${PWD}/output/${serial}/${dpkgArch}/${suite}
  cp ${PWD}/Dockerfile $outputDir/Dockerfile

  # build docker image
  docker build ${dockerOptions} ${outputDir}
done

# cleanup on exit
rm -rf "${debuerreotypeDirectory}"
cleanup
exit 0
