# debian-minimal - Automated building of consistant debian root filesystems for Docker

Builds minimal consistant debian root file system images for use with Docker. It is based on the work of Tianon Gravi, who build the debuerreotype tools.

Since I wanted to build the root images myself, I wrote this skript to build the docker images I needed. The configuration is done with the .env file. 

##### Example .env file:

```
# debuerreotype repository that will be cloned
DEBUERREOTYPE_REPO=https://github.com/debuerreotype/debuerreotype.git

# debian suites to be build
DEBIAN_SUITES="stable testing"

# target docker repository
DOCKER_REPO_USER=svenpaass
DOCKER_REPO_NAME=debian-minimal

# timestamp of the debian snapshot to use (timestamp or "now")
TIMESTAMP="2017-08-26T00:00:00Z"
```

##### What does the skript do?

The [`build.sh`](https://github.com/svenpaass/debian-minimal/blob/master/build.sh) needs to be run as root (or with sudo). 
First the script downloads the current `debuerreotype` version from the configured repository url. Then a debian stable docker image 
is build with debootstrap and afterwards the debuerreotype scripts are added to the build image.

Next the debian suites are build from the snapshot repository with the configured timestamp. This ensures a consistant build 
(see [`README.md`](https://github.com/debuerreotype/debuerreotype/blob/master/README.md)).

##### sha256sums of the rootfs.tar.xz files

###### Timestamp: 2017-08-26T00:00:00Z
###### Architecture: amd64

- Debian Scretch (stable) - 13.037.256 Bytes : bc203a05daf4bdfc9553a05a6fb8d7dc92a1c19c4b9a5b197160992737b0c4b5 
- Debian Buster (testing) - 14.668.620 Bytes : 49fe4f9b1546620ede145e7d903f1bda78dde1afdb8c3f3d994cf6d15bf23cd6

From the generated root filesystem file the base docker images are build and tagged with the release information.
The current stable version is always tagged as `latest`.

##### Tags Debian Stable (stretch):
- `github-user`/`github-project`:latest
- `github-user`/`github-project`:stable
- `github-user`/`github-project`:stretch
- `github-user`/`github-project`:9
- `github-user`/`github-project`:9.1

##### Tags Debian Testing (buster):
- `github-user`/`github-project`:testing
- `github-user`/`github-project`:buster

##### Pushing the images to the docker hub

```
docker login --username=`github-user`
docker push `github-user`/`github-project` #  whole project with all tags

or

docker push `github-user`/`github-project`:stretch     #  only specific tag
```
