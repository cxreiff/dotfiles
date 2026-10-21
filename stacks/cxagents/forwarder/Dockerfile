# syntax=docker/dockerfile:1
# tailnet-forwarder — built only by stacks/cxagents/scripts/build.sh (writes
# ../build.lock). Bumping a pin = edit a digest here or a version in go.mod,
# then `dotfiles stacks cxagents build`.
FROM golang:1.27.3-bookworm@sha256:21ade014faf952365b9ecbd8dbdb87176fbacb82fac9fb132d9f2a7b8cc3f132 AS build
ENV GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-mod=readonly
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN go build -trimpath -mod=readonly -buildvcs=false -ldflags='-s -w -buildid=' \
        -o /out/tailnet-forwarder . \
 && mkdir -p /out/state

FROM build AS test
RUN go vet ./... && go test -count=1 ./...

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/tailnet-forwarder /tailnet-forwarder
# A fresh named volume mounted at /state inherits this ownership (uid 65532).
COPY --from=build --chown=65532:65532 /out/state /state
USER 65532:65532
ENTRYPOINT ["/tailnet-forwarder"]
CMD ["serve"]
