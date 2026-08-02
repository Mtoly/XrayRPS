package main

import (
	"fmt"
	"os"
	"strconv"

	"github.com/Mtoly/XrayRP/panel"
	"github.com/spf13/viper"
)

func main() {
	if len(os.Args) != 5 {
		fail("usage: go-config-parse CONFIG ENABLE LISTEN STALE_AFTER")
	}

	wantEnable, err := strconv.ParseBool(os.Args[2])
	if err != nil {
		fail("invalid expected Enable value")
	}
	wantStaleAfter, err := strconv.Atoi(os.Args[4])
	if err != nil {
		fail("invalid expected ReadinessStaleAfter value")
	}

	config := viper.New()
	config.SetConfigFile(os.Args[1])
	if err := config.ReadInConfig(); err != nil {
		fail("XrayRP failed to read generated YAML")
	}

	parsed := &panel.Config{}
	if err := config.Unmarshal(parsed); err != nil {
		fail("XrayRP failed to unmarshal generated YAML")
	}
	if parsed.Observability == nil {
		fail("Observability did not parse as a top-level config")
	}
	if parsed.Observability.Enable != wantEnable || parsed.Observability.Listen != os.Args[3] || parsed.Observability.ReadinessStaleAfter != wantStaleAfter {
		fail("Observability values did not survive XrayRP parsing")
	}
	if parsed.MachineConfig == nil || !parsed.MachineConfig.Enable {
		fail("MachineConfig did not parse as enabled")
	}
	if parsed.MachineConfig.ControllerConfig == nil {
		fail("ControllerConfig did not parse under MachineConfig")
	}
	if config.IsSet("MachineConfig.WebSocketConfig") {
		fail("WebSocketConfig was also emitted beside ControllerConfig")
	}
	ws := parsed.MachineConfig.ControllerConfig.WebSocketConfig
	if ws == nil || !ws.Enable || ws.HeartbeatInterval != 30 || ws.ReconnectBackoff != 5 || !ws.ResyncOnReconnect {
		fail("WebSocketConfig did not parse under ControllerConfig")
	}
}

func fail(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
