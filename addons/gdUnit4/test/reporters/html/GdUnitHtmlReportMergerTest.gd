class_name GdUnitHtmlReportMergerTest
extends GdUnitTestSuite


const __source = "res://addons/gdUnit4/src/reporters/html/GdUnitHtmlReportMerger.gd"

const SHARD := '<?xml version="1.0" encoding="UTF-8" ?>\n<testsuites id="d" name="report_1" tests="%d" failures="%d" skipped="%d" flaky="0" time="0.000"></testsuites>'

var _dir: String


func before_test() -> void:
	_dir = "user://html_merge_test_%d" % randi()


func after_test() -> void:
	GdUnitFileAccess.delete_directory(_dir)


func _write(file_path: String, content: String) -> void:
	@warning_ignore("return_value_discarded")
	DirAccess.make_dir_recursive_absolute(file_path.get_base_dir())
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	file.store_string(content)


func test_merge_builds_summary_with_links_and_totals() -> void:
	var shard_a := "%s/shard_0/report_1/results.xml" % _dir
	var shard_b := "%s/shard_1/report_1/results.xml" % _dir
	_write(shard_a, SHARD % [3, 1, 0])
	_write(shard_b, SHARD % [2, 0, 1])
	var manifest := [
		{"shard": 0, "suites": ["res://a.gd", "res://b.gd"], "duration": 1.5, "result_file": shard_a},
		{"shard": 1, "suites": ["res://c.gd"], "duration": 0.8, "result_file": shard_b},
	]

	var output := GdUnitHtmlReportMerger.merge(_dir, manifest)
	assert_str(output).is_equal("%s/index.html" % _dir)

	var html := FileAccess.get_file_as_string(output)
	# links point to each shard's own report, relative to the summary
	assert_str(html).contains('href="shard_0/report_1/index.html"')
	assert_str(html).contains('href="shard_1/report_1/index.html"')
	assert_str(html).contains('href="shards.json"')
	# combined totals: 5 tests, 1 failure, 1 skipped
	assert_str(html).contains("Total")
	assert_int(html.count("<td>5</td>")).is_equal(1)


func test_merge_returns_empty_when_no_reports() -> void:
	var manifest := [{"shard": 0, "suites": [], "duration": 0.0, "result_file": "%s/none.xml" % _dir}]
	assert_str(GdUnitHtmlReportMerger.merge(_dir, manifest)).is_empty()
