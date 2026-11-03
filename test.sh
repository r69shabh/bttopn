#!/bin/bash
# Headless unit tests for the config layer (no Touch Bar / Accessibility needed).
set -e
cd "$(dirname "$0")"
TMP_BIN="$(mktemp -d)/bttopn_config_test"
swiftc -o "$TMP_BIN" Sources/KeyAction.swift Sources/ConfigManager.swift tests/config_test.swift
"$TMP_BIN"
