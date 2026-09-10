# Multi-stage build — only Docker is needed on the host (no local Go toolchain).
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# Resolve deps (go-control-plane ext_proc, grpc) and build a static binary.
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -trimpath -o /agent-router-guardrail .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /agent-router-guardrail /agent-router-guardrail
EXPOSE 18080
ENTRYPOINT ["/agent-router-guardrail"]
