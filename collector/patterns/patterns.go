package patterns

type CausalPattern struct {
	ID                 string        `json:"id"`
	Name               string        `json:"name"`
	Description        string        `json:"description"`
	Steps              []PatternStep `json:"steps"`
	RemediationActions []string      `json:"remediation_actions"`
}

type PatternStep struct {
	EventType   string `json:"event_type"`
	Role        string `json:"role"`
	Optional    bool   `json:"optional"`
	WindowSecs  int    `json:"window_secs"`
	Description string `json:"description"`
}

var AllPatterns = map[string]CausalPattern{
	PatternOOMKill:        OOMKillPattern,
	PatternConfigMapEnv:   ConfigMapEnvPattern,
	PatternConfigMapMount: ConfigMapMountPattern,
}
