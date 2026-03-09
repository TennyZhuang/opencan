package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRotateLogFilesKeepsMultipleArchives(t *testing.T) {
	dir := t.TempDir()
	basePath := filepath.Join(dir, "daemon.log")

	writeTextFile(t, basePath, "current")
	writeTextFile(t, ArchivedLogFilePath(basePath, 1), "older-1")
	writeTextFile(t, ArchivedLogFilePath(basePath, 2), "older-2")

	if err := RotateLogFiles(basePath, 3); err != nil {
		t.Fatalf("RotateLogFiles: %v", err)
	}

	assertFileText(t, ArchivedLogFilePath(basePath, 1), "current")
	assertFileText(t, ArchivedLogFilePath(basePath, 2), "older-1")
	assertFileText(t, ArchivedLogFilePath(basePath, 3), "older-2")
}

func TestLogStorageMetadataIncludesArchivedFiles(t *testing.T) {
	dir := t.TempDir()
	basePath := filepath.Join(dir, "daemon.log")

	writeTextFile(t, basePath, "current")
	writeTextFile(t, ArchivedLogFilePath(basePath, 1), "archive")

	metadata := LogStorageConfig{
		Service:          "daemon",
		CurrentFilePath:  basePath,
		MaxFileBytes:     1024,
		MaxArchivedFiles: 3,
		BufferEntryCap:   2000,
	}.Metadata()

	if metadata.SchemaVersion != LogSchemaVersion {
		t.Fatalf("expected schema version %d, got %d", LogSchemaVersion, metadata.SchemaVersion)
	}
	if metadata.CurrentFileSizeBytes == 0 {
		t.Fatalf("expected current file size in metadata, got %#v", metadata)
	}
	if len(metadata.ArchivedFiles) != 1 {
		t.Fatalf("expected one archived file, got %#v", metadata.ArchivedFiles)
	}
	if metadata.ArchivedFiles[0].Name != "daemon.log.1" {
		t.Fatalf("unexpected archived file metadata: %#v", metadata.ArchivedFiles[0])
	}
}

func writeTextFile(t *testing.T, path string, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func assertFileText(t *testing.T, path string, want string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if string(data) != want {
		t.Fatalf("unexpected contents for %s: got %q want %q", path, data, want)
	}
}
