package patterns

// PatternConfigMapMount: ConfigMapChanged → KubeletSymlinkSwap → inotifyFires
// Reference: https://opscart.com/when-kubernetes-restarts-your-pod/
const PatternConfigMapMount = "P003"

var ConfigMapMountPattern = CausalPattern{
	ID:          PatternConfigMapMount,
	Name:        "ConfigMap Volume Mount Symlink Swap",
	Description: "ConfigMap update propagated via kubelet atomic symlink swap",
	Steps: []PatternStep{
		{EventType: "ConfigMapChanged", Role: "trigger", Optional: false, WindowSecs: 0, Description: "ConfigMap content changed"},
		{EventType: "KubeletSync", Role: "propagation", Optional: true, WindowSecs: 90, Description: "Kubelet syncs ConfigMap via symlink swap"},
	},
	RemediationActions: []string{"verify_inotify_watch_pattern", "check_app_reload_logs"},
}
