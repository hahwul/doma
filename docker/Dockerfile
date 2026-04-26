# Multi-stage build: musl-static binary in Alpine, then a slim Alpine
# runtime. Static linkage means the runtime needs no libraries at all,
# but a tiny base image keeps `sh`, `ls`, etc. around for debugging.

##= BUILDER =##
FROM crystallang/crystal:1.20.0-alpine AS builder
WORKDIR /doma

# `sqlite-static` is what makes the final binary fully self-contained —
# without it Crystal's --static still needs libsqlite3.a at link time.
RUN apk add --no-cache yaml-dev sqlite-dev sqlite-static git

COPY shard.yml shard.lock ./
RUN shards install --production

COPY . .
RUN shards build --release --no-debug --production --static && \
    strip /doma/bin/doma

##= RUNNER =##
FROM alpine:3.20

LABEL org.opencontainers.image.title="doma"
LABEL org.opencontainers.image.description="Directory tag manager — put your directories on the cutting board (Crystal CLI)"
LABEL org.opencontainers.image.authors="HAHWUL <hahwul@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/hahwul/doma"
LABEL org.opencontainers.image.licenses="MIT"

COPY --from=builder /doma/bin/doma /usr/local/bin/doma

ENTRYPOINT ["/usr/local/bin/doma"]
CMD ["--help"]
