# Tiny token minter: openssl + curl + jq, nothing else.
FROM docker.io/library/debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq openssl \
 && rm -rf /var/lib/apt/lists/*
COPY --chmod=0555 mint.sh /usr/local/bin/mint.sh
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/mint.sh"]
