FROM scratch
MAINTAINER Sven Paaß <sven@paass.net>

ADD rootfs.tar.xz /

CMD [ "/bin/bash" ]
