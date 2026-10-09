FROM golang:1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1

ENV REPO=/go/src/github.com/Alexsovich5/kubernetes-platform
WORKDIR $REPO
COPY . $REPO
RUN go install -ldflags "-X main.version=0.1.0" ./cmd/platform-app

ENV CONFIG_DIR=/app/config
EXPOSE 8080
CMD ["platform-app"]
