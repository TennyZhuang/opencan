package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRotatingFileWriterRotatesWhileRunning(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "daemon.log")

	writer, err := NewRotatingFileWriter(logPath, 16, 2)
	if err != nil {
		t.Fatalf("NewRotatingFileWriter: %v", err)
	}
	defer writer.Close()

	if _, err := writer.Write([]byte("1234567890\n")); err != nil {
		t.Fatalf("first write: %v", err)
	}
	if _, err := writer.Write([]byte("abcdefghij\n")); err != nil {
		t.Fatalf("second write: %v", err)
	}

	current, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read current log: %v", err)
	}
	if got := string(current); !strings.Contains(got, "abcdefghij") {
		t.Fatalf("expected current file to contain second write, got %q", got)
	}

	archived, err := os.ReadFile(ArchivedLogFilePath(logPath, 1))
	if err != nil {
		t.Fatalf("read archived log: %v", err)
	}
	if got := string(archived); !strings.Contains(got, "1234567890") {
		t.Fatalf("expected archived file to contain first write, got %q", got)
	}
}
