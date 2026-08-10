# Merges the JUnit `results.xml` files produced by parallel shard runs into a single report.
class_name JUnitXmlReportMerger

const HEADER := '<?xml version="1.0" encoding="UTF-8" ?>\n'


# Merges the given shard result files into one `results.xml` under [param output_path].
# Returns the written file path, or an empty string when no shard report was found.
static func merge(shard_result_files: Array, output_path: String) -> String:
	var total := {"tests": 0, "failures": 0, "skipped": 0, "flaky": 0, "time": 0.0}
	var suite_blocks := ""
	var found := false
	for file_path: String in shard_result_files:
		if not FileAccess.file_exists(file_path):
			continue
		var content := FileAccess.get_file_as_string(file_path)
		var root_tag := _root_tag(content)
		if root_tag.is_empty():
			continue
		found = true
		total.tests += _attr_int(root_tag, "tests")
		total.failures += _attr_int(root_tag, "failures")
		total.skipped += _attr_int(root_tag, "skipped")
		total.flaky += _attr_int(root_tag, "flaky")
		total.time += _attr_float(root_tag, "time")
		suite_blocks += _inner_suites(content)
	if not found:
		return ""

	var root := '<testsuites id="%s" name="%s" tests="%d" failures="%d" skipped="%d" flaky="%d" time="%4.03f">' % [
		Time.get_date_string_from_system(),
		output_path.get_file(),
		total.tests, total.failures, total.skipped, total.flaky, total.time
	]
	var result_file := "%s/results.xml" % output_path
	DirAccess.make_dir_recursive_absolute(output_path)
	var file := FileAccess.open(result_file, FileAccess.WRITE)
	if file == null:
		push_warning("Can't save merged result to '%s'\n Error: %s" % [result_file, error_string(FileAccess.get_open_error())])
		return ""
	file.store_string("%s%s%s</testsuites>" % [HEADER, root, suite_blocks])
	return result_file


# Returns the opening `<testsuites ...>` tag of the document.
static func _root_tag(content: String) -> String:
	var start := content.find("<testsuites")
	if start == -1:
		return ""
	var end := content.find(">", start)
	if end == -1:
		return ""
	return content.substr(start, end - start + 1)


# Returns everything between the root `<testsuites ...>` and `</testsuites>` (the `<testsuite>` blocks).
static func _inner_suites(content: String) -> String:
	var start := content.find(">", content.find("<testsuites"))
	var end := content.rfind("</testsuites>")
	if start == -1 or end == -1 or end <= start:
		return ""
	return content.substr(start + 1, end - start - 1)


static func _attr_int(tag: String, name: String) -> int:
	return int(_attr(tag, name))


static func _attr_float(tag: String, name: String) -> float:
	return float(_attr(tag, name))


static func _attr(tag: String, name: String) -> String:
	var key := '%s="' % name
	var start := tag.find(key)
	if start == -1:
		return ""
	start += key.length()
	var end := tag.find('"', start)
	if end == -1:
		return ""
	return tag.substr(start, end - start)
