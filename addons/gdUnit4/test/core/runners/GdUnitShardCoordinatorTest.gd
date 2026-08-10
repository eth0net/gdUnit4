class_name GdUnitShardCoordinatorTest
extends GdUnitTestSuite


const __source = "res://addons/gdUnit4/src/core/runners/GdUnitShardCoordinator.gd"


# The coordinator is never added to the scene tree here, so _ready() (which would run and quit) does not fire.
func _coordinator() -> GdUnitShardCoordinator:
	return auto_free(GdUnitShardCoordinator.new())


func test_partition_distributes_suites_round_robin() -> void:
	var suites: Array[String] = ["a", "b", "c", "d", "e"]
	var buckets := _coordinator()._partition(suites, 3)

	assert_int(buckets.size()).is_equal(3)
	assert_array(buckets[0]).contains_exactly(["a", "d"])
	assert_array(buckets[1]).contains_exactly(["b", "e"])
	assert_array(buckets[2]).contains_exactly(["c"])


func test_aggregate_exit_code_all_success() -> void:
	assert_int(_coordinator()._aggregate_exit_code([0, 0, 0])).is_equal(0)


func test_aggregate_exit_code_orphan_warning() -> void:
	assert_int(_coordinator()._aggregate_exit_code([0, 101, 0])).is_equal(101)


func test_aggregate_exit_code_failure_wins_over_warning() -> void:
	assert_int(_coordinator()._aggregate_exit_code([101, 100, 0])).is_equal(100)


func test_aggregate_exit_code_unknown_code_is_error() -> void:
	# a non-standard exit code (spawn failure / crash) is treated as an error
	assert_int(_coordinator()._aggregate_exit_code([0, 1, 0])).is_equal(100)
