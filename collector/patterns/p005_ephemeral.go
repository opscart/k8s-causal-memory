package patterns

// PatternEphemeral: EphemeralContainerAttached → EphemeralContainerTerminated
// Evidence Horizon H3: EphemeralContainerStatus has no lastState field.
// Kubernetes API spec (v1.32) explicitly excludes ephemeral containers from
// the LastTerminationState mechanism. Exit code, duration, and debug session
// context are permanently lost when the container exits.
const PatternEphemeral = "P005"

var EphemeralPattern = CausalPattern{
	ID:          PatternEphemeral,
	Name:        "Ephemeral Container Evidence Loss",
	Description: "Debug session state discarded on exit — EphemeralContainerStatus excludes lastState by API spec",
	Steps: []PatternStep{
		{
			EventType:   "EphemeralContainerTerminated",
			Role:        "trigger",
			Optional:    false,
			WindowSecs:  0,
			Description: "Ephemeral container exits — state lost immediately, no lastState preserved",
		},
	},
	RemediationActions: []string{
		"capture_exit_code_via_oma",
		"preserve_debug_session_duration",
		"record_target_container_context",
	},
}

func init() {
	AllPatterns[PatternEphemeral] = EphemeralPattern
}
