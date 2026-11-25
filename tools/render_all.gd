extends SceneTree

# Drive the app through its screens and capture screenshots for visual review.
# Run with a display (not --headless): godot --path . --script res://tools/render_all.gd

const OUT_DIR := "res://.build/screenshots"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var dir := Directory.new()
	if not dir.dir_exists(OUT_DIR):
		dir.make_dir_recursive(OUT_DIR)
	var main = load("res://scenes/Main.tscn").instance()
	root.add_child(main)
	yield(self, "idle_frame")
	yield(self, "idle_frame")

	# home
	yield(_capture("home"), "completed")

	# chapters list
	main._show_chapters()
	yield(_capture("chapters"), "completed")

	# sections of chapter 11
	main.current_chapter_index = main.repo.get_chapter(0) != null and 11 or 0
	for index in range(main.repo.chapter_count()):
		if String(main.repo.get_chapter(index).get("id", "")) == "ch11":
			main.current_chapter_index = index
			break
	main._show_sections()
	yield(_capture("sections"), "completed")

	# reader: bubble sort page 1 (para + steps card)
	main._open_section("ch11_03")
	main.body_page = 0
	main._show_reader()
	yield(_capture("reader_bubble_p1"), "completed")

	# reader: a page with a full-width figure (last pages hold overview figure)
	main.body_page = clamp(main.body_pages.size() - 4, 0, main.body_pages.size() - 1)
	main._show_reader()
	yield(_capture("reader_bubble_late"), "completed")

	# reader: code-heavy page (insertion sort has code right after text)
	main._open_section("ch11_04")
	main.body_page = 1
	main._show_reader()
	yield(_capture("reader_code"), "completed")

	# reader: summary with Q&A overlay (ch11 summary)
	main._open_section("ch11_11")
	main.body_page = 0
	main._show_reader()
	main.qa_overlay = main._first_qa_on_page(main.body_pages[main.body_page])
	if main.qa_overlay >= 0:
		main._show_reader()
	yield(_capture("reader_qa"), "completed")

	# reader: exercises with reveal qa (ch11 exercises page)
	main._open_section("ch11_12")
	main.body_page = 0
	main._show_reader()
	main.qa_overlay = main._first_qa_on_page(main.body_pages[main.body_page])
	if main.qa_overlay >= 0:
		main._show_reader()
	yield(_capture("reader_exercise"), "completed")

	# reader: complexity chapter (dense math + table)
	main._open_section("ch02_03")
	main.body_page = 2
	main._show_reader()
	yield(_capture("reader_complexity"), "completed")

	# reader: transposed complexity table (hash map)
	main._open_section("ch06_01")
	main.body_page = main.body_pages.size() - 3
	main._show_reader()
	yield(_capture("reader_table"), "completed")

	# steps viewer: bubble sort step card -> open steps, jump to step 4
	main._open_section("ch11_03")
	var steps_block := {}
	for block in main.repo.section_by_id("ch11_03").get("blocks", []):
		if String(block.get("type", "")) == "figure_steps":
			steps_block = block
			break
	main._open_steps({"id": String(steps_block.get("id", ""))})
	yield(_capture("steps_1"), "completed")
	main.steps_idx = 3
	main._show_steps()
	yield(_capture("steps_4"), "completed")
	main.steps_idx = main.steps_block.get("steps", []).size() - 1
	main._show_steps()
	yield(_capture("steps_last"), "completed")

	# quiz: mcq (chapter 4 carries the generated complexity MCQs)
	var mcq := {}
	for item in main.repo.quiz_items:
		if String(item.get("type", "")) == "mcq" and String(item.get("section", "")).begins_with("ch04"):
			mcq = item
			break
	main._start_quiz([mcq], "ch04_01")
	yield(_capture("quiz_mcq"), "completed")
	main._answer_question(1)
	yield(_capture("quiz_feedback"), "completed")

	# quiz: reveal
	var reveal := {}
	for item in main.repo.quiz_items:
		if String(item.get("type", "")) == "reveal":
			reveal = item
			break
	main._start_quiz([reveal], "ch11")
	yield(_capture("quiz_reveal"), "completed")
	main.quiz_state = "reveal_answer"
	main._show_quiz()
	yield(_capture("quiz_reveal_answer"), "completed")

	# glossary
	main._show_glossary()
	yield(_capture("glossary"), "completed")
	main._show_glossary_detail(3)
	yield(_capture("glossary_detail"), "completed")

	# controls + about
	main._show_controls()
	yield(_capture("controls"), "completed")
	main._show_about()
	yield(_capture("about"), "completed")

	print("RENDER_DONE")
	quit(0)


func _capture(name: String) -> void:
	yield(self, "idle_frame")
	yield(self, "idle_frame")
	yield(self, "idle_frame")
	var image: Image = root.get_texture().get_data()
	image.flip_y()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := image.save_png(path)
	print("CAPTURED ", name, " err=", err)
