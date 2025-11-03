FROM alpine:3.18
RUN apk add --no-cache ca-certificates tar bash
WORKDIR /tmp
# Download k6 linux-arm64 binary (pinned version known to have arm64 asset)
ARG K6_VERSION=0.46.0
ADD https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-arm64.tar.gz /tmp/k6.tar.gz
RUN tar -xzf /tmp/k6.tar.gz -C /usr/local/bin --strip-components=1 && rm /tmp/k6.tar.gz

WORKDIR /scripts
ENTRYPOINT ["/usr/local/bin/k6"]
