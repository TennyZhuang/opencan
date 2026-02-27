MODULE := github.com/anthropics/opencan-daemon
BINARY := opencan-daemon
VERSION := 0.1.0
TARGETS := linux-amd64 linux-arm64 darwin-amd64 darwin-arm64
IOS_BUNDLE_OUTPUT ?= ../Resources/$(BINARY)-linux-amd64

.PHONY: build test test-integration clean build-all mock-acp install-ios

build:
	go build -ldflags="-s -w -X main.version=$(VERSION)" -o bin/$(BINARY) ./cmd/opencan-daemon

test:
	go test -v -race ./internal/...

test-integration:
	go test -v -race -tags=integration ./test/...

build-all:
	@for target in $(TARGETS); do \
		OS=$$(echo $$target | cut -d- -f1); \
		ARCH=$$(echo $$target | cut -d- -f2); \
		echo "Building $$target..."; \
		GOOS=$$OS GOARCH=$$ARCH go build -ldflags="-s -w -X main.version=$(VERSION)" \
			-o dist/$(BINARY)-$$target ./cmd/opencan-daemon; \
	done

# Build linux-amd64 and copy to iOS app Resources for auto-deploy
install-ios:
	@mkdir -p "$(dir $(IOS_BUNDLE_OUTPUT))"
	GOOS=linux GOARCH=amd64 go build -ldflags="-s -w -X main.version=$(VERSION)" \
		-o "$(IOS_BUNDLE_OUTPUT)" ./cmd/opencan-daemon
	@echo "Installed to $(IOS_BUNDLE_OUTPUT)"

mock-acp:
	go build -o bin/mock-acp-server ./test/mock_acp_server

clean:
	rm -rf bin/ dist/
