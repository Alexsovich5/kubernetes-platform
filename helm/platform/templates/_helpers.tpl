{{/*
fullname: the release name followed by the chart name, cut to the 24
characters Kubernetes 1.2 allows in a Service name.
*/}}
{{define "fullname"}}{{printf "%s-%s" .Release.Name .Chart.Name | trunc 24}}{{end}}
