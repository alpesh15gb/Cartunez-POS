FROM node:22-bookworm-slim
ENV NEXT_TELEMETRY_DISABLED=1 NODE_OPTIONS=--max-old-space-size=1536
COPY deploy/cartunez/build-web-container.sh /usr/local/bin/cartunez-build-web
RUN chmod 755 /usr/local/bin/cartunez-build-web
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/cartunez-build-web"]
