package daemon

import (
	"io"
	"log/slog"
	"testing"
)

func TestBufferingHandlerTeesToBuffer(t *testing.T) {
	buffer := NewLogRingBuffer(10)
	handler := NewBufferingHandler(slog.NewJSONHandler(io.Discard, nil), buffer)
	logger := slog.New(handler).With("traceId", "trace-123", "component", "test")

	logger.Info("hello", "sessionId", "sess-1", "count", 3)

	entries := buffer.Recent(10)
	if len(entries) != 1 {
		t.Fatalf("expected one buffered entry, got %d", len(entries))
	}
	entry := entries[0]
	if entry.Message != "hello" {
		t.Fatalf("unexpected message: %q", entry.Message)
	}
	if entry.Attrs["traceId"] != "trace-123" {
		t.Fatalf("expected traceId attr, got %#v", entry.Attrs)
	}
	if entry.Attrs["sessionId"] != "sess-1" {
		t.Fatalf("expected sessionId attr, got %#v", entry.Attrs)
	}
	if entry.Attrs["count"] != "3" {
		t.Fatalf("expected numeric attr conversion, got %#v", entry.Attrs)
	}
}

func TestBufferingHandlerWithGroupFlattensKeys(t *testing.T) {
	buffer := NewLogRingBuffer(10)
	handler := NewBufferingHandler(slog.NewJSONHandler(io.Discard, nil), buffer)
	logger := slog.New(handler).WithGroup("daemon")

	logger.Info("grouped", "state", "idle")

	entries := buffer.Recent(10)
	if len(entries) != 1 {
		t.Fatalf("expected one buffered entry, got %d", len(entries))
	}
	if entries[0].Attrs["daemon.state"] != "idle" {
		t.Fatalf("expected grouped attr key daemon.state, got %#v", entries[0].Attrs)
	}
}
