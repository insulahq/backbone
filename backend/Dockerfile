FROM node:22-alpine

WORKDIR /app

# Install dependencies (includes devDeps — tsx needed at runtime for Phase 1)
COPY package*.json ./
RUN npm install

COPY . .

EXPOSE 3000

# Run DB migrations then start server
# tsx runs TypeScript directly — no build step needed for Phase 1 testing
CMD ["sh", "-c", "node_modules/.bin/knex --knexfile src/db/knexfile.ts migrate:latest && node_modules/.bin/tsx src/server.ts"]
