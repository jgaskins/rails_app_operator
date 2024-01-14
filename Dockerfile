FROM 84codes/crystal:1.11.1-alpine AS builder

RUN apk add --update yaml-static

COPY . /build/
WORKDIR /build

RUN shards build --release --static

FROM scratch

COPY --from=builder /build/bin/rails_app_operator /
WORKDIR /

CMD ["./rails_app_operator"]
