ARG DOCKER_TAG
FROM savonet/liquidsoap-github-actions:$DOCKER_TAG

MAINTAINER The Savonet Team <savonet-users@lists.sourceforge.net>

WORKDIR /tmp/liquidsoap-full/liquidsoap

RUN eval $(opam config env) && make test
