FROM crystallang/crystal:1.3.2-alpine AS builder

COPY . /build/
WORKDIR /build

RUN shards build --release --static

FROM scratch

COPY --from=builder /build/bin/rails_app_operator /
WORKDIR /

CMD ["./rails_app_operator"]
