class_name GdUnitShardCoordinatorTest
extends GdUnitTestSuite


const __source = "res://addons/gdUnit4/src/core/runners/GdUnitShardCoordinator.gd"


# The coordinator is never added to the scene tree here, so _ready() (which would run and quit) does not fire.
func _coordinator() -> GdUnitShardCoordinator:
	return auto_free(GdUnitShardCoordinator.new())


func test_partition_without_weights_balances_by_count() -> void:
	var suites: Array[String] = ["a", "b", "c", "d", "e"]
	var buckets := _coordinator()._partition(suites, 3, {}, {})

	assert_int(buckets.size()).is_equal(3)
	assert_array(buckets[0]).contains_exactly(["a", "d"])
	assert_array(buckets[1]).contains_exactly(["b", "e"])
	assert_array(buckets[2]).contains_exactly(["c"])


func test_partition_balances_by_weight() -> void:
	var suites: Array[String] = ["a", "b", "c", "d"]
	var weights := {"a": 10.0, "b": 1.0, "c": 1.0, "d": 1.0}
	var buckets := _coordinator()._partition(suites, 2, weights, {})

	# the one heavy suite runs alone, the three light suites share the other shard
	assert_array(buckets[0]).contains_exactly(["a"])
	assert_array(buckets[1]).contains_exactly(["b", "c", "d"])


func test_partition_keeps_shard_group_on_one_shard() -> void:
	var suites: Array[String] = ["a", "b", "c", "d"]
	# a and c share a resource, so they must never run concurrently
	var groups := {"a": "net", "c": "net"}
	var buckets := _coordinator()._partition(suites, 3, {}, groups)

	var shard_of := {}
	for shard_index in buckets.size():
		for suite: String in buckets[shard_index]:
			shard_of[suite] = shard_index
	assert_int(shard_of["a"]).is_equal(shard_of["c"])


#region shard groups
func test_resolve_shard_groups_single_tag_pins_sharers() -> void:
	var tags := {"a": ["net"], "b": ["net"], "c": ["db"]}
	var groups := _coordinator()._resolve_shard_groups(tags)

	# a and b share "net" so they collapse into one group; c is a singleton and stays free
	assert_str(groups["a"]).is_equal(groups["b"])
	assert_bool(groups.has("c")).is_false()


func test_resolve_shard_groups_merges_transitively_across_tags() -> void:
	# a bridges "db" and "net", so a, b and c all end up in one exclusion component
	var tags := {"a": ["db", "net"], "b": ["net"], "c": ["db"], "d": ["ui"]}
	var groups := _coordinator()._resolve_shard_groups(tags)

	assert_str(groups["a"]).is_equal(groups["b"])
	assert_str(groups["a"]).is_equal(groups["c"])
	assert_str(groups["a"]).is_equal("db+net")
	assert_bool(groups.has("d")).is_false()


func test_resolve_shard_groups_keeps_disjoint_components_separate() -> void:
	var tags := {"a": ["net"], "b": ["net"], "c": ["db"], "d": ["db"]}
	var groups := _coordinator()._resolve_shard_groups(tags)

	assert_str(groups["a"]).is_equal(groups["b"])
	assert_str(groups["c"]).is_equal(groups["d"])
	assert_str(groups["a"]).is_not_equal(groups["c"])


func test_resolve_shard_groups_no_tags_is_empty() -> void:
	assert_dict(_coordinator()._resolve_shard_groups({})).is_empty()
#endregion


func test_aggregate_exit_code_all_success() -> void:
	assert_int(_coordinator()._aggregate_exit_code([0, 0, 0])).is_equal(0)


func test_aggregate_exit_code_orphan_warning() -> void:
	assert_int(_coordinator()._aggregate_exit_code([0, 101, 0])).is_equal(101)


func test_aggregate_exit_code_failure_wins_over_warning() -> void:
	assert_int(_coordinator()._aggregate_exit_code([101, 100, 0])).is_equal(100)


func test_aggregate_exit_code_unknown_code_is_error() -> void:
	# a non-standard exit code (spawn failure / crash) is treated as an error
	assert_int(_coordinator()._aggregate_exit_code([0, 1, 0])).is_equal(100)


func test_resolve_max_concurrent_clamps_to_setting_and_shard_count() -> void:
	ProjectSettings.set_setting(GdUnitSettings.TEST_MAX_PARALLEL_PROCESSES, 2)
	var coordinator := _coordinator()

	assert_int(coordinator._resolve_max_concurrent(10)).is_equal(2)
	assert_int(coordinator._resolve_max_concurrent(1)).is_equal(1)
