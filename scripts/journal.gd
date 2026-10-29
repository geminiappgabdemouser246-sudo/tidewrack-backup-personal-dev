extends Node
## Journal – discovered-logs state and save/load serialization.
##
## Autoloaded as `Journal`. Tracks unique discovered entry IDs in discovery
## order and persists them through `GameState` (`user://save.json`).

## Emitted only when a new entry is discovered during live play (not on load).
signal entry_added(id: String)
## Emitted whenever the entry list changes (discover, clear, or save restore).
signal journal_changed

var _entries: Array[String] = []


func _ready() -> void:
	var game_state := get_node_or_null("/root/GameState")
	if game_state != null and game_state.has_method("_sync_journal_node"):
		game_state.call("_sync_journal_node", self)


func discover(id: String) -> void:
	var clean_id := id.strip_edges()
	if clean_id.is_empty():
		push_warning("Journal: ignored empty entry ID in discover().")
		return
	if clean_id in _entries:
		return
	_entries.append(clean_id)
	entry_added.emit(clean_id)
	journal_changed.emit()


func entries() -> Array[String]:
	return _entries.duplicate()


func has(id: String) -> bool:
	var clean_id := id.strip_edges()
	if clean_id.is_empty():
		return false
	return clean_id in _entries


func clear() -> void:
	_entries.clear()
	journal_changed.emit()


func to_save_data() -> Array[String]:
	return _entries.duplicate()


## Replaces in-memory entries from parsed save data without firing `entry_added`.
func from_save_data(raw: Variant) -> void:
	var next_entries: Array[String] = []
	var source: Variant = raw
	if typeof(raw) == TYPE_DICTIONARY:
		source = (raw as Dictionary).get("entries", [])

	if typeof(source) == TYPE_ARRAY:
		var raw_list: Array = source
		for item: Variant in raw_list:
			if typeof(item) != TYPE_STRING:
				push_warning("Journal: ignoring non-string entry in save data.")
				continue
			var clean_id := (item as String).strip_edges()
			if clean_id.is_empty() or clean_id in next_entries:
				continue
			next_entries.append(clean_id)
	elif source != null:
		push_warning("Journal: malformed journal data in save; resetting to empty.")

	_entries = next_entries
	journal_changed.emit()
