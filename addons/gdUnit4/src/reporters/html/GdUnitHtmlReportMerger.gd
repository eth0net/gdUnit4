# Builds a top-level HTML summary for a parallel (sharded) run that links to each shard's
# own HTML report and shows the combined totals. The shard reports are left untouched.
class_name GdUnitHtmlReportMerger

const _STYLE := "body{font-family:sans-serif;margin:2rem;background:#1e1e1e;color:#ddd}"\
	+ "table{border-collapse:collapse;margin-top:1rem}th,td{border:1px solid #444;padding:.4rem .8rem;text-align:right}"\
	+ "th:first-child,td:first-child{text-align:left}a{color:#4ea1ff}tfoot td{font-weight:bold}.fail{color:#ff6b6b}"


# Writes `{output_path}/index.html` from the shard run [param manifest] (see GdUnitShardCoordinator),
# linking each shard's own report and showing per-shard suites, results and wall-clock duration.
# Returns the written path, or "" when nothing was written.
static func merge(output_path: String, manifest: Array) -> String:
	var rows := ""
	var total_tests := 0
	var total_failures := 0
	var total_skipped := 0
	var found := false
	for entry: Dictionary in manifest:
		var result_file: String = entry["result_file"]
		if result_file.is_empty() or not FileAccess.file_exists(result_file):
			continue
		found = true
		var root := _root_tag(FileAccess.get_file_as_string(result_file))
		var tests := _attr_int(root, "tests")
		var failures := _attr_int(root, "failures")
		var skipped := _attr_int(root, "skipped")
		total_tests += tests
		total_failures += failures
		total_skipped += skipped
		var suites: Array = entry["suites"]
		var link := "%s/index.html" % result_file.get_base_dir().trim_prefix(output_path + "/")
		var fail_class := ' class="fail"' if failures > 0 else ""
		rows += '<tr><td><a href="%s">Shard %d</a></td><td>%d</td><td>%d</td><td%s>%d</td><td>%d</td><td>%.2fs</td></tr>' % [
			link, entry["shard"], suites.size(), tests, fail_class, failures, skipped, entry["duration"]
		]
	if not found:
		return ""

	var html := '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Parallel test report</title>'\
		+ '<style>%s</style></head><body>' % _STYLE\
		+ '<h1>Parallel test report</h1>'\
		+ '<p><a href="shards.json">shard manifest (shards.json)</a></p>'\
		+ '<table><thead><tr><th>Shard</th><th>Suites</th><th>Tests</th><th>Failures</th><th>Skipped</th><th>Duration</th></tr></thead>'\
		+ '<tbody>%s</tbody>' % rows\
		+ '<tfoot><tr><td>Total</td><td></td><td>%d</td><td>%d</td><td>%d</td><td></td></tr></tfoot></table>' % [
			total_tests, total_failures, total_skipped
		]\
		+ '</body></html>'

	var index_file := "%s/index.html" % output_path
	DirAccess.make_dir_recursive_absolute(output_path)
	var file := FileAccess.open(index_file, FileAccess.WRITE)
	if file == null:
		push_warning("Can't save merged HTML report to '%s'" % index_file)
		return ""
	file.store_string(html)
	return index_file


static func _root_tag(content: String) -> String:
	var start := content.find("<testsuites")
	if start == -1:
		return ""
	var end := content.find(">", start)
	return "" if end == -1 else content.substr(start, end - start + 1)


static func _attr_int(tag: String, name: String) -> int:
	var key := '%s="' % name
	var start := tag.find(key)
	if start == -1:
		return 0
	start += key.length()
	var end := tag.find('"', start)
	return 0 if end == -1 else int(tag.substr(start, end - start))
