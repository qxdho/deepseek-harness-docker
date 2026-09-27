# dsh-admin 管理面板镜像：静态二进制 + scratch，约 7MB。
# 只有这个容器挂 docker.sock；dsh 容器永远不挂。
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /dsh-admin .

FROM scratch
COPY --from=build /dsh-admin /dsh-admin
# 配置由 compose 挂进来（含口令哈希与会话密钥），默认路径 /config/config.json
ENTRYPOINT ["/dsh-admin"]
CMD ["-config", "/config/config.json"]
