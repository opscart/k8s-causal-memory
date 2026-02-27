package patterns

// PatternConfigMapEnv: ConfigMapChanged → PodNotRestarted → StaleConfigInEffect
// Reference: https://opscart.com/when-kubernetes-restarts-your-pod/
const PatternConfigMapEnv = "P002"

var ConfigMapEnvPattern = CausalPattern{
	ID:          PatternConfigMapEnv,
	Name:        "ConfigMap Env Var Silent Misconfiguration",
	Description: "ConfigMap update not propagated to pods consuming it as env vars",
	Steps: []PatternStep{
		{EventType: "ConfigMapChanged", Role: "trigger", Optional: false, WindowSecs: 0, Description: "ConfigMap content changed"},
		{EventType: "PodNotRestarted", Role: "absence", Optional: false, WindowSecs: 120, Description: "No pod restart observed for env var consumers"},
	},
	RemediationActions: []string{"rollout_restart_deployment", "alert_config_drift"},
}
