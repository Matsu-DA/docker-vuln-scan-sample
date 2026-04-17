FROM node:14.21.3-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --production
CMD ["true"]
