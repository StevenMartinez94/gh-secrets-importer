FROM alpine:3.20

RUN apk add --no-cache bash github-cli jq yq

WORKDIR /app
COPY import_secrets.sh .
RUN chmod +x import_secrets.sh

ENTRYPOINT ["./import_secrets.sh"]
