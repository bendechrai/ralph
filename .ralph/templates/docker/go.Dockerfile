FROM golang:1.23-bookworm

WORKDIR /app

# Install air for hot reload
RUN go install github.com/air-verse/air@latest

COPY go.mod go.sum* ./
RUN go mod download

COPY . .

EXPOSE 8080

CMD ["air"]
