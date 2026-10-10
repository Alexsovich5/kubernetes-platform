package manifests

import (
	"fmt"
	"io/ioutil"
	"os"
	"strconv"
	"strings"
	"testing"

	"gopkg.in/yaml.v2"
)

const (
	composeFile = "../../docker-compose.yml"
	// Written on the host by "make compose-config" (docker compose config),
	// which "make test" runs before the unit suite.
	renderedComposeFile = "../../build/cache/compose-config.yml"

	loopback      = "127.0.0.1"
	firstHostPort = 20100
	lastHostPort  = 20199
)

// Services that serve without authentication and must stay on the Compose
// network: the insecure apiserver port, etcd, Tiller's gRPC port and the
// controller health endpoints in the apiserver's network namespace.
var unpublishedServices = []string{"etcd", "apiserver", "controller-manager", "scheduler", "tiller"}

// composePortProblems returns one message per published port that is not
// bound to 127.0.0.1 inside the lane's host port range, per published port on
// an unauthenticated control-plane service, and per service on the host
// network. It accepts both the short form ("127.0.0.1:20180:8080") of the
// source file and the long form (host_ip/published/target) that
// "docker compose config" renders.
func composePortProblems(data []byte) ([]string, error) {
	var doc struct {
		Services map[string]map[interface{}]interface{} `yaml:"services"`
	}
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	if len(doc.Services) == 0 {
		return nil, fmt.Errorf("no services found")
	}

	var problems []string
	for name, svc := range doc.Services {
		if mode, _ := svc["network_mode"].(string); mode == "host" {
			problems = append(problems, fmt.Sprintf("%s: network_mode host", name))
		}
		ports, _ := svc["ports"].([]interface{})
		for _, unpub := range unpublishedServices {
			if name == unpub && len(ports) > 0 {
				problems = append(problems, fmt.Sprintf("%s: must not publish ports, has %v", name, ports))
			}
		}
		for _, p := range ports {
			hostIP, published, err := parsePort(p)
			if err != nil {
				problems = append(problems, fmt.Sprintf("%s: %v", name, err))
				continue
			}
			if hostIP != loopback {
				problems = append(problems, fmt.Sprintf("%s: port %v is bound to %q, want %s", name, p, hostIP, loopback))
			}
			n, err := strconv.Atoi(published)
			if err != nil || n < firstHostPort || n > lastHostPort {
				problems = append(problems, fmt.Sprintf("%s: host port %q outside %d-%d", name, published, firstHostPort, lastHostPort))
			}
		}
	}
	return problems, nil
}

// parsePort returns the host IP and the published host port of one entry of
// a service's ports list.
func parsePort(p interface{}) (hostIP, published string, err error) {
	switch v := p.(type) {
	case string:
		spec := strings.SplitN(v, "/", 2)[0]
		parts := strings.Split(spec, ":")
		switch len(parts) {
		case 3:
			return parts[0], parts[1], nil
		case 2:
			return "", parts[0], nil
		default:
			return "", "", fmt.Errorf("port %q publishes a random host port", v)
		}
	case map[interface{}]interface{}:
		ip, _ := v["host_ip"].(string)
		pub := fmt.Sprint(v["published"])
		if v["published"] == nil {
			pub = ""
		}
		return ip, pub, nil
	default:
		return "", "", fmt.Errorf("unrecognised port entry %v", p)
	}
}

func TestComposePortCheckerRejectsUnsafeForms(t *testing.T) {
	cases := map[string]string{
		"bare short form":       "services:\n  app:\n    ports:\n      - \"20180:8080\"\n",
		"all interfaces":        "services:\n  app:\n    ports:\n      - \"0.0.0.0:20180:8080\"\n",
		"random host port":      "services:\n  app:\n    ports:\n      - \"8080\"\n",
		"outside the lane":      "services:\n  app:\n    ports:\n      - \"127.0.0.1:8080:8080\"\n",
		"long form without ip":  "services:\n  app:\n    ports:\n      - target: 8080\n        published: \"20180\"\n",
		"apiserver published":   "services:\n  apiserver:\n    ports:\n      - \"127.0.0.1:20181:8080\"\n",
		"tiller published":      "services:\n  tiller:\n    ports:\n      - \"127.0.0.1:20182:44134\"\n",
		"host network":          "services:\n  app:\n    network_mode: host\n",
		"long form other iface": "services:\n  app:\n    ports:\n      - host_ip: 192.168.1.10\n        target: 8080\n        published: \"20180\"\n",
	}
	for name, src := range cases {
		problems, err := composePortProblems([]byte(src))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if len(problems) == 0 {
			t.Errorf("%s: accepted, want a problem", name)
		}
	}
}

func TestComposePortCheckerAcceptsLoopbackForms(t *testing.T) {
	cases := map[string]string{
		"short form": "services:\n  app:\n    ports:\n      - \"127.0.0.1:20180:8080\"\n  apiserver:\n    image: x\n",
		"long form":  "services:\n  app:\n    ports:\n      - mode: ingress\n        host_ip: 127.0.0.1\n        target: 8080\n        published: \"20180\"\n        protocol: tcp\n",
	}
	for name, src := range cases {
		problems, err := composePortProblems([]byte(src))
		if err != nil || len(problems) != 0 {
			t.Errorf("%s: problems %v, err %v; want none", name, problems, err)
		}
	}
}

func checkComposeFile(t *testing.T, path string) {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	problems, err := composePortProblems(data)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	for _, p := range problems {
		t.Errorf("%s: %s", path, p)
	}
}

func TestComposeFilePublishesOnlyOnLoopback(t *testing.T) {
	checkComposeFile(t, composeFile)
}

func TestRenderedComposeConfigPublishesOnlyOnLoopback(t *testing.T) {
	if _, err := os.Stat(renderedComposeFile); err != nil {
		t.Fatalf("%s is missing: run \"make compose-config\" on the host first (make test does): %v", renderedComposeFile, err)
	}
	checkComposeFile(t, renderedComposeFile)
}
