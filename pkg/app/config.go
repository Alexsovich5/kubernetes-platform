package app

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"
)

// LoadConfig reads a ConfigMap-style directory into a key/value map. Each
// regular file (or symlink to one) becomes a key named after the file, with
// its contents trimmed of surrounding whitespace. Hidden entries such as the
// "..data" symlink and timestamped data directories that Kubernetes creates
// inside ConfigMap volumes are skipped, as are subdirectories. A missing
// directory yields an empty map and a nil error.
func LoadConfig(dir string) (map[string]string, error) {
	cfg := map[string]string{}

	entries, err := ioutil.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return nil, err
	}

	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		path := filepath.Join(dir, name)
		// Stat follows symlinks, so ConfigMap keys that link through
		// "..data" resolve to the file they point at.
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		data, err := ioutil.ReadFile(path)
		if err != nil {
			return nil, err
		}
		cfg[name] = strings.TrimSpace(string(data))
	}
	return cfg, nil
}
