FROM alpine:3.23

# dependencies for check scripts: certs (jq, openssl), dns (bind-tools), crowdsec (docker-cli)
RUN apk add --no-cache jq openssl curl tzdata coreutils bind-tools docker-cli

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# run the watchdog
ENTRYPOINT ["/entrypoint.sh"]