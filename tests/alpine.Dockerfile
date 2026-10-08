FROM alpine:3.22
RUN apk add --no-cache bash curl wget unzip tar socat openrc python3
COPY install.sh install-machine.sh XrayR.sh XrayR.service XrayR.openrc /repo/
COPY config /repo/config
COPY tests /repo/tests
WORKDIR /repo
CMD ["bash", "tests/openrc_integration_test.sh"]
