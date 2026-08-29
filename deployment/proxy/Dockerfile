FROM node:22-slim

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY index.js ./
COPY public/ ./public/

EXPOSE 8080

CMD ["node", "index.js"]
