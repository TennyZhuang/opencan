package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
)

// BufferingHandler tees slog records to an in-memory ring buffer.
type BufferingHandler struct {
	inner  slog.Handler
	buffer *LogRingBuffer
	attrs  []slog.Attr
	groups []string
}

func NewBufferingHandler(inner slog.Handler, buffer *LogRingBuffer) *BufferingHandler {
	if buffer == nil {
		buffer = NewLogRingBuffer(2000)
	}
	return &BufferingHandler{
		inner:  inner,
		buffer: buffer,
	}
}

func (h *BufferingHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.inner.Enabled(ctx, level)
}

func (h *BufferingHandler) Handle(ctx context.Context, record slog.Record) error {
	if err := h.inner.Handle(ctx, record); err != nil {
		return err
	}

	attrs := make(map[string]string)
	for _, attr := range h.attrs {
		flattenAttr(attrs, h.groups, attr)
	}
	record.Attrs(func(attr slog.Attr) bool {
		flattenAttr(attrs, h.groups, attr)
		return true
	})

	ts := record.Time
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	entry := LogBufferEntry{
		Timestamp: ts.Format(time.RFC3339Nano),
		Level:     strings.ToLower(record.Level.String()),
		Message:   record.Message,
		Attrs:     attrs,
	}
	if len(entry.Attrs) == 0 {
		entry.Attrs = nil
	}
	h.buffer.Append(entry)
	return nil
}

func (h *BufferingHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	merged := make([]slog.Attr, 0, len(h.attrs)+len(attrs))
	merged = append(merged, h.attrs...)
	merged = append(merged, attrs...)
	return &BufferingHandler{
		inner:  h.inner.WithAttrs(attrs),
		buffer: h.buffer,
		attrs:  merged,
		groups: append([]string(nil), h.groups...),
	}
}

func (h *BufferingHandler) WithGroup(name string) slog.Handler {
	groups := append([]string(nil), h.groups...)
	if name != "" {
		groups = append(groups, name)
	}
	return &BufferingHandler{
		inner:  h.inner.WithGroup(name),
		buffer: h.buffer,
		attrs:  append([]slog.Attr(nil), h.attrs...),
		groups: groups,
	}
}

func flattenAttr(dst map[string]string, groups []string, attr slog.Attr) {
	if attr.Key == "" {
		return
	}

	value := attr.Value.Resolve()
	if value.Kind() == slog.KindGroup {
		nextGroups := append([]string(nil), groups...)
		nextGroups = append(nextGroups, attr.Key)
		for _, nested := range value.Group() {
			flattenAttr(dst, nextGroups, nested)
		}
		return
	}

	key := attr.Key
	if len(groups) > 0 {
		key = strings.Join(append(append([]string(nil), groups...), attr.Key), ".")
	}
	dst[key] = valueToString(value)
}

func valueToString(value slog.Value) string {
	switch value.Kind() {
	case slog.KindString:
		return value.String()
	case slog.KindInt64:
		return fmt.Sprintf("%d", value.Int64())
	case slog.KindUint64:
		return fmt.Sprintf("%d", value.Uint64())
	case slog.KindFloat64:
		return fmt.Sprintf("%f", value.Float64())
	case slog.KindBool:
		if value.Bool() {
			return "true"
		}
		return "false"
	case slog.KindDuration:
		return value.Duration().String()
	case slog.KindTime:
		return value.Time().Format(time.RFC3339Nano)
	case slog.KindAny:
		if value.Any() == nil {
			return ""
		}
		return fmt.Sprintf("%v", value.Any())
	default:
		return value.String()
	}
}
