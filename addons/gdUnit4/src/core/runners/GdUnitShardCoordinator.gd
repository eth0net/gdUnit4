## Coordinates an opt-in parallel test run by sharding the discovered test suites across
## several headless child processes (each a normal GdUnitCmdTool run on a subset of suites)
## and merging their JUnit reports into a single result.
class_name GdUnitShardCoordinator
extends Node

const CHILD_SCRIPT := "res://addons/gdUnit4/bin/GdUnitCmdTool.gd"

var _shards := 0
var _include_paths: Array[String] = []
var _report_base := ""
var _verbose := false
var _headless := false


func _ready() -> void:
	_execute.call_deferred()


func _execute() -> void:
	get_tree().quit(_run())


func _run() -> int:
	_parse_args()
	if _shards < 2:
		push_error("GdUnitShardCoordinator: --shards must be >= 2")
		return 100
	if _report_base.is_empty():
		_report_base = "res://reports"
	_headless = DisplayServer.get_name() == "headless"

	var suites := _discover_suites()
	if suites.is_empty():
		prints("No test suites found for", _include_paths)
		return 0
	var shard_count: int = mini(_shards, suites.size())
	var buckets := _partition(suites, shard_count)
	var report_dir := "%s/report_%d" % [_report_base, _next_report_index(_report_base)]
	prints("Running %d test suites across %d shards -> %s" % [suites.size(), shard_count, report_dir])

	var codes := _run_shards(buckets, report_dir)
	_merge_reports(shard_count, report_dir)
	return _aggregate_exit_code(codes)


func _run_shards(buckets: Array, report_dir: String) -> Array[int]:
	var godot := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var threads: Array[Thread] = []
	for shard_index in buckets.size():
		var args := _child_args(project_root, buckets[shard_index], "%s/shard_%d" % [report_dir, shard_index])
		var thread := Thread.new()
		@warning_ignore("return_value_discarded")
		thread.start(func() -> int:
			var output := []
			return OS.execute(godot, args, output, true))
		threads.append(thread)

	var codes: Array[int] = []
	for shard_index in threads.size():
		var code: int = threads[shard_index].wait_to_finish()
		prints("Shard %d finished with exit code %d" % [shard_index, code])
		codes.append(code)
	return codes


func _child_args(project_root: String, suites: Array, shard_dir: String) -> PackedStringArray:
	var args := PackedStringArray(["--path", project_root])
	if _headless:
		args.append("--headless")
	# --remote-debug tcp://127.0.0.1:0 suppresses the interactive debugger so a child parse error
	# cannot hang the shard (port 0 is never bound, matching runtest.sh).
	@warning_ignore("return_value_discarded")
	args.append_array(["-d", "--remote-debug", "tcp://127.0.0.1:0", "-s", CHILD_SCRIPT])
	for suite: String in suites:
		@warning_ignore("return_value_discarded")
		args.append_array(["-a", suite])
	@warning_ignore("return_value_discarded")
	args.append_array(["-rd", shard_dir, "-c"])
	if _headless:
		args.append("--ignoreHeadlessMode")
	if _verbose:
		args.append("--verbose")
	return args


func _merge_reports(shard_count: int, report_dir: String) -> void:
	var shard_result_files: Array[String] = []
	for shard_index in shard_count:
		var result_file := _find_result_file("%s/shard_%d" % [report_dir, shard_index])
		if not result_file.is_empty():
			shard_result_files.append(result_file)
	var merged := JUnitXmlReportMerger.merge(shard_result_files, report_dir)
	if merged.is_empty():
		push_warning("GdUnitShardCoordinator: no shard reports found to merge")
	else:
		prints("Merged JUnit report:", merged)


func _aggregate_exit_code(codes: Array[int]) -> int:
	var result := 0
	for code in codes:
		if code == 100 or (code != 0 and code != 101):
			return 100
		if code == 101:
			result = 101
	return result


func _discover_suites() -> Array[String]:
	var scanner := GdUnitTestSuiteScanner.new()
	var suites: Array[String] = []
	for path in _include_paths:
		for script in scanner.scan(path):
			var suite_path := script.resource_path
			if not suite_path.is_empty() and not suites.has(suite_path):
				suites.append(suite_path)
	suites.sort()
	return suites


func _partition(suites: Array[String], shard_count: int) -> Array:
	var buckets: Array = []
	for _index in shard_count:
		buckets.append([] as Array[String])
	for index in suites.size():
		var bucket: Array[String] = buckets[index % shard_count]
		bucket.append(suites[index])
	return buckets


func _find_result_file(shard_dir: String) -> String:
	if not DirAccess.dir_exists_absolute(shard_dir):
		return ""
	for report_dir in DirAccess.get_directories_at(shard_dir):
		var candidate := "%s/%s/results.xml" % [shard_dir, report_dir]
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


func _next_report_index(base: String) -> int:
	if not DirAccess.dir_exists_absolute(base):
		return 1
	var last := 0
	for dir in DirAccess.get_directories_at(base):
		if dir.begins_with("report_"):
			last = maxi(last, dir.trim_prefix("report_").to_int())
	return last + 1


func _parse_args() -> void:
	var args := OS.get_cmdline_args()
	for index in args.size():
		match args[index]:
			"--shards":
				if index + 1 < args.size():
					_shards = args[index + 1].to_int()
			"-a", "--add":
				if index + 1 < args.size():
					_include_paths.append(args[index + 1])
			"-rd", "--report-directory":
				if index + 1 < args.size():
					_report_base = GdUnitFileAccess.make_qualified_path(args[index + 1])
			"--verbose":
				_verbose = true
