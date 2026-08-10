## Coordinates an opt-in parallel test run by sharding the discovered test suites across
## several headless child processes (each a normal GdUnitCmdTool run on a subset of suites)
## and merging their JUnit reports into a single result.
class_name GdUnitShardCoordinator
extends Node

const CHILD_SCRIPT := "res://addons/gdUnit4/bin/GdUnitCmdTool.gd"
# Persisted suite -> last-run duration (ms), used to balance shards across runs.
const WEIGHTS_FILE := "user://gdunit_shard_weights.json"

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
	_shards = _resolve_shard_count()
	if _report_base.is_empty():
		_report_base = "res://reports"
	_headless = DisplayServer.get_name() == "headless"

	var suites := _discover_suites()
	if suites.is_empty():
		prints("No test suites found for", _include_paths)
		return 0
	var shard_count: int = mini(_shards, suites.size())
	var buckets := _partition(suites, shard_count, _load_weights())
	var report_dir := "%s/report_%d" % [_report_base, _next_report_index(_report_base)]
	prints("Running %d test suites across %d shards -> %s" % [suites.size(), shard_count, report_dir])

	var max_concurrent := _resolve_max_concurrent(shard_count)
	if max_concurrent < shard_count:
		prints("Limiting to %d concurrent shard processes" % max_concurrent)
	var shard_results := _run_shards(buckets, report_dir, max_concurrent)
	var manifest := _build_manifest(shard_results, buckets, report_dir)
	_write_manifest(report_dir, manifest)
	_merge_reports(report_dir, manifest)
	_update_weights(manifest)
	var codes: Array[int] = []
	for entry: Dictionary in manifest:
		codes.append(entry["exit_code"])
	return _aggregate_exit_code(codes)


# Resolves the shard count: an explicit --shards wins, then the project setting, then the CPU count.
func _resolve_shard_count() -> int:
	if _shards >= 2:
		return _shards
	var configured := GdUnitSettings.get_parallel_shards()
	if configured >= 2:
		return configured
	return maxi(2, OS.get_processor_count())


# Resolves how many shard processes may run at once: the project setting, then the CPU count,
# never more than the shard count.
func _resolve_max_concurrent(shard_count: int) -> int:
	var configured := GdUnitSettings.get_max_parallel_processes()
	var cap := configured if configured >= 1 else OS.get_processor_count()
	return clampi(cap, 1, shard_count)


# Runs the shards in a rolling pool so no more than [param max_concurrent] child processes run at once.
func _run_shards(buckets: Array, report_dir: String, max_concurrent: int) -> Array:
	var godot := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var results: Array = []
	results.resize(buckets.size())
	var pending: Array[int] = []
	for shard_index in buckets.size():
		pending.append(shard_index)
	var running: Dictionary = {}

	while not pending.is_empty() or not running.is_empty():
		while running.size() < max_concurrent and not pending.is_empty():
			var shard_index: int = pending.pop_front()
			var args := _child_args(project_root, buckets[shard_index], "%s/shard_%d" % [report_dir, shard_index])
			var thread := Thread.new()
			@warning_ignore("return_value_discarded")
			thread.start(func() -> Dictionary:
				var started := Time.get_unix_time_from_system()
				var output := []
				var code := OS.execute(godot, args, output, true)
				return {"code": code, "started": started, "ended": Time.get_unix_time_from_system()})
			running[shard_index] = thread

		for shard_index: int in running.keys():
			if not (running[shard_index] as Thread).is_alive():
				var result: Dictionary = (running[shard_index] as Thread).wait_to_finish()
				prints("Shard %d finished with exit code %d in %.2fs" % [shard_index, result["code"], result["ended"] - result["started"]])
				results[shard_index] = result
				@warning_ignore("return_value_discarded")
				running.erase(shard_index)

		if not running.is_empty():
			OS.delay_msec(50)
	return results


# Builds the per-shard run manifest: which suites ran where, wall-clock timing and the exit code.
func _build_manifest(shard_results: Array, buckets: Array, report_dir: String) -> Array:
	var manifest: Array = []
	for shard_index in shard_results.size():
		var result: Dictionary = shard_results[shard_index]
		manifest.append({
			"shard": shard_index,
			"suites": buckets[shard_index],
			"started": result["started"],
			"ended": result["ended"],
			"duration": result["ended"] - result["started"],
			"exit_code": result["code"],
			"result_file": _find_result_file("%s/shard_%d" % [report_dir, shard_index]),
		})
	return manifest


func _write_manifest(report_dir: String, manifest: Array) -> void:
	@warning_ignore("return_value_discarded")
	DirAccess.make_dir_recursive_absolute(report_dir)
	var manifest_file := "%s/shards.json" % report_dir
	var file := FileAccess.open(manifest_file, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(manifest, "\t"))
		prints("Shard manifest:", manifest_file)


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


func _merge_reports(report_dir: String, manifest: Array) -> void:
	var shard_result_files: Array[String] = []
	for entry: Dictionary in manifest:
		if not entry["result_file"].is_empty():
			shard_result_files.append(entry["result_file"])
	var merged := JUnitXmlReportMerger.merge(shard_result_files, report_dir)
	if merged.is_empty():
		push_warning("GdUnitShardCoordinator: no shard reports found to merge")
		return
	prints("Merged JUnit report:", merged)
	var merged_html := GdUnitHtmlReportMerger.merge(report_dir, manifest)
	if not merged_html.is_empty():
		prints("Merged HTML report:", merged_html)


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


# Balances suites across shards by expected duration using a greedy longest-processing-time fit:
# heaviest suites first, each assigned to the currently least-loaded shard. Unknown suites use the
# average known weight, so with no history (empty weights) this degrades to a balanced-by-count split.
func _partition(suites: Array[String], shard_count: int, weights: Dictionary) -> Array:
	var default_weight := _average_weight(weights)
	var order := suites.duplicate()
	order.sort_custom(func(left: String, right: String) -> bool:
		var left_weight := float(weights.get(left, default_weight))
		var right_weight := float(weights.get(right, default_weight))
		if left_weight != right_weight:
			return left_weight > right_weight
		return left < right)

	var buckets: Array = []
	var loads: Array[float] = []
	for _index in shard_count:
		buckets.append([] as Array[String])
		loads.append(0.0)
	for suite: String in order:
		var target := _least_loaded(loads)
		var bucket: Array[String] = buckets[target]
		bucket.append(suite)
		loads[target] += float(weights.get(suite, default_weight))
	return buckets


func _average_weight(weights: Dictionary) -> float:
	if weights.is_empty():
		return 1.0
	var sum := 0.0
	for weight: float in weights.values():
		sum += weight
	return sum / weights.size()


func _least_loaded(loads: Array) -> int:
	var index := 0
	for candidate in loads.size():
		if loads[candidate] < loads[index]:
			index = candidate
	return index


func _load_weights() -> Dictionary:
	if not FileAccess.file_exists(WEIGHTS_FILE):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(WEIGHTS_FILE))
	return parsed if parsed is Dictionary else {}


# Records each suite's latest duration (ms) from the shard reports so the next run can balance better.
func _update_weights(manifest: Array) -> void:
	var weights := _load_weights()
	for entry: Dictionary in manifest:
		var result_file: String = entry["result_file"]
		if result_file.is_empty():
			continue
		var durations := _parse_suite_durations(result_file)
		for suite_path: String in durations:
			weights[suite_path] = durations[suite_path]
	var file := FileAccess.open(WEIGHTS_FILE, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(weights))


func _parse_suite_durations(result_file: String) -> Dictionary:
	var durations: Dictionary = {}
	var content := FileAccess.get_file_as_string(result_file)
	var from := 0
	while true:
		var start := content.find("<testsuite ", from)
		if start == -1:
			break
		var end := content.find(">", start)
		if end == -1:
			break
		var tag := content.substr(start, end - start + 1)
		from = end + 1
		var suite_path := "res://%s/%s.gd" % [_attr(tag, "package"), _attr(tag, "name")]
		if FileAccess.file_exists(suite_path):
			durations[suite_path] = float(_attr(tag, "time")) * 1000.0
	return durations


func _attr(tag: String, name: String) -> String:
	var key := '%s="' % name
	var start := tag.find(key)
	if start == -1:
		return ""
	start += key.length()
	var end := tag.find('"', start)
	return "" if end == -1 else tag.substr(start, end - start)


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
