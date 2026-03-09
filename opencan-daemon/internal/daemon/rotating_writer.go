package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type RotatingFileWriter struct {
	path             string
	maxFileBytes     int64
	maxArchivedFiles int

	mu   sync.Mutex
	file *os.File
	size int64
}

func NewRotatingFileWriter(path string, maxFileBytes int64, maxArchivedFiles int) (*RotatingFileWriter, error) {
	if maxFileBytes <= 0 {
		return nil, fmt.Errorf("maxFileBytes must be positive")
	}
	if maxArchivedFiles < 0 {
		return nil, fmt.Errorf("maxArchivedFiles must be non-negative")
	}

	writer := &RotatingFileWriter{
		path:             path,
		maxFileBytes:     maxFileBytes,
		maxArchivedFiles: maxArchivedFiles,
	}
	if err := writer.open(); err != nil {
		return nil, err
	}
	return writer, nil
}

func (w *RotatingFileWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	if err := w.rotateIfNeeded(int64(len(p))); err != nil {
		return 0, err
	}
	written, err := w.file.Write(p)
	w.size += int64(written)
	return written, err
}

func (w *RotatingFileWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	err := w.file.Close()
	w.file = nil
	return err
}

func (w *RotatingFileWriter) open() error {
	if err := os.MkdirAll(filepath.Dir(w.path), 0700); err != nil {
		return fmt.Errorf("create log directory: %w", err)
	}

	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return fmt.Errorf("open daemon log file: %w", err)
	}

	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return fmt.Errorf("stat daemon log file: %w", err)
	}

	w.file = file
	w.size = info.Size()
	return nil
}

func (w *RotatingFileWriter) rotateIfNeeded(incomingBytes int64) error {
	if w.file == nil {
		if err := w.open(); err != nil {
			return err
		}
	}
	if w.size+incomingBytes <= w.maxFileBytes {
		return nil
	}
	if err := w.file.Close(); err != nil {
		return fmt.Errorf("close daemon log file before rotate: %w", err)
	}
	w.file = nil
	w.size = 0
	if err := RotateLogFiles(w.path, w.maxArchivedFiles); err != nil {
		return fmt.Errorf("rotate daemon log: %w", err)
	}
	return w.open()
}
