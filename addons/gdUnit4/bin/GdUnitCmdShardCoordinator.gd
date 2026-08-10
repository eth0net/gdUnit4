#!/usr/bin/env -S godot -s
extends SceneTree

# Entry point for parallel (process-sharded) test execution.
# Usage: godot -s res://addons/gdUnit4/bin/GdUnitCmdShardCoordinator.gd --shards N -a <path> [-a <path> ...] [-rd <dir>]

var _coordinator: GdUnitShardCoordinator


func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	_coordinator = GdUnitShardCoordinator.new()
	root.add_child(_coordinator)


func _finalize() -> void:
	queue_delete(_coordinator)
