FROM node:22-slim

WORKDIR /app

# Install system deps for common packages (puppeteer, sharp, etc.)
RUN apt-get update && apt-get install -y \
    openssl \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install dependencies first for layer caching
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

COPY . .

# Generate Prisma client if prisma schema exists
RUN if [ -f prisma/schema.prisma ]; then npx prisma generate; fi

EXPOSE 3000

CMD ["npm", "run", "dev"]
