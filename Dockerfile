# syntax=docker/dockerfile:1

# ---- Stage 1: build ----
# Pinned to the Go version declared in app/go.mod. Built on the native builder
# platform and cross-compiled to the target platform, so the same Dockerfile
# works on both Intel and Apple Silicon hosts.
FROM --platform=$BUILDPLATFORM golang:1.22 AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src

# Copy the module definition first so dependency resolution is cached
# independently of source changes. The service currently has no external
# dependencies, but keeping this step means adding one later stays cheap.
COPY app/go.mod ./
RUN go mod download

COPY app/ ./

# CGO is disabled on purpose:
#   - it produces a fully static binary that runs on a distroless/static base
#     (and on scratch), and
#   - it avoids the macOS "missing LC_UUID load command" issue called out in
#     the README.
# -ldflags "-s -w" strips the symbol table and DWARF debug info to keep the
# binary small; it has no effect on runtime behaviour.
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -trimpath -o /greeter .

# ---- Stage 2: runtime ----
# distroless/static gives us just enough to run a static binary safely: CA
# certificates, /etc/passwd with a nonroot user, and tzdata, but no shell and
# no package manager. Smaller attack surface than a full distro, more batteries
# than scratch.
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /

COPY --from=builder /greeter /greeter

# Documents the default listen port (app reads PORT, default 8080).
EXPOSE 8080

# Run as the built-in nonroot user (UID 65532), never as root.
USER nonroot:nonroot

ENTRYPOINT ["/greeter"]
