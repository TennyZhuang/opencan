package daemon

import (
	"fmt"
	"sync"
	"testing"
)

func TestLogRingBufferCapacityAndRecent(t *testing.T) {
	buf := NewLogRingBuffer(3)
	for i := 1; i <= 5; i++ {
		buf.Append(LogBufferEntry{
			Timestamp: fmt.Sprintf("t-%d", i),
			Level:     "info",
			Message:   fmt.Sprintf("m-%d", i),
		})
	}

	recent := buf.Recent(10)
	if len(recent) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(recent))
	}
	if recent[0].Message != "m-3" || recent[2].Message != "m-5" {
		t.Fatalf("unexpected eviction order: %#v", recent)
	}
}

func TestLogRingBufferFilter(t *testing.T) {
	buf := NewLogRingBuffer(10)
	buf.Append(LogBufferEntry{Message: "a", Attrs: map[string]string{"traceId": "trace-1"}})
	buf.Append(LogBufferEntry{Message: "b", Attrs: map[string]string{"traceId": "trace-2"}})
	buf.Append(LogBufferEntry{Message: "c", Attrs: map[string]string{"traceId": "trace-1"}})

	filtered := buf.Filter("trace-1")
	if len(filtered) != 2 {
		t.Fatalf("expected 2 filtered entries, got %d", len(filtered))
	}
	if filtered[0].Message != "a" || filtered[1].Message != "c" {
		t.Fatalf("unexpected filtered entries: %#v", filtered)
	}
}

func TestLogRingBufferConcurrentAppend(t *testing.T) {
	buf := NewLogRingBuffer(200)
	var wg sync.WaitGroup

	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				buf.Append(LogBufferEntry{Message: fmt.Sprintf("%d-%d", worker, j)})
			}
		}(i)
	}

	wg.Wait()
	recent := buf.Recent(200)
	if len(recent) != 200 {
		t.Fatalf("expected max size 200 after concurrent append, got %d", len(recent))
	}
}
