package daemon

import (
	"os"
	"path/filepath"
	"strconv"
)

const LogSchemaVersion = 1

type LogStorageConfig struct {
	Service          string
	CurrentFilePath  string
	MaxFileBytes     int64
	MaxArchivedFiles int
	BufferEntryCap   int
}

type LogArchiveFileInfo struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	SizeBytes int64  `json:"sizeBytes"`
}

type LogStorageMetadata struct {
	SchemaVersion        int                  `json:"schemaVersion"`
	Service              string               `json:"service"`
	CurrentFilePath      string               `json:"currentFilePath"`
	CurrentFileSizeBytes int64                `json:"currentFileSizeBytes"`
	ArchivedFiles        []LogArchiveFileInfo `json:"archivedFiles"`
	MaxFileBytes         int64                `json:"maxFileBytes"`
	MaxArchivedFiles     int                  `json:"maxArchivedFiles"`
	BufferEntryCapacity  *int                 `json:"bufferEntryCapacity,omitempty"`
}

func (c LogStorageConfig) Metadata() LogStorageMetadata {
	metadata := LogStorageMetadata{
		SchemaVersion:        LogSchemaVersion,
		Service:              c.Service,
		CurrentFilePath:      c.CurrentFilePath,
		CurrentFileSizeBytes: fileSize(c.CurrentFilePath),
		MaxFileBytes:         c.MaxFileBytes,
		MaxArchivedFiles:     c.MaxArchivedFiles,
		ArchivedFiles:        archivedLogFiles(c.CurrentFilePath, c.MaxArchivedFiles),
	}
	if c.BufferEntryCap > 0 {
		value := c.BufferEntryCap
		metadata.BufferEntryCapacity = &value
	}
	return metadata
}

func ArchivedLogFilePath(basePath string, index int) string {
	return basePath + "." + strconv.Itoa(index)
}

func archivedLogFiles(basePath string, maxArchivedFiles int) []LogArchiveFileInfo {
	if maxArchivedFiles <= 0 {
		return nil
	}
	files := make([]LogArchiveFileInfo, 0, maxArchivedFiles)
	for index := 1; index <= maxArchivedFiles; index++ {
		path := ArchivedLogFilePath(basePath, index)
		size := fileSize(path)
		if size <= 0 {
			continue
		}
		files = append(files, LogArchiveFileInfo{
			Name:      filepath.Base(path),
			Path:      path,
			SizeBytes: size,
		})
	}
	return files
}

func RotateLogFiles(basePath string, maxArchivedFiles int) error {
	if maxArchivedFiles <= 0 {
		if err := os.Remove(basePath); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}

	for index := maxArchivedFiles; index >= 1; index-- {
		destination := ArchivedLogFilePath(basePath, index)
		source := basePath
		if index > 1 {
			source = ArchivedLogFilePath(basePath, index-1)
		}

		if _, err := os.Stat(destination); err == nil {
			if err := os.Remove(destination); err != nil {
				return err
			}
		}
		if _, err := os.Stat(source); err == nil {
			if err := os.Rename(source, destination); err != nil {
				return err
			}
		}
	}

	return nil
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}
