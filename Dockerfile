FROM 84codes/crystal:1.15.1-alpine AS builder

RUN apk add --update yaml-static

WORKDIR /build
COPY shard.yml shard.lock .
RUN shards

COPY src/ src/
COPY k8s/ k8s/
RUN shards build --release --static

FROM scratch AS final

COPY --from=builder /build/bin/rails_app_operator /
WORKDIR /

CMD ["/rails_app_operator"]
