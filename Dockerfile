FROM registry.access.redhat.com/ubi9/go-toolset:1.26 AS build
WORKDIR /src/ecr-creds-sync
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/ecr-creds-sync ./cmd/ecr-creds-sync

FROM registry.access.redhat.com/ubi9/ubi-minimal
COPY --from=build /out/ecr-creds-sync /usr/local/bin/ecr-creds-sync
USER 65532
ENTRYPOINT ["/usr/local/bin/ecr-creds-sync"]
