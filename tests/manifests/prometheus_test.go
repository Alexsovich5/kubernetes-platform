package manifests

import (
	"io/ioutil"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"gopkg.in/yaml.v2"
)

const prometheusDir = "../../prometheus"

type prometheusConfig struct {
	RuleFiles     []string `yaml:"rule_files"`
	ScrapeConfigs []struct {
		JobName        string `yaml:"job_name"`
		RelabelConfigs []struct {
			SourceLabels []string `yaml:"source_labels"`
			Action       string   `yaml:"action"`
			Regex        string   `yaml:"regex"`
		} `yaml:"relabel_configs"`
	} `yaml:"scrape_configs"`
}

func loadPrometheusConfig(t *testing.T, name string) prometheusConfig {
	data, err := ioutil.ReadFile(filepath.Join(prometheusDir, name))
	if err != nil {
		t.Fatal(err)
	}
	var cfg prometheusConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return cfg
}

func readRules(t *testing.T, name string) string {
	data, err := ioutil.ReadFile(filepath.Join(prometheusDir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

var jobSelector = regexp.MustCompile(`job="([^"]+)"`)

// An alert rule that selects a job the loading config never scrapes matches
// no series, so it can never fire.
func TestAlertRulesSelectOnlyScrapedJobs(t *testing.T) {
	for _, cfgName := range []string{"prometheus.yml", "prometheus-local.yml"} {
		cfg := loadPrometheusConfig(t, cfgName)
		jobs := map[string]bool{}
		for _, sc := range cfg.ScrapeConfigs {
			jobs[sc.JobName] = true
		}
		if len(cfg.RuleFiles) == 0 {
			t.Errorf("%s loads no rule files", cfgName)
		}
		for _, rf := range cfg.RuleFiles {
			for _, m := range jobSelector.FindAllStringSubmatch(readRules(t, rf), -1) {
				if !jobs[m[1]] {
					t.Errorf("%s selects job %q, which %s does not scrape", rf, m[1], cfgName)
				}
			}
		}
	}
}

// up == 0 only exists while the target is still discovered. When every
// platform-app target disappears (all pods gone, discovery failing) the
// series vanishes and PlatformAppDown resolves, so a separate rule must fire
// on absence.
func TestRulesAlertWhenPlatformAppTargetsAreAbsent(t *testing.T) {
	alert := regexp.MustCompile(`(?m)^ALERT PlatformAppAbsent\n  IF absent\(up\{job="platform-app"\}\)\n  FOR \S+\n`)
	for _, rf := range []string{"alert_rules.yml", "alert_rules_local.yml"} {
		if !alert.MatchString(readRules(t, rf)) {
			t.Errorf("%s has no PlatformAppAbsent rule on absent(up{job=\"platform-app\"})", rf)
		}
	}
}

// In the cluster config, platform-app pods form their own job and are kept
// out of the generic kubernetes-pods job, so each pod is scraped once.
func TestClusterConfigScrapesPlatformPodsOnceUnderPlatformAppJob(t *testing.T) {
	cfg := loadPrometheusConfig(t, "prometheus.yml")
	found := map[string]bool{}
	for _, sc := range cfg.ScrapeConfigs {
		for _, rc := range sc.RelabelConfigs {
			src := strings.Join(rc.SourceLabels, ",")
			switch {
			case sc.JobName == "platform-app" && rc.Action == "keep" &&
				src == "__meta_kubernetes_role,__meta_kubernetes_pod_label_app,__meta_kubernetes_pod_annotation_prometheus_io_scrape" &&
				rc.Regex == "pod;platform;true":
				found["keep"] = true
			case sc.JobName == "kubernetes-pods" && rc.Action == "drop" &&
				src == "__meta_kubernetes_pod_label_app" && rc.Regex == "platform":
				found["drop"] = true
			}
		}
	}
	if !found["keep"] {
		t.Error("prometheus.yml: job platform-app does not keep annotated pods labelled app=platform")
	}
	if !found["drop"] {
		t.Error("prometheus.yml: job kubernetes-pods does not drop pods labelled app=platform")
	}
}
