package proxy

import (
	"encoding/json"
	"sync"
	"testing"
)

func TestEventBuffer_Append(t *testing.T) {
	buf := NewEventBuffer(100)

	seq1 := buf.Append(json.RawMessage(`{"event":1}`))
	seq2 := buf.Append(json.RawMessage(`{"event":2}`))

	if seq1 != 1 {
		t.Fatalf("expected seq 1, got %d", seq1)
	}
	if seq2 != 2 {
		t.Fatalf("expected seq 2, got %d", seq2)
	}
	if buf.Len() != 2 {
		t.Fatalf("expected len 2, got %d", buf.Len())
	}
}

func TestEventBuffer_Since(t *testing.T) {
	buf := NewEventBuffer(100)
	buf.Append(json.RawMessage(`{"event":1}`))
	buf.Append(json.RawMessage(`{"event":2}`))
	buf.Append(json.RawMessage(`{"event":3}`))

	// Since(0) returns all events
	events := buf.Since(0)
	if len(events) != 3 {
		t.Fatalf("Since(0): expected 3 events, got %d", len(events))
	}

	// Since(1) returns events 2, 3
	events = buf.Since(1)
	if len(events) != 2 {
		t.Fatalf("Since(1): expected 2 events, got %d", len(events))
	}
	if events[0].Seq != 2 {
		t.Fatalf("expected seq 2, got %d", events[0].Seq)
	}

	// Since(3) returns nil (no events after 3)
	events = buf.Since(3)
	if events != nil {
		t.Fatalf("Since(3): expected nil, got %d events", len(events))
	}
}

func TestEventBuffer_LastSeq(t *testing.T) {
	buf := NewEventBuffer(100)

	if buf.LastSeq() != 0 {
		t.Fatalf("empty buffer: expected 0, got %d", buf.LastSeq())
	}

	buf.Append(json.RawMessage(`{}`))
	buf.Append(json.RawMessage(`{}`))
	buf.Append(json.RawMessage(`{}`))

	if buf.LastSeq() != 3 {
		t.Fatalf("expected 3, got %d", buf.LastSeq())
	}
}

func TestEventBuffer_Overflow(t *testing.T) {
	buf := NewEventBuffer(3)

	buf.Append(json.RawMessage(`{"event":1}`))
	buf.Append(json.RawMessage(`{"event":2}`))
	buf.Append(json.RawMessage(`{"event":3}`))
	buf.Append(json.RawMessage(`{"event":4}`))
	buf.Append(json.RawMessage(`{"event":5}`))

	if buf.Len() != 3 {
		t.Fatalf("expected len 3 after overflow, got %d", buf.Len())
	}

	events := buf.Since(0)
	if len(events) != 3 {
		t.Fatalf("expected 3 events, got %d", len(events))
	}
	// Oldest should be seq 3 (1 and 2 evicted)
	if events[0].Seq != 3 {
		t.Fatalf("expected oldest seq 3, got %d", events[0].Seq)
	}
	if events[2].Seq != 5 {
		t.Fatalf("expected newest seq 5, got %d", events[2].Seq)
	}
}

func TestEventBuffer_SinceAfterOverflow(t *testing.T) {
	buf := NewEventBuffer(3)

	// Add 5 events (buffer holds 3)
	for i := 1; i <= 5; i++ {
		buf.Append(json.RawMessage(`{}`))
	}

	// Since(2) — seq 2 was evicted, but seq 3,4,5 remain
	events := buf.Since(2)
	if len(events) != 3 {
		t.Fatalf("expected 3, got %d", len(events))
	}
	if events[0].Seq != 3 {
		t.Fatalf("expected seq 3, got %d", events[0].Seq)
	}

	// Since(4) — only seq 5 remains after 4
	events = buf.Since(4)
	if len(events) != 1 {
		t.Fatalf("expected 1, got %d", len(events))
	}
}

func TestEventBuffer_ConcurrentAccess(t *testing.T) {
	buf := NewEventBuffer(1000)
	var wg sync.WaitGroup

	// Concurrent writers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				buf.Append(json.RawMessage(`{"concurrent":true}`))
			}
		}()
	}

	// Concurrent readers
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				buf.Since(0)
				buf.LastSeq()
				buf.Len()
			}
		}()
	}

	wg.Wait()

	if buf.Len() != 1000 {
		t.Fatalf("expected 1000 events, got %d", buf.Len())
	}
}

func TestEventBuffer_DefaultMaxSizeWhenInvalid(t *testing.T) {
	buf := NewEventBuffer(0)

	for i := 0; i < 10005; i++ {
		buf.Append(json.RawMessage(`{}`))
	}

	if buf.Len() != 10000 {
		t.Fatalf("expected default max size 10000, got %d", buf.Len())
	}

	events := buf.Since(0)
	if len(events) != 10000 {
		t.Fatalf("expected 10000 events in replay, got %d", len(events))
	}
	// 5 events should be evicted from the front.
	if events[0].Seq != 6 {
		t.Fatalf("expected oldest seq 6 after default overflow, got %d", events[0].Seq)
	}
	if buf.LastSeq() != 10005 {
		t.Fatalf("expected last seq 10005, got %d", buf.LastSeq())
	}
}

func TestEventBuffer_SequenceMonotonicAfterHeavyOverflow(t *testing.T) {
	buf := NewEventBuffer(2)

	for i := 0; i < 10; i++ {
		buf.Append(json.RawMessage(`{}`))
	}

	if got := buf.LastSeq(); got != 10 {
		t.Fatalf("expected last seq 10, got %d", got)
	}

	events := buf.Since(0)
	if len(events) != 2 {
		t.Fatalf("expected 2 events, got %d", len(events))
	}
	if events[0].Seq != 9 || events[1].Seq != 10 {
		t.Fatalf("expected seqs [9,10], got [%d,%d]", events[0].Seq, events[1].Seq)
	}
}

func TestEventBuffer_SinceReturnsSnapshotCopy(t *testing.T) {
	buf := NewEventBuffer(10)
	buf.Append(json.RawMessage(`{"event":1}`))
	buf.Append(json.RawMessage(`{"event":2}`))

	snapshot := buf.Since(0)
	if len(snapshot) != 2 {
		t.Fatalf("expected snapshot len 2, got %d", len(snapshot))
	}

	buf.Append(json.RawMessage(`{"event":3}`))
	if len(snapshot) != 2 {
		t.Fatalf("snapshot should stay unchanged after append, got len %d", len(snapshot))
	}
	if snapshot[0].Seq != 1 || snapshot[1].Seq != 2 {
		t.Fatalf("snapshot sequence changed unexpectedly: %+v", snapshot)
	}
}
