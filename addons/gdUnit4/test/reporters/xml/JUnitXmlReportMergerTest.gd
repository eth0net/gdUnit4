class_name JUnitXmlReportMergerTest
extends GdUnitTestSuite


const __source = "res://addons/gdUnit4/src/reporters/xml/JUnitXmlReportMerger.gd"

const SHARD_A := """<?xml version="1.0" encoding="UTF-8" ?>
<testsuites id="d" name="report_1" tests="5" failures="1" skipped="0" flaky="0" time="1.500">
	<testsuite id="0" name="SuiteA" tests="3" failures="1" errors="0" skipped="0" flaky="0" time="1.000"><testcase name="t1"/></testsuite>
	<testsuite id="1" name="SuiteB" tests="2" failures="0" errors="0" skipped="0" flaky="0" time="0.500"><testcase name="t2"/></testsuite>
</testsuites>"""

const SHARD_B := """<?xml version="1.0" encoding="UTF-8" ?>
<testsuites id="d" name="report_1" tests="3" failures="0" skipped="1" flaky="2" time="0.800">
	<testsuite id="0" name="SuiteC" tests="3" failures="0" errors="0" skipped="1" flaky="2" time="0.800"><testcase name="t3"/></testsuite>
</testsuites>"""

var _dir: String


func before_test() -> void:
	_dir = "user://junit_merge_test_%d" % randi()
	@warning_ignore("return_value_discarded")
	DirAccess.make_dir_recursive_absolute(_dir)


func after_test() -> void:
	@warning_ignore("return_value_discarded")
	DirAccess.remove_absolute(_dir)


func _write(file_path: String, content: String) -> void:
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	file.store_string(content)


func test_merge_combines_suites_and_sums_totals() -> void:
	_write("%s/a.xml" % _dir, SHARD_A)
	_write("%s/b.xml" % _dir, SHARD_B)

	var output := JUnitXmlReportMerger.merge(["%s/a.xml" % _dir, "%s/b.xml" % _dir], "%s/merged" % _dir)
	assert_str(output).is_equal("%s/merged/results.xml" % _dir)

	var merged := FileAccess.get_file_as_string(output)
	# root totals are summed across shards
	assert_str(merged).contains('tests="8"')
	assert_str(merged).contains('failures="1"')
	assert_str(merged).contains('skipped="1"')
	assert_str(merged).contains('flaky="2"')
	# all three suites and their test cases are carried over
	assert_int(merged.count("<testsuite ")).is_equal(3)
	assert_int(merged.count("<testcase ")).is_equal(3)


func test_merge_skips_missing_files() -> void:
	_write("%s/a.xml" % _dir, SHARD_A)

	var output := JUnitXmlReportMerger.merge(["%s/a.xml" % _dir, "%s/missing.xml" % _dir], "%s/merged" % _dir)
	var merged := FileAccess.get_file_as_string(output)
	assert_str(merged).contains('tests="5"')
	assert_int(merged.count("<testsuite ")).is_equal(2)


func test_merge_returns_empty_when_no_reports() -> void:
	assert_str(JUnitXmlReportMerger.merge(["%s/none.xml" % _dir], "%s/merged" % _dir)).is_empty()
