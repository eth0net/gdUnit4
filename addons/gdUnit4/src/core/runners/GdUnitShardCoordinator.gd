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
# suite path -> resolved shard group key; suites sharing any tag are pinned to the same shard.
var _suite_groups: Dictionary = {}


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
	var buckets := _partition(suites, shard_count, _load_weights(), _suite_groups)
	# Grouping can collapse suites into fewer units than shards; drop the empty ones.
	buckets = buckets.filter(func(bucket: Array) -> bool: return not bucket.is_empty())
	shard_count = buckets.size()
	var report_dir := "%s/report_%d" % [_report_base, _next_report_index(_report_base)]
	prints("Running %d test suites across %d shards -> %s" % [suites.size(), shard_count, report_dir])
	if not _suite_groups.is_empty():
		prints("Pinned %d suites to shard groups: %s" % [_suite_groups.size(), " ".join(_group_names())])

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
	var suite_tags: Dictionary = {}
	for path in _include_paths:
		for script in scanner.scan(path):
			var suite_path := script.resource_path
			if suite_path.is_empty() or suites.has(suite_path):
				continue
			suites.append(suite_path)
			var tags := _read_shard_tags(script)
			if not tags.is_empty():
				suite_tags[suite_path] = tags
	_suite_groups = _resolve_shard_groups(suite_tags)
	suites.sort()
	return suites


# Reads a suite's `__shard_group` marker as a set of resource tags. Accepts a single String
# (one tag, the original form) or an Array of Strings (several). Suites sharing any tag are
# pinned to the same shard so they never run concurrently.
func _read_shard_tags(script: Script) -> Array[String]:
	var marker: Variant = script.get_script_constant_map().get("__shard_group", null)
	var tags: Array[String] = []
	if marker is String:
		if not (marker as String).is_empty():
			tags.append(marker)
	elif marker is Array:
		for tag: Variant in marker:
			if tag is String and not (tag as String).is_empty() and not tags.has(tag):
				tags.append(tag)
	return tags


# Merges suites that share any tag into exclusion components via union-find, then maps every
# suite in a multi-suite component to a stable component key (the sorted tag union, e.g. "db+net").
# Singleton components need no pinning and are omitted. Two distinct components can never share a
# tag (sharing one would union them), so their tag-union keys are always distinct.
func _resolve_shard_groups(suite_tags: Dictionary) -> Dictionary:
	var groups: Dictionary = {}
	if suite_tags.is_empty():
		return groups
	var parent: Dictionary = {}
	for suite: String in suite_tags:
		parent[suite] = suite
	# Union suites via the first suite seen holding each tag (O(suites * tags per suite)).
	var tag_owner: Dictionary = {}
	for suite: String in suite_tags:
		for tag: String in suite_tags[suite]:
			if tag_owner.has(tag):
				_union(parent, tag_owner[tag], suite)
			else:
				tag_owner[tag] = suite
	# Gather each connected component's members by root.
	var members: Dictionary = {}
	for suite: String in suite_tags:
		var root := _find(parent, suite)
		if not members.has(root):
			members[root] = [] as Array[String]
		members[root].append(suite)
	for root: String in members:
		var component: Array = members[root]
		if component.size() <= 1:
			continue
		var tags: Array[String] = []
		for suite: String in component:
			for tag: String in suite_tags[suite]:
				if not tags.has(tag):
					tags.append(tag)
		tags.sort()
		var key := "+".join(tags)
		for suite: String in component:
			groups[suite] = key
	return groups


func _find(parent: Dictionary, node: String) -> String:
	var root: String = node
	while parent[root] != root:
		root = parent[root]
	# Path compression: point every node on the path straight at the root.
	while parent[node] != root:
		var next: String = parent[node]
		parent[node] = root
		node = next
	return root


func _union(parent: Dictionary, left: String, right: String) -> void:
	var left_root := _find(parent, left)
	var right_root := _find(parent, right)
	if left_root != right_root:
		parent[right_root] = left_root


func _group_names() -> Array:
	var names: Array = []
	for group: String in _suite_groups.values():
		if not names.has(group):
			names.append(group)
	return names


# Balances suites across shards by expected duration using a greedy longest-processing-time fit:
# heaviest units first, each assigned to the currently least-loaded shard. Suites that share a
# [param groups] key collapse into one unit so they always land on the same shard (never run
# concurrently). Unknown weights use the average, so with no history this degrades to balanced-by-count.
func _partition(suites: Array[String], shard_count: int, weights: Dictionary, groups: Dictionary) -> Array:
	var default_weight := _average_weight(weights)
	# Collapse suites into units: one unit per shard group, plus one unit per ungrouped suite.
	var units: Dictionary = {}
	for suite: String in suites:
		var group := String(groups.get(suite, ""))
		var unit_key := "group:%s" % group if not group.is_empty() else "suite:%s" % suite
		if not units.has(unit_key):
			units[unit_key] = {"suites": [] as Array[String], "weight": 0.0}
		var unit: Dictionary = units[unit_key]
		unit["suites"].append(suite)
		unit["weight"] += float(weights.get(suite, default_weight))

	var order := units.keys()
	order.sort_custom(func(left: String, right: String) -> bool:
		var left_weight: float = units[left]["weight"]
		var right_weight: float = units[right]["weight"]
		if left_weight != right_weight:
			return left_weight > right_weight
		return left < right)

	var buckets: Array = []
	var loads: Array[float] = []
	for _index in shard_count:
		buckets.append([] as Array[String])
		loads.append(0.0)
	for unit_key: String in order:
		var target := _least_loaded(loads)
		var bucket: Array[String] = buckets[target]
		@warning_ignore("return_value_discarded")
		bucket.append_array(units[unit_key]["suites"])
		loads[target] += float(units[unit_key]["weight"])
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
