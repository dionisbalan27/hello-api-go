FROM golang:1.23-alpine AS builder

WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o http .

# Distribution

FROM alpine:3.20 AS runtime

ENV TZ=Asia/Jakarta
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 10001 app

WORKDIR /app

EXPOSE 3000

COPY --from=builder /app/http /app/http

USER app

CMD ["/app/http"]
