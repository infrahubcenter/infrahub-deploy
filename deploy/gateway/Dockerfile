# Infra Hub Center gateway: the single public entry point in front of the
# API and the console -- /api/* (REST + WebSockets: VM console, live logs,
# agent connections) to infrahub-api, everything else to infrahub-ui.
# Published as docker.io/infrahubcenter/infrahub-gateway.
# alpine-slim: same nginx + template support (envsubst), ~20 MB instead of ~74 MB.
FROM nginx:1.27-alpine-slim

# Upstreams, substituted into the config at container start by the nginx
# image's own template step. Defaults match the service names used by
# deploy/docker/docker-compose.yml and deploy/kubernetes/.
ENV INFRAHUB_API_UPSTREAM=infrahub-api:8080 \
    INFRAHUB_UI_UPSTREAM=infrahub-ui:3000 \
    INFRAHUB_MAX_BODY_SIZE=50m

COPY default.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 80
