package proxy

import (
	"bytes"
	"io"
	"testing"

	"github.com/anthropics/opencan-daemon/internal/ioutils"
)

type shortWriteBuffer struct {
	buf      bytes.Buffer
	maxChunk int
}

func (w *shortWriteBuffer) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	n := len(p)
	if w.maxChunk > 0 && n > w.maxChunk {
		n = w.maxChunk
	}
	return w.buf.Write(p[:n])
}

type zeroWriteBuffer struct{}

func (zeroWriteBuffer) Write(_ []byte) (int, error) { return 0, nil }

func TestWriteAllHandlesShortWrites(t *testing.T) {
	w := &shortWriteBuffer{maxChunk: 2}
	payload := []byte("0123456789")

	if err := ioutils.WriteAll(w, payload); err != nil {
		t.Fatalf("WriteAll failed: %v", err)
	}
	if got := w.buf.Bytes(); !bytes.Equal(got, payload) {
		t.Fatalf("unexpected payload written: got=%q want=%q", got, payload)
	}
}

func TestWriteAllDetectsZeroProgress(t *testing.T) {
	err := ioutils.WriteAll(zeroWriteBuffer{}, []byte("xyz"))
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err != io.ErrShortWrite {
		t.Fatalf("unexpected error: %v", err)
	}
}
