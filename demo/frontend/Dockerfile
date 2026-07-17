FROM node:20-slim AS build

WORKDIR /app
COPY demo/frontend/package.json demo/frontend/package-lock.json* ./
RUN npm install
COPY demo/frontend/ .
ENV NODE_OPTIONS="--max-old-space-size=4096"
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY demo/frontend/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
