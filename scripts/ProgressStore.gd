extends Node

signal changed

const SAVE_PATH := "user://algo_buddy_profile.json"
const BACKUP_PATH := "user://algo_buddy_profile.bak"
const TEMP_PATH := "user://algo_buddy_profile.tmp"

# Simplified spaced repetition: mastery 0..3, wrong answers reset to 0.
const SRS_INTERVALS := [1, 1, 3, 7]
const QUIZ_PASS_SCORE := 60

var data: Dictionary = default_data()


func _ready() -> void:
	load_game()


func default_data() -> Dictionary:
	return {
		"version": 1,
		"currentSection": "",
		"reading": {},        # section_id -> {"page": int, "pages": int}
		"completed": {},      # section_id -> true (reading finished)
		"scores": {},         # scope_id -> best quiz %
		"srs": {},            # quiz_id -> {"m": 0..3, "due": "YYYY-MM-DD", "section": id}
		"xp": 0,
		"streak": 0,
		"lastStudyDay": "",
		"history": [],
	}


func load_game() -> void:
	var file := File.new()
	for path in [SAVE_PATH, BACKUP_PATH]:
		if file.file_exists(path) and file.open(path, File.READ) == OK:
			var parsed = JSON.parse(file.get_as_text()).result
			file.close()
			if parsed is Dictionary and int(parsed.get("version", 0)) == 1:
				data = _merge_defaults(parsed)
				return
	emit_signal("changed")


func _merge_defaults(saved: Dictionary) -> Dictionary:
	var merged := default_data()
	for key in saved:
		merged[key] = saved[key]
	return merged


func save_game() -> void:
	var file := File.new()
	if file.open(TEMP_PATH, File.WRITE) != OK:
		push_error("Could not write learning profile")
		return
	file.store_string(JSON.print(data))
	file.close()
	var directory := Directory.new()
	if file.file_exists(SAVE_PATH):
		directory.rename(SAVE_PATH, BACKUP_PATH)
	if directory.rename(TEMP_PATH, SAVE_PATH) != OK:
		if file.file_exists(BACKUP_PATH):
			directory.rename(BACKUP_PATH, SAVE_PATH)
		push_error("Could not replace learning profile")
		return
	emit_signal("changed")


# ---------------------------------------------------------------- reading --

func set_current_section(section_id: String) -> void:
	data.currentSection = section_id
	save_game()


func current_section_id() -> String:
	return String(data.get("currentSection", ""))


func save_reading_position(section_id: String, page: int, pages: int) -> void:
	var reading: Dictionary = data.get("reading", {})
	reading[section_id] = {"page": page, "pages": pages}
	data.reading = reading
	_touch_study_day()
	save_game()


func reading_page(section_id: String) -> int:
	var entry: Dictionary = data.get("reading", {}).get(section_id, {})
	return int(entry.get("page", 0))


func is_completed(section_id: String) -> bool:
	return bool(data.get("completed", {}).get(section_id, false))


func completed_count() -> int:
	return data.get("completed", {}).size()


func mark_section_done(section_id: String) -> bool:
	if is_completed(section_id):
		return false
	data.completed[section_id] = true
	data.xp = int(data.get("xp", 0)) + 5
	_touch_study_day()
	save_game()
	return true


# ------------------------------------------------------------------- quiz --

func best_score(scope_id: String) -> int:
	return int(data.get("scores", {}).get(scope_id, -1))


func record_quiz(scope_id: String, score: int) -> bool:
	var first := best_score(scope_id) < 0
	if score > best_score(scope_id):
		data.scores[scope_id] = score
	if score >= QUIZ_PASS_SCORE and first:
		data.xp = int(data.get("xp", 0)) + 10
	_touch_study_day()
	var history: Array = data.get("history", [])
	history.append({"scope": scope_id, "score": score, "day": _today()})
	if history.size() > 60:
		history = history.slice(history.size() - 60, history.size())
	data.history = history
	save_game()
	return first


# -------------------------------------------------------------------- srs --

func record_srs(quiz_id: String, section_id: String, correct: bool) -> void:
	var srs: Dictionary = data.get("srs", {})
	var entry: Dictionary = srs.get(quiz_id, {"m": 0, "due": _today(), "section": section_id})
	var mastery := int(entry.get("m", 0))
	if correct:
		mastery = min(3, mastery + 1)
	else:
		mastery = 0
	entry["m"] = mastery
	entry["section"] = section_id
	entry["due"] = _due_date(SRS_INTERVALS[mastery])
	srs[quiz_id] = entry
	data.srs = srs
	save_game()


func srs_entry(quiz_id: String) -> Dictionary:
	return data.get("srs", {}).get(quiz_id, {})


func due_quiz_ids() -> Array:
	var result: Array = []
	var today := _today()
	for quiz_id in data.get("srs", {}).keys():
		var entry: Dictionary = data.srs[quiz_id]
		if String(entry.get("due", "")) <= today:
			result.append(String(quiz_id))
	return result


func srs_count() -> int:
	return data.get("srs", {}).size()


# ----------------------------------------------------------------- common --

func _touch_study_day() -> void:
	var today := _today()
	if String(data.get("lastStudyDay", "")) == today:
		return
	data.lastStudyDay = today
	data.streak = int(data.get("streak", 0)) + 1


func _today() -> String:
	var time := OS.get_datetime()
	return "%04d-%02d-%02d" % [time.year, time.month, time.day]


func _due_date(days_ahead: int) -> String:
	var unix := OS.get_unix_time() + days_ahead * 86400
	var time := OS.get_datetime_from_unix_time(unix)
	return "%04d-%02d-%02d" % [time.year, time.month, time.day]


func reset_game() -> void:
	data = default_data()
	save_game()
