// Package manifests checks invariants of the Kubernetes manifests in k8s/.
package manifests

import (
	"io/ioutil"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v2"
)

const manifestDir = "../../k8s"

type objectMeta struct {
	Name        string            `yaml:"name"`
	Namespace   string            `yaml:"namespace"`
	Labels      map[string]string `yaml:"labels"`
	Annotations map[string]string `yaml:"annotations"`
}

type httpGet struct {
	Path string      `yaml:"path"`
	Port interface{} `yaml:"port"`
}

type probe struct {
	HTTPGet *httpGet `yaml:"httpGet"`
}

type envVar struct {
	Name string `yaml:"name"`
}

type containerPort struct {
	ContainerPort int    `yaml:"containerPort"`
	Name          string `yaml:"name"`
}

type container struct {
	Name           string                       `yaml:"name"`
	Image          string                       `yaml:"image"`
	Ports          []containerPort              `yaml:"ports"`
	Env            []envVar                     `yaml:"env"`
	ReadinessProbe *probe                       `yaml:"readinessProbe"`
	LivenessProbe  *probe                       `yaml:"livenessProbe"`
	Resources      map[string]map[string]string `yaml:"resources"`
}

type volume struct {
	Name      string `yaml:"name"`
	ConfigMap *struct {
		Name string `yaml:"name"`
	} `yaml:"configMap"`
}

type podSpec struct {
	Containers []container `yaml:"containers"`
	Volumes    []volume    `yaml:"volumes"`
}

type rollingUpdate struct {
	MaxSurge       interface{} `yaml:"maxSurge"`
	MaxUnavailable interface{} `yaml:"maxUnavailable"`
}

type object struct {
	APIVersion string     `yaml:"apiVersion"`
	Kind       string     `yaml:"kind"`
	Metadata   objectMeta `yaml:"metadata"`
	Spec       struct {
		Replicas int               `yaml:"replicas"`
		Selector map[string]string `yaml:"selector"`
		Strategy struct {
			Type          string         `yaml:"type"`
			RollingUpdate *rollingUpdate `yaml:"rollingUpdate"`
		} `yaml:"strategy"`
		Template struct {
			Metadata objectMeta `yaml:"metadata"`
			Spec     podSpec    `yaml:"spec"`
		} `yaml:"template"`
	} `yaml:"spec"`
	File string `yaml:"-"`
}

func (o object) namespace() string {
	if o.Metadata.Namespace == "" {
		return "default"
	}
	return o.Metadata.Namespace
}

// splitDocuments splits a multi-document YAML file on "\n---" separators.
func splitDocuments(data string) []string {
	var docs []string
	for _, part := range strings.Split("\n"+data, "\n---") {
		if strings.TrimSpace(stripComments(part)) == "" {
			continue
		}
		docs = append(docs, part)
	}
	return docs
}

func stripComments(s string) string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func loadObjects(t *testing.T) []object {
	files, err := filepath.Glob(filepath.Join(manifestDir, "*.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatalf("no manifests found in %s", manifestDir)
	}
	var objs []object
	for _, f := range files {
		data, err := ioutil.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for i, doc := range splitDocuments(string(data)) {
			var o object
			if err := yaml.Unmarshal([]byte(doc), &o); err != nil {
				t.Fatalf("%s document %d: %v", f, i, err)
			}
			o.File = filepath.Base(f)
			objs = append(objs, o)
		}
	}
	return objs
}

func ofKind(objs []object, kind string) []object {
	var out []object
	for _, o := range objs {
		if o.Kind == kind {
			out = append(out, o)
		}
	}
	return out
}

func appDeployment(t *testing.T, objs []object) object {
	for _, d := range ofKind(objs, "Deployment") {
		if d.Metadata.Name == "platform-app" {
			return d
		}
	}
	t.Fatal("Deployment platform-app not found in k8s/")
	return object{}
}

func TestSplitDocumentsHandlesSeparatorsAndComments(t *testing.T) {
	docs := splitDocuments("# header\n\nkind: A\n---\nkind: B\n---\n# only a comment\n")
	if len(docs) != 2 {
		t.Fatalf("got %d documents, want 2: %q", len(docs), docs)
	}
}

func TestOnlyTheAppDeploymentRemainsInDeploymentFile(t *testing.T) {
	for _, d := range ofKind(loadObjects(t), "Deployment") {
		if d.File == "deployment.yaml" && d.Metadata.Name != "platform-app" {
			t.Errorf("unexpected Deployment %q in deployment.yaml", d.Metadata.Name)
		}
	}
}

func TestServiceSelectorsMatchDeploymentTemplateLabels(t *testing.T) {
	objs := loadObjects(t)
	services := ofKind(objs, "Service")
	if len(services) == 0 {
		t.Fatal("no Services found")
	}
	for _, s := range services {
		if len(s.Spec.Selector) == 0 {
			t.Errorf("Service %s has no selector", s.Metadata.Name)
			continue
		}
		matched := false
		for _, d := range ofKind(objs, "Deployment") {
			if d.namespace() != s.namespace() {
				continue
			}
			subset := true
			for k, v := range s.Spec.Selector {
				if d.Spec.Template.Metadata.Labels[k] != v {
					subset = false
					break
				}
			}
			if subset {
				matched = true
			}
		}
		if !matched {
			t.Errorf("Service %s selector %v matches no Deployment template labels", s.Metadata.Name, s.Spec.Selector)
		}
	}
}

func TestProbesUseHealthOnContainerPort(t *testing.T) {
	d := appDeployment(t, loadObjects(t))
	for _, c := range d.Spec.Template.Spec.Containers {
		if len(c.Ports) == 0 || c.Ports[0].ContainerPort != 8080 {
			t.Errorf("container %s: want containerPort 8080, got %v", c.Name, c.Ports)
		}
		for name, p := range map[string]*probe{"readiness": c.ReadinessProbe, "liveness": c.LivenessProbe} {
			if p == nil || p.HTTPGet == nil {
				t.Errorf("container %s: %s probe missing httpGet", c.Name, name)
				continue
			}
			if p.HTTPGet.Path != "/health" {
				t.Errorf("container %s: %s probe path %q, want /health", c.Name, name, p.HTTPGet.Path)
			}
			port := p.HTTPGet.Port
			if port != 8080 && port != "http" {
				t.Errorf("container %s: %s probe port %v, want 8080", c.Name, name, port)
			}
		}
	}
}

func TestResourceRequestsAndLimitsAreSet(t *testing.T) {
	d := appDeployment(t, loadObjects(t))
	for _, c := range d.Spec.Template.Spec.Containers {
		for _, kind := range []string{"requests", "limits"} {
			r := c.Resources[kind]
			if r["cpu"] == "" || r["memory"] == "" {
				t.Errorf("container %s: %s must set cpu and memory, got %v", c.Name, kind, r)
			}
		}
	}
}

func TestRollingUpdateSurgeOneUnavailableZero(t *testing.T) {
	d := appDeployment(t, loadObjects(t))
	st := d.Spec.Strategy
	if st.Type != "RollingUpdate" || st.RollingUpdate == nil {
		t.Fatalf("strategy %+v, want RollingUpdate", st)
	}
	if st.RollingUpdate.MaxSurge != 1 || st.RollingUpdate.MaxUnavailable != 0 {
		t.Errorf("rollingUpdate surge=%v unavailable=%v, want 1 and 0",
			st.RollingUpdate.MaxSurge, st.RollingUpdate.MaxUnavailable)
	}
}

func TestPrometheusAnnotationsArePresent(t *testing.T) {
	d := appDeployment(t, loadObjects(t))
	want := map[string]string{
		"prometheus.io/scrape": "true",
		"prometheus.io/port":   "8080",
		"prometheus.io/path":   "/metrics",
	}
	got := d.Spec.Template.Metadata.Annotations
	for k, v := range want {
		if got[k] != v {
			t.Errorf("pod annotation %s = %q, want %q", k, got[k], v)
		}
	}
}

func TestAppImageIsPinned(t *testing.T) {
	d := appDeployment(t, loadObjects(t))
	if img := d.Spec.Template.Spec.Containers[0].Image; img != "platform-app:0.1.0" {
		t.Errorf("image %q, want platform-app:0.1.0", img)
	}
}

func TestNoImageUsesLatestTag(t *testing.T) {
	for _, d := range ofKind(loadObjects(t), "Deployment") {
		for _, c := range d.Spec.Template.Spec.Containers {
			last := c.Image[strings.LastIndex(c.Image, "/")+1:]
			if !strings.Contains(last, ":") || strings.HasSuffix(last, ":latest") {
				t.Errorf("%s/%s: image %q has no pinned tag", d.Metadata.Name, c.Name, c.Image)
			}
		}
	}
}

func TestNoContainerSetsNodeEnv(t *testing.T) {
	for _, d := range ofKind(loadObjects(t), "Deployment") {
		for _, c := range d.Spec.Template.Spec.Containers {
			for _, e := range c.Env {
				if e.Name == "NODE_ENV" {
					t.Errorf("%s/%s sets NODE_ENV", d.Metadata.Name, c.Name)
				}
			}
		}
	}
}

func TestConfigMapVolumesReferenceDefinedConfigMaps(t *testing.T) {
	objs := loadObjects(t)
	defined := map[string]bool{}
	for _, cm := range ofKind(objs, "ConfigMap") {
		defined[cm.namespace()+"/"+cm.Metadata.Name] = true
	}
	for _, d := range ofKind(objs, "Deployment") {
		for _, v := range d.Spec.Template.Spec.Volumes {
			if v.ConfigMap == nil {
				continue
			}
			key := d.namespace() + "/" + v.ConfigMap.Name
			if !defined[key] {
				t.Errorf("Deployment %s volume %s references ConfigMap %s, which k8s/ does not define", d.Metadata.Name, v.Name, key)
			}
		}
	}
}
