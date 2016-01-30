FROM postgres:9.4
MAINTAINER Peter Salanki <peter@salanki.st>

RUN rm /docker-entrypoint.sh
COPY docker-entrypoint.sh /

RUN mkdir -p /tmp/trigger

COPY baseconfig /tmp
