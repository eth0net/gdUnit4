## A persistent, file-modification-time keyed cache of discovered test cases.[br]
## [br]
## Test discovery loads (compiles) every candidate script to determine whether it is a[br]
## test suite and to extract its test methods. For a large project this dominates the[br]
## discovery cost. This cache stores the discovered [GdUnitTestCase]s per source file,[br]
## keyed by the file's modification time, so unchanged files are served from the cache[br]
## without ever loading the script.[br]
## [br]
## A file that is not a test suite is cached as an empty entry so it is not re-loaded on[br]
## subsequent runs either. The cache is stored under [code]res://.godot/[/code] which is[br]
## per-project and excluded from version control.
class_name GdUnitDiscoverCache
extends RefCounted

const CACHE_FILE := "res://.godot/gdunit_discover_cache.json"

# source_file -> { "mtime": int, "tests": Array[Dictionary] }
var _entries: Dictionary = {}
var _dirty := false


## Loads the cache from disk. Silently starts empty when no cache exists yet.
func load_cache() -> void:
	if not FileAccess.file_exists(CACHE_FILE):
		return
	var file := FileAccess.open(CACHE_FILE, FileAccess.READ)
	if file == null:
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	if data is Dictionary:
		_entries = data


## Writes the cache back to disk when it has changed.
func save_cache() -> void:
	if not _dirty:
		return
	var file := FileAccess.open(CACHE_FILE, FileAccess.WRITE)
	if file == null:
		push_warning("GdUnitDiscoverCache: unable to write cache at %s" % CACHE_FILE)
		return
	file.store_string(JSON.stringify(_entries))
	_dirty = false


## Returns true when a valid, up-to-date entry exists for [param source_file].
func is_valid(source_file: String, mtime: int) -> bool:
	var entry: Variant = _entries.get(source_file)
	return entry is Dictionary and int(entry.get("mtime", -1)) == mtime


## Returns the cached test cases for [param source_file]. Only call after [method is_valid].
func get_tests(source_file: String) -> Array[GdUnitTestCase]:
	var tests: Array[GdUnitTestCase] = []
	var entry: Variant = _entries.get(source_file)
	if not entry is Dictionary:
		return tests
	for dict: Variant in (entry as Dictionary).get("tests", []):
		if dict is Dictionary:
			tests.append(GdUnitTestCase.from_dict(dict))
	return tests


## Stores the discovered [param tests] for [param source_file] under its [param mtime].
func put(source_file: String, mtime: int, tests: Array[GdUnitTestCase]) -> void:
	var serialized: Array[Dictionary] = []
	for test in tests:
		serialized.append(GdUnitTestCase.to_dict(test))
	_entries[source_file] = { "mtime": mtime, "tests": serialized }
	_dirty = true
