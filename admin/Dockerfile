# dsh-admin 管理面板镜像。
# 运行镜像需要 bash（dshm 是 bash 脚本）与 docker CLI + compose（命令台会调用
# `dshm …`，而 dshm 内部用 `docker compose`）。二进制本身仍是静态的、无依赖。
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /dsh-admin .

FROM alpine:3.21
RUN apk add --no-cache bash docker-cli docker-cli-compose
COPY --from=build /dsh-admin /dsh-admin
# 配置由 compose 挂进来（含口令哈希与会话密钥），默认路径 /config/config.json
ENTRYPOINT ["/dsh-admin"]
CMD ["-config", "/config/config.json"]
