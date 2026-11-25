extends SceneTree

# Headless smoke test for algo-buddy.
# Run: godot --headless --path . --script res://tools/smoke.gd

const VALID_BLOCK_TYPES := ["h2", "h3", "para", "tip", "code", "figure", "figure_steps", "qa", "table", "list"]

var failures := 0
var checks := 0


func _init() -> void:
	call_deferred("_run")


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		print("FAIL: ", label)


func _run() -> void:
	var repo = load("res://scripts/ContentRepository.gd").new()
	root.add_child(repo)
	yield(self, "idle_frame")

	check(repo.chapter_count() == 18, "18 chapters, got %d" % repo.chapter_count())
	check(repo.section_count() == 117, "117 sections, got %d" % repo.section_count())
	check(repo.glossary.size() == 128, "glossary 128, got %d" % repo.glossary.size())
	check(repo.quiz_items.size() >= 140, "quiz >= 140, got %d" % repo.quiz_items.size())
	check(not repo.sections.empty(), "sections not empty")

	# fonts load
	check(load("res://assets/fonts/ui.ttf") != null, "ui.ttf loads")
	check(load("res://assets/fonts/code.ttf") != null, "code.ttf loads")

	# block types and asset references
	var file := File.new()
	var steps_groups := 0
	var figure_count := 0
	var code_count := 0
	for section in repo.sections:
		for block in section.get("blocks", []):
			var kind := String(block.get("type", ""))
			check(VALID_BLOCK_TYPES.has(kind), "block type '%s' valid (%s)" % [kind, section.get("id")])
			if kind == "figure":
				figure_count += 1
				check(file.file_exists("res://assets/figures/%s.png" % String(block.get("img", ""))),
					"figure exists %s" % block.get("img"))
			elif kind == "figure_steps":
				steps_groups += 1
				var steps: Array = block.get("steps", [])
				check(int(block.get("count", 0)) == steps.size(), "steps count matches (%s)" % block.get("id"))
				check(steps.size() >= 2 and steps.size() <= 20, "steps size sane (%s)" % block.get("id"))
				for step_index in range(steps.size()):
					var step: Dictionary = steps[step_index]
					check(file.file_exists("res://assets/figures/%s.png" % String(step.get("img", ""))),
						"step png exists %s" % step.get("img"))
					if step_index == 0:
						check(file.file_exists("res://assets/figures/%s_thumb.png" % String(step.get("img", ""))),
							"step thumb exists %s" % step.get("img"))
			elif kind == "code":
				code_count += 1
				check(String(block.get("text", "")).length() > 0, "code non-empty (%s)" % section.get("id"))
	check(steps_groups == 39, "39 figure_steps, got %d" % steps_groups)
	check(figure_count == 209, "209 figures, got %d" % figure_count)
	check(code_count == 174, "174 code blocks, got %d" % code_count)

	# quiz integrity
	var mcq_count := 0
	var reveal_count := 0
	for item in repo.quiz_items:
		if String(item.get("type", "")) == "mcq":
			mcq_count += 1
			var options: Array = item.get("options", [])
			check(options.size() == 4, "mcq 4 options (%s)" % item.get("id"))
			check(options.has(String(item.get("answer", ""))), "mcq answer in options (%s)" % item.get("id"))
			var unique := {}
			for option in options:
				unique[String(option)] = true
			check(unique.size() == options.size(), "mcq options unique (%s)" % item.get("id"))
		else:
			reveal_count += 1
			check(String(item.get("answer", "")).length() > 0, "reveal answer non-empty (%s)" % item.get("id"))
	check(mcq_count >= 30, "mcq count >= 30, got %d" % mcq_count)
	check(reveal_count >= 80, "reveal count >= 80, got %d" % reveal_count)

	# boot the full app and paginate every section
	var main = load("res://scenes/Main.tscn").instance()
	root.add_child(main)
	yield(self, "idle_frame")
	yield(self, "idle_frame")
	check(main.screen == "home", "app boots to home")
	check(main.repo.section_count() == repo.section_count(), "app repo matches")

	var max_pages := 0
	var max_pages_section := ""
	for section in main.repo.sections:
		var pages: Array = main._build_pages(section)
		check(pages.size() >= 1, "pages >= 1 (%s)" % section.get("id"))
		if pages.size() > max_pages:
			max_pages = pages.size()
			max_pages_section = String(section.get("id"))
		if pages.size() > 80:
			print("WARN: section %s has %d pages" % [section.get("id"), pages.size()])
	print("longest section: %s = %d pages" % [max_pages_section, max_pages])

	# sample reader flow
	main._open_section("ch11_03")
	check(main.body_pages.size() >= 1, "bubble sort section paginates")
	main.body_page = main.body_pages.size() - 1
	main._show_reader()
	main._reader_done()

	# regression: steps card entry is X-only; A must stay a page-turn
	main._open_section("ch11_03")
	main.body_page = 0
	main._show_reader()
	var page_before_steps: int = main.body_page
	main._accept()
	check(main.screen == "reader" and main.body_page == page_before_steps + 1,
		"A turns page on steps-card page (no auto-open)")
	main.body_page = page_before_steps
	main._show_reader()
	main._replay()
	check(main.screen == "steps", "X opens steps viewer from card page")
	main._close_steps()
	check(main.screen == "reader", "return from steps to reader")

	# regression: qa overlay must not trap A (open -> close -> advances/reopens other qa)
	main._open_section("ch11_11")
	var qa_page := -1
	for pi in range(main.body_pages.size()):
		if main._page_has_qa(main.body_pages[pi]):
			qa_page = pi
			break
	check(qa_page >= 0, "summary has a qa page")
	main.body_page = qa_page
	main._show_reader()
	var qa_idx: int = main._first_unshown_qa_on_page(main.body_pages[qa_page])
	check(qa_idx >= 0, "qa page has an unshown qa")
	main._accept()
	check(main.qa_overlay == qa_idx, "A opens qa overlay")
	main._accept()
	check(main.qa_overlay == -1, "A closes qa overlay")
	main._accept()
	check(main.qa_overlay != qa_idx, "A does not reopen the same qa")

	# summary pages must carry their bullet-list content
	var summary_pages: Array = main._build_pages(main.repo.section_by_id("ch11_11"))
	var text_items := 0
	for sp in summary_pages:
		for item in sp:
			if item.get("k", "") == "p":
				text_items += item.get("lines", []).size()
	check(text_items >= 10, "summary list content paginated (got %d lines)" % text_items)

	print("SMOKE_CHECKS=%d FAILURES=%d" % [checks, failures])
	print("SMOKE_DONE")
	quit(1 if failures > 0 else 0)
