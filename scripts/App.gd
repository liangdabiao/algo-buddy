extends Control

# Algo Buddy — an offline Hello 算法 reader for the R36S.
# Single-scene app: every screen is a function that rebuilds screen_root,
# following the english-buddy / javascript-buddy template.

const ContentScript = preload("res://scripts/ContentRepository.gd")
const ProgressScript = preload("res://scripts/ProgressStore.gd")
const UIKitScript = preload("res://scripts/UIKit.gd")
const ChromeScript = preload("res://scripts/Chrome.gd")

const PAGE_SIZE := 8
const PAGE_TOP := 64.0
const PAGE_BOTTOM := 424.0
const CONTENT_WIDTH := 588.0
const CODE_WRAP_CHARS := 66
const OPTION_LETTERS := "ABCDEFGH"

var ui: UIKit
var repo
var progress
var chrome: Control
var screen_root: Control

var screen := "home"
var title_text := "Algo Buddy" setget _set_title_text
var footer_text := "" setget _set_footer_text
var menu_panels: Array = []
var menu_meta: Array = []
var menu_index := 0
var last_action_msec := 0

var toast_text := ""
var toast_time := 0.0

# navigation state
var chapter_page := 0
var section_page := 0
var chapters_mode := "read"          # "read" | "quiz"
var current_chapter_index := 0
var current_section_index := -1

# reader state
var body_pages: Array = []
var body_page := 0
var qa_revealed := Dictionary()      # qa index -> true (session only)
var qa_shown := Dictionary()         # qa index -> true (overlay opened once per session)
var qa_overlay_chunk := 0            # long-answer pagination while overlay is open
var qa_overlay := -1                 # qa index shown in the bottom overlay

# steps viewer state
var steps_block: Dictionary = {}
var steps_idx := 0
var steps_cache := Dictionary()      # image name -> Texture
var fig_cache := Dictionary()        # figure textures, preloaded before drawing

# quiz state
var quiz_items: Array = []
var quiz_index := 0
var quiz_correct := 0
var quiz_state := "playing"          # playing | feedback | reveal_answer | result
var quiz_selected := -1
var quiz_scope := ""
var quiz_result := {}

# glossary state
var glossary_page := 0
var glossary_index := -1


func _ready() -> void:
	ui = UIKitScript.new()
	repo = ContentScript.new()
	progress = ProgressScript.new()
	add_child(repo)
	add_child(progress)
	var backdrop := ui.panel(self, Rect2(0, 0, 640, 480), ui.BG, Color(0, 0, 0, 0), 0)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	move_child(backdrop, 0)
	chrome = ChromeScript.new()
	chrome.app = self
	chrome.rect_size = Vector2(640, 480)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(chrome)
	_show_home()


# ============================================================= chrome ======

func _set_title_text(value: String) -> void:
	title_text = value
	_sync_chrome()


func _set_footer_text(value: String) -> void:
	footer_text = value
	_sync_chrome()


func _sync_chrome() -> void:
	if chrome != null and is_instance_valid(chrome):
		chrome.update()


func draw_chrome(ci: CanvasItem) -> void:
	ci.draw_rect(Rect2(0, 0, 640, 54), Color(0.043, 0.063, 0.098, 0.95))
	ci.draw_rect(Rect2(0, 53, 640, 1), ui.LINE)
	ci.draw_string(ui.font(19), Vector2(20, 34), title_text, ui.TEXT)
	var status := "%d/%d 节 · %d XP · 连续 %d 天" % [
		progress.completed_count(), repo.section_count(),
		int(progress.data.get("xp", 0)), int(progress.data.get("streak", 0))]
	ci.draw_string(ui.font(13), Vector2(620 - ui.font(13).get_string_size(status).x, 33), status, ui.GOLD)
	ci.draw_rect(Rect2(0, 444, 640, 36), Color(0.043, 0.063, 0.098, 0.95))
	ci.draw_rect(Rect2(0, 444, 640, 1), ui.LINE)
	ci.draw_string(ui.font(14), Vector2(20, 467), footer_text, ui.MUTED)
	if toast_text != "":
		var width := ui.font(17).get_string_size(toast_text).x + 40
		ci.draw_rect(Rect2((640 - width) / 2, 61, width, 38), Color(0.09, 0.14, 0.22, 0.96))
		ci.draw_string(ui.font(17), Vector2((640 - width) / 2 + 20, 86), toast_text, ui.GREEN)


func _process(delta: float) -> void:
	if toast_time > 0:
		toast_time -= delta
		if toast_time <= 0:
			toast_text = ""
			_sync_chrome()


# ============================================================= input =======

func _input(event: InputEvent) -> void:
	if not event.is_pressed():
		return
	if event is InputEventKey and event.echo:
		return
	var action := ""
	for candidate in ["nav_up", "nav_down", "nav_left", "nav_right", "accept", "back", "replay", "hint", "prev", "next", "menu"]:
		if event.is_action_pressed(candidate):
			action = candidate
			break
	if action == "":
		return
	var now := OS.get_ticks_msec()
	if now - last_action_msec < 70:
		return
	last_action_msec = now
	get_viewport().set_input_as_handled()
	match action:
		"nav_up": _navigate(-1)
		"nav_down": _navigate(1)
		"nav_left": _page_step(-1)
		"nav_right": _page_step(1)
		"accept": _accept()
		"back": _back()
		"replay": _replay()
		"hint": _hint()
		"prev": _page_step(-1)
		"next": _page_step(1)
		"menu": _menu_button()


func _clear_screen() -> void:
	if is_instance_valid(screen_root):
		remove_child(screen_root)
		screen_root.queue_free()
	screen_root = Control.new()
	screen_root.rect_size = Vector2(640, 480)
	screen_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen_root)
	move_child(screen_root, 1)
	menu_panels.clear()
	menu_meta.clear()
	menu_index = 0
	fig_cache.clear()
	_sync_chrome()


func _show_toast(text: String) -> void:
	toast_text = text
	toast_time = 2.6
	_sync_chrome()


# ============================================================= menu ========

func _build_menu(items: Array, rect: Rect2, spacing: float, columns: int) -> void:
	for index in range(items.size()):
		var item: Dictionary = items[index]
		var y: float = rect.position.y + index * spacing if spacing > 0 else rect.position.y + index * (rect.size.y + 8)
		var panel := ui.panel(screen_root, Rect2(rect.position.x, y, rect.size.x, rect.size.y), ui.PANEL, ui.LINE, 10)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.connect("gui_input", self, "_on_menu_gui_input", [index], CONNECT_DEFERRED)
		var status: String = String(item.get("status", ""))
		var status_width: float = ui.font(14).get_string_size(status).x + 8 if status != "" else 0
		ui.label(panel, String(item.get("text", "")), Rect2(16, 3, rect.size.x - status_width - 24, rect.size.y - 6), 17 if rect.size.y >= 40 else 15, ui.TEXT, 0, true)
		if status != "":
			var status_color: Color = ui.GREEN if status.begins_with("已读") else ui.MUTED
			ui.label(panel, status, Rect2(rect.size.x - status_width - 8, 3, status_width, rect.size.y - 6), 13, status_color, 2)
		if not bool(item.get("enabled", true)):
			panel.modulate = Color(1, 1, 1, 0.4)
		menu_panels.append(panel)
		menu_meta.append(item)
	_refresh_menu()


func _refresh_menu() -> void:
	for index in range(menu_panels.size()):
		var selected := index == menu_index
		var background_color: Color = ui.PANEL_LIGHT if selected else ui.PANEL
		var border_color: Color = ui.GOLD if selected else ui.LINE
		menu_panels[index].add_stylebox_override("panel", ui.style(background_color, border_color, 10, 2 if selected else 1))
		if bool(menu_meta[index].get("enabled", true)):
			menu_panels[index].modulate = Color(1, 1, 1, 1)


func _on_menu_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_LEFT:
		menu_index = index
		_refresh_menu()
		_activate_menu()


func _navigate(direction: int) -> void:
	if screen == "steps":
		_steps_move(direction)
		return
	if menu_panels.empty():
		return
	if screen == "chapters":
		var start := chapter_page * PAGE_SIZE
		var count: int = min(PAGE_SIZE, repo.chapter_count() - start)
		if direction < 0 and menu_index == 0 and chapter_page > 0:
			chapter_page -= 1
			_show_chapters()
			menu_index = max(0, min(PAGE_SIZE, repo.chapter_count() - chapter_page * PAGE_SIZE) - 1)
			_refresh_menu()
			return
		if direction > 0 and menu_index == count - 1 and (chapter_page + 1) * PAGE_SIZE < repo.chapter_count():
			chapter_page += 1
			_show_chapters()
			return
	if screen == "sections":
		var bucket: Array = repo.sections_for_chapter(_current_chapter_id())
		var start2 := section_page * PAGE_SIZE
		var count2: int = min(PAGE_SIZE, bucket.size() - start2)
		if direction < 0 and menu_index == 0 and section_page > 0:
			section_page -= 1
			_show_sections()
			menu_index = max(0, min(PAGE_SIZE, bucket.size() - section_page * PAGE_SIZE) - 1)
			_refresh_menu()
			return
		if direction > 0 and menu_index == count2 - 1 and (section_page + 1) * PAGE_SIZE < bucket.size():
			section_page += 1
			_show_sections()
			return
	if screen == "glossary":
		var gsize: int = repo.glossary.size()
		var gstart := glossary_page * PAGE_SIZE
		if direction < 0 and menu_index == 0 and glossary_page > 0:
			glossary_page -= 1
			_show_glossary()
			return
		if direction > 0 and menu_index == min(PAGE_SIZE, gsize - gstart) - 1 and (glossary_page + 1) * PAGE_SIZE < gsize:
			glossary_page += 1
			_show_glossary()
			return
	menu_index = posmod(menu_index + direction, menu_panels.size())
	_refresh_menu()


func _page_step(direction: int) -> void:
	match screen:
		"reader":
			if qa_overlay >= 0:
				qa_overlay = -1
				_show_reader()
				return
			var next_page := body_page + direction
			if next_page >= 0 and next_page < body_pages.size():
				body_page = next_page
				_show_reader()
		"chapters":
			var max_page := max(0, int(ceil(float(repo.chapter_count()) / float(PAGE_SIZE))) - 1)
			var np := clamp(chapter_page + direction, 0, max_page)
			if np != chapter_page:
				chapter_page = np
				_show_chapters()
		"sections":
			var bucket: Array = repo.sections_for_chapter(_current_chapter_id())
			var max_page2 := max(0, int(ceil(float(bucket.size()) / float(PAGE_SIZE))) - 1)
			var np2 := clamp(section_page + direction, 0, max_page2)
			if np2 != section_page:
				section_page = np2
				_show_sections()
		"glossary":
			var gsize2: int = repo.glossary.size()
			var max_page3 := max(0, int(ceil(float(gsize2) / float(PAGE_SIZE))) - 1)
			var np3 := clamp(glossary_page + direction, 0, max_page3)
			if np3 != glossary_page:
				glossary_page = np3
				_show_glossary()
		"steps":
			_steps_move(direction)


func _accept() -> void:
	match screen:
		"reader":
			if qa_overlay >= 0:
				# answer open: A walks through long-answer chunks, then closes
				var chunks: int = _qa_overlay_chunk_count()
				if qa_overlay_chunk + 1 < chunks:
					qa_overlay_chunk += 1
				else:
					qa_overlay = -1
				_show_reader()
				return
			var page: Array = body_pages[body_page] if body_page < body_pages.size() else []
			# A = reading flow (Q&A overlay, then turn page); X = step viewer entry
			var qidx: int = _first_unshown_qa_on_page(page)
			if qidx >= 0:
				_open_qa_overlay(qidx)
				return
			if body_page + 1 < body_pages.size():
				body_page += 1
				_show_reader()
			else:
				_reader_done()
		"quiz":
			_quiz_accept()
		"steps":
			_steps_move(1)
		"figure":
			_close_figure()
		"reset":
			progress.reset_game()
			_show_home()
		_:
			if not menu_panels.empty():
				_activate_menu()


func _back() -> void:
	match screen:
		"reader":
			if qa_overlay >= 0:
				qa_overlay = -1
				_show_reader()
			else:
				_show_sections()
		"sections": _show_chapters()
		"chapters": _show_home()
		"quiz":
			if quiz_state == "feedback":
				quiz_state = "playing"
				quiz_selected = -1
				_show_quiz()
			elif quiz_state == "reveal_answer":
				quiz_state = "playing"
				_show_quiz()
			else:
				_show_home()
		"steps": _close_steps()
		"figure": _close_figure()
		"glossary":
			if glossary_index >= 0:
				glossary_index = -1
				_show_glossary()
			else:
				_show_home()
		"controls", "about", "result", "reset": _show_home()
		"home": pass


func _replay() -> void:
	# X button: open the step viewer from a reader page, step forward in it.
	match screen:
		"reader":
			if qa_overlay >= 0:
				qa_overlay = -1
				_show_reader()
				return
			var page: Array = body_pages[body_page] if body_page < body_pages.size() else []
			for item in page:
				if item.get("k", "") == "steps":
					_open_steps(item)
					return
			_page_step(1)
		"steps":
			_steps_move(1)
		"figure":
			_close_figure()


func _hint() -> void:
	# Y button: reveal the Q&A answer of the current reader page.
	if screen == "reader" and qa_overlay < 0:
		var page: Array = body_pages[body_page] if body_page < body_pages.size() else []
		var qidx: int = _first_unshown_qa_on_page(page)
		if qidx < 0:
			qidx = _first_qa_on_page(page)
		if qidx >= 0:
			_open_qa_overlay(qidx)


func _menu_button() -> void:
	if screen != "home":
		_show_home()


# ============================================================= home ========

func _show_home() -> void:
	_clear_screen()
	_clear_steps_cache()
	screen = "home"
	title_text = "Algo Buddy"
	footer_text = "上下键 选择   A 确认   Start 退出"
	var meta: Dictionary = repo.meta
	var subtitle := "%s · 离线版" % String(meta.get("sourceTitle", "Hello 算法"))
	ui.label(screen_root, subtitle, Rect2(30, 70, 580, 26), 15, ui.GREEN)
	ui.label(screen_root, "动画图解 · 数据结构与算法", Rect2(30, 100, 580, 40), 27, ui.TEXT)
	var total := max(1, repo.section_count())
	ui.progress_bar(screen_root, Rect2(30, 150, 580, 6), float(progress.completed_count()) / float(total), ui.GOLD)
	var due: int = progress.due_quiz_ids().size()
	var continue_label := "继续阅读"
	var cont_section := {}
	var cont_id: String = progress.current_section_id()
	if cont_id != "":
		cont_section = repo.section_by_id(cont_id)
	if cont_section.empty():
		cont_section = repo.get_section(_first_unread_index())
	var cont_text := String(cont_section.get("title", "开始学习"))
	if cont_text.length() > 24:
		cont_text = cont_text.substr(0, 22) + "…"
	continue_label = "继续阅读 · " + cont_text
	var items := [
		{"text": continue_label, "action": "continue", "enabled": true},
		{"text": "章节目录 · %d 章" % repo.chapter_count(), "action": "chapters", "enabled": true},
		{"text": "错题复习 · %d 题到期" % due, "action": "review", "enabled": due > 0},
		{"text": "术语表 · %d 条" % repo.glossary.size(), "action": "glossary", "enabled": true},
		{"text": "操作说明", "action": "controls", "enabled": true},
		{"text": "关于与版权", "action": "about", "enabled": true},
		{"text": "清除学习记录", "action": "reset", "enabled": true},
	]
	_build_menu(items, Rect2(44, 172, 552, 36), 37, 0)
	ui.label(screen_root, "内容来自《Hello 算法》(CC BY-NC-SA 4.0)，仅供个人学习。", Rect2(44, 420, 552, 20), 12, ui.MUTED, 1)


func _first_unread_index() -> int:
	for index in range(repo.section_count()):
		if not progress.is_completed(String(repo.get_section(index).get("id", ""))):
			return index
	return 0


# ============================================================= chapters ====

func _show_chapters() -> void:
	_clear_screen()
	screen = "chapters"
	title_text = "章节测验" if chapters_mode == "quiz" else "章节目录"
	footer_text = "上下键 选择   A 进入   B 返回   左右键 翻页"
	var start := chapter_page * PAGE_SIZE
	var items := []
	for index in range(start, min(start + PAGE_SIZE, repo.chapter_count())):
		var chapter: Dictionary = repo.get_chapter(index)
		var chapter_id := String(chapter.get("id", ""))
		var bucket: Array = repo.sections_for_chapter(chapter_id)
		var done := 0
		for section in bucket:
			if progress.is_completed(String(section.get("id", ""))):
				done += 1
		var label := String(chapter.get("title", ""))
		var num = chapter.get("num")
		var prefix := "第%s章 " % (str(num) + "") if num != null else ""
		items.append({
			"text": prefix + label,
			"status": "%d/%d" % [done, bucket.size()],
			"action": "chapter",
			"index": index,
			"enabled": true,
		})
	_build_menu(items, Rect2(28, 68, 584, 40), 44, 0)
	var pages := max(1, int(ceil(float(repo.chapter_count()) / float(PAGE_SIZE))))
	ui.label(screen_root, "第 %d / %d 页" % [chapter_page + 1, pages], Rect2(420, 452, 192, 22), 13, ui.MUTED, 2)


func _current_chapter_id() -> String:
	return String(repo.get_chapter(current_chapter_index).get("id", ""))


# ============================================================= sections ====

func _show_sections() -> void:
	_clear_screen()
	screen = "sections"
	var chapter: Dictionary = repo.get_chapter(current_chapter_index)
	var chapter_label := String(chapter.get("title", ""))
	var num = chapter.get("num")
	if num != null:
		chapter_label = "第%s章 %s" % [str(num), chapter_label]
	title_text = chapter_label
	footer_text = "上下键 选择   A 阅读   B 返回   左右键 翻页"
	var bucket: Array = repo.sections_for_chapter(_current_chapter_id())
	var start := section_page * PAGE_SIZE
	var items := []
	for index in range(start, min(start + PAGE_SIZE, bucket.size())):
		var section: Dictionary = bucket[index]
		var section_id := String(section.get("id", ""))
		var label := String(section.get("title", ""))
		var section_num := String(section.get("num", ""))
		if section_num != "":
			label = "%s %s" % [section_num, label]
		if bool(section.get("optional", false)):
			label += " （选学）"
		var status := "已读" if progress.is_completed(section_id) else ""
		var score: int = progress.best_score(section_id)
		if score >= 0 and score < 100:
			status = "%d分" % score if status == "" else "%s %d分" % [status, score]
		items.append({
			"text": label,
			"status": status,
			"action": "section",
			"section_id": section_id,
			"enabled": true,
		})
	_build_menu(items, Rect2(28, 68, 584, 40), 44, 0)
	var pages := max(1, int(ceil(float(bucket.size()) / float(PAGE_SIZE))))
	ui.label(screen_root, "第 %d / %d 页" % [section_page + 1, pages], Rect2(420, 452, 192, 22), 13, ui.MUTED, 2)


# ============================================================= reader ======

func _open_section(section_id: String) -> void:
	var section: Dictionary = repo.section_by_id(section_id)
	if section.empty():
		return
	current_section_index = repo.sections.find(section)
	var chapter_id := String(section.get("chapter", ""))
	for index in range(repo.chapter_count()):
		if String(repo.get_chapter(index).get("id", "")) == chapter_id:
			current_chapter_index = index
			break
	progress.set_current_section(section_id)
	body_pages = _build_pages(section)
	if body_pages.empty():
		body_pages = [[{"k": "p", "lines": [[["t", "（本节没有正文内容）"]]]}]]
	var saved_page: int = progress.reading_page(section_id)
	body_page = clamp(saved_page, 0, body_pages.size() - 1)
	qa_revealed = {}
	qa_overlay = -1
	qa_shown = {}
	_show_reader()


func _show_reader() -> void:
	_clear_screen()
	screen = "reader"
	var section: Dictionary = repo.get_section(max(0, current_section_index))
	var label := String(section.get("title", "阅读"))
	if label.length() > 24:
		label = label.substr(0, 22) + "…"
	title_text = label
	var page: Array = body_pages[body_page] if body_page < body_pages.size() else []
	if qa_overlay >= 0:
		var chunks: int = _qa_overlay_chunk_count()
		footer_text = "A %s答案   B 关闭" % ("下一段 " if qa_overlay_chunk + 1 < chunks else "关闭")
		_draw_page_and_hints(page)
		return
	var hints := ""
	if _first_unshown_qa_on_page(page) >= 0:
		hints = "A 显示问答   B 返回   L/R 翻页"
	else:
		hints = "A 下一页   B 返回"
	if _page_has_steps(page):
		hints = "X 进入步进图   " + hints
	footer_text = hints
	_draw_page_and_hints(page)


func _draw_page_and_hints(page: Array) -> void:
	# preload this page's figure textures before the canvas draws
	for item in page:
		var kind := String(item.get("k", ""))
		var image_name := ""
		if kind == "fig":
			image_name = String(item.get("img", ""))
		elif kind == "steps":
			image_name = String(item.get("thumb", "")) + "_thumb"
		if image_name != "" and not fig_cache.has(image_name):
			var fig_path: String = repo.figure_path(image_name)
			if ResourceLoader.exists(fig_path):
				fig_cache[image_name] = load(fig_path)
	var page_view := PageCanvas.new()
	page_view.app = self
	page_view.page = page
	page_view.rect_position = Vector2(26, 0)
	page_view.rect_size = Vector2(640, 480)
	page_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_root.add_child(page_view)
	ui.label(screen_root, "第 %d / %d 页" % [body_page + 1, body_pages.size()], Rect2(430, 448, 186, 26), 13, ui.GOLD, 2)
	if qa_overlay >= 0:
		_draw_qa_overlay(page)


func _page_has_steps(page: Array) -> bool:
	for item in page:
		if item.get("k", "") == "steps":
			return true
	return false


func _page_has_qa(page: Array) -> bool:
	return _first_qa_on_page(page) >= 0


func _first_qa_on_page(page: Array) -> int:
	for item in page:
		if item.get("k", "") == "qa":
			return int(item.get("qidx", -1))
	return -1


func _first_unshown_qa_on_page(page: Array) -> int:
	for item in page:
		if item.get("k", "") == "qa":
			var qidx: int = int(item.get("qidx", -1))
			if not qa_shown.has(qidx):
				return qidx
	return -1


func _open_qa_overlay(qidx: int) -> void:
	qa_overlay = qidx
	qa_shown[qidx] = true
	qa_overlay_chunk = 0
	_show_reader()


func _qa_overlay_chunks(answer: String) -> Array:
	# long answers are paginated inside the overlay, 7 wrapped lines per chunk
	var lines := _wrap_plain(answer, 580, 15)
	var chunks: Array = []
	var i := 0
	while i < lines.size():
		chunks.append(lines.slice(i, min(i + 7, lines.size()) - 1))
		i += 7
	if chunks.empty():
		chunks.append([])
	return chunks


func _qa_overlay_chunk_count() -> int:
	for item in body_pages[body_page] if body_page < body_pages.size() else []:
		if item.get("k", "") == "qa" and int(item.get("qidx", -1)) == qa_overlay:
			return _qa_overlay_chunks(String(item.get("answer", ""))).size()
	return 1


func _draw_qa_overlay(page: Array) -> void:
	var question := ""
	var answer := ""
	for item in page:
		if item.get("k", "") == "qa" and int(item.get("qidx", -1)) == qa_overlay:
			question = _runs_plain_list(item.get("qlines", []))
			answer = String(item.get("answer", ""))
			break
	ui.panel(screen_root, Rect2(14, 208, 612, 232), Color("141d2b"), ui.GOLD, 12)
	ui.label(screen_root, "问答题", Rect2(30, 214, 200, 24), 14, ui.GOLD)
	var q_label := ui.label(screen_root, question, Rect2(30, 238, 580, 44), 16, ui.TEXT, 0, true)
	q_label.autowrap = true
	var chunks: Array = _qa_overlay_chunks(answer)
	var chunk: Array = chunks[min(qa_overlay_chunk, chunks.size() - 1)]
	var shown := ""
	for line in chunk:
		shown += _line_text(line) + "\n"
	var chunk_hint := ""
	if chunks.size() > 1:
		chunk_hint = "（%d / %d）" % [qa_overlay_chunk + 1, chunks.size()]
	ui.label(screen_root, shown, Rect2(30, 286, 580, 148), 15, ui.GREEN, 0, true)
	ui.label(screen_root, "答案" + chunk_hint + "   A 继续   B 关闭", Rect2(430, 214, 196, 24), 13, ui.MUTED, 2)


func _reader_done() -> void:
	var section: Dictionary = repo.get_section(max(0, current_section_index))
	var section_id := String(section.get("id", ""))
	progress.save_reading_position(section_id, body_pages.size() - 1, body_pages.size())
	var first: bool = progress.mark_section_done(section_id)
	var quiz: Array = repo.quiz_for_section(section_id)
	if quiz.empty():
		if first:
			_show_toast("本节完成 +5 XP")
		_show_result(section_id, 0, 0, true)
		return
	_start_quiz(quiz, section_id)


# ====================================================== pagination =========

var _pb_pages: Array = []
var _pb_current: Array = []
var _pb_y := PAGE_TOP
var qa_counter := 0


func _build_pages(section: Dictionary) -> Array:
	_pb_pages = []
	_pb_current = []
	_pb_y = PAGE_TOP
	qa_counter = 0
	for block in section.get("blocks", []):
		_flow_block(block)
	if not _pb_current.empty():
		_pb_pages.append(_pb_current)
		_pb_current = []
	var pages := _pb_pages
	_pb_pages = []
	return pages


func _flow_push_page() -> void:
	if not _pb_current.empty():
		_pb_pages.append(_pb_current)
		_pb_current = []
		_pb_y = PAGE_TOP


func _flow_need(height: float) -> void:
	if _pb_y + height > PAGE_BOTTOM and not _pb_current.empty():
		_flow_push_page()


func _flow_block(block: Dictionary) -> void:
	var kind := String(block.get("type", ""))
	match kind:
		"h2":
			var h_lines := _wrap_runs(block.get("runs", []), CONTENT_WIDTH, 20)
			var h_h := h_lines.size() * 30 + 8.0
			_flow_need(h_h)
			_pb_current.append({"k": "h", "size": 20, "lines": h_lines})
			_pb_y += h_h
		"h3":
			var h3_lines := _wrap_runs(block.get("runs", []), CONTENT_WIDTH, 18)
			var h3_h := h3_lines.size() * 27 + 6.0
			_flow_need(h3_h)
			_pb_current.append({"k": "h", "size": 18, "lines": h3_lines})
			_pb_y += h3_h
		"para":
			var p_lines := _wrap_runs(block.get("runs", []), CONTENT_WIDTH, 17)
			var offset := 0
			while offset < p_lines.size():
				var room := int((PAGE_BOTTOM - _pb_y) / 25.0)
				if room <= 1 and not _pb_current.empty():
					_flow_push_page()
					continue
				room = max(1, int((PAGE_BOTTOM - _pb_y) / 25.0))
				var take: int = min(room, p_lines.size() - offset)
				_pb_current.append({"k": "p", "lines": p_lines.slice(offset, offset + take - 1)})
				_pb_y += take * 25.0 + 4.0
				offset += take
				if offset < p_lines.size():
					_flow_push_page()
		"list":
			var list_items: Array = block.get("items", [])
			var ordered := bool(block.get("ordered", false))
			for li in range(list_items.size()):
				var item_runs: Array = list_items[li]
				var prefix := "%d. " % (li + 1) if ordered else "· "
				var bullet: Dictionary = {"s": "t", "t": prefix}
				var all_runs: Array = [bullet] + item_runs
				var li_lines := _wrap_runs(all_runs, CONTENT_WIDTH - 26, 17)
				var li_offset := 0
				while li_offset < li_lines.size():
					var li_room := int((PAGE_BOTTOM - _pb_y) / 25.0)
					if li_room <= 1 and not _pb_current.empty():
						_flow_push_page()
						continue
					li_room = max(1, int((PAGE_BOTTOM - _pb_y) / 25.0))
					var li_take: int = min(li_room, li_lines.size() - li_offset)
					_pb_current.append({"k": "p", "indent": 26.0, "lines": li_lines.slice(li_offset, li_offset + li_take - 1)})
					_pb_y += li_take * 25.0 + 2.0
					li_offset += li_take
					if li_offset < li_lines.size():
						_flow_push_page()
			_pb_y += 4.0
		"tip":
			var t_lines := _wrap_runs(block.get("runs", []), CONTENT_WIDTH - 40, 15)
			var tip_title := String(block.get("title", ""))
			var t_h := (t_lines.size() + (1 if tip_title != "" else 0)) * 22 + 18.0
			_flow_need(t_h)
			_pb_current.append({"k": "tip", "title": tip_title, "lines": t_lines})
			_pb_y += t_h
		"code":
			var c_lines := _wrap_code(String(block.get("text", "")))
			var offset2 := 0
			while offset2 < c_lines.size():
				var room2 := int((PAGE_BOTTOM - _pb_y - 12.0) / 19.0)
				if room2 <= 1 and not _pb_current.empty():
					_flow_push_page()
					continue
				room2 = max(1, int((PAGE_BOTTOM - _pb_y - 12.0) / 19.0))
				var take2: int = min(room2, c_lines.size() - offset2)
				_pb_current.append({"k": "code", "lines": c_lines.slice(offset2, offset2 + take2 - 1)})
				_pb_y += take2 * 19.0 + 12.0
				offset2 += take2
				if offset2 < c_lines.size():
					_flow_push_page()
		"figure":
			_flow_need(360)
			if _pb_y > PAGE_TOP:
				_flow_push_page()
			_pb_current.append({"k": "fig", "img": String(block.get("img", "")), "caption": String(block.get("caption", ""))})
			_flow_push_page()
		"figure_steps":
			var steps: Array = block.get("steps", [])
			var thumb := ""
			if not steps.empty():
				thumb = String(steps[0].get("img", ""))
			_flow_need(172)
			_pb_current.append({
				"k": "steps", "id": String(block.get("id", "")), "title": String(block.get("title", "")),
				"count": int(block.get("count", 0)), "thumb": thumb,
			})
			_pb_y += 172.0
		"qa":
			var q_lines := _wrap_runs(block.get("question_runs", []), CONTENT_WIDTH, 17)
			var a_plain := _runs_plain_list_runs(block.get("answer_runs", []))
			var q_h := q_lines.size() * 25 + 26.0
			_flow_need(q_h)
			_pb_current.append({
				"k": "qa", "qidx": qa_counter, "lines": q_lines, "answer": a_plain,
			})
			qa_counter += 1
			_pb_y += q_h
		"table":
			for t_item in _table_items(block):
				_flow_need(float(t_item["h"]))
				if _pb_y > PAGE_TOP and _pb_y + float(t_item["h"]) > PAGE_BOTTOM:
					_flow_push_page()
				_pb_current.append(t_item)
				_pb_y += float(t_item["h"])


func _table_items(block: Dictionary) -> Array:
	# Precompute column widths and split rows into page-sized chunks.
	var header: Array = block.get("header", [])
	var raw_rows: Array = block.get("rows", [])
	var cols := header.size()
	if cols == 0:
		return []
	var plain_rows: Array = []
	for row in raw_rows:
		var cells: Array = []
		for ci in range(cols):
			cells.append(_runs_plain_list_runs(row[ci]) if ci < row.size() else "")
		plain_rows.append(cells)
	var widths: Array = []
	for ci in range(cols):
		var w := ui.font(13).get_string_size(String(header[ci])).x + 16
		for row in plain_rows:
			if ci < row.size():
				w = max(w, ui.font(13).get_string_size(String(row[ci])).x + 16)
		widths.append(max(48.0, w))
	var total := 0.0
	for w in widths:
		total += w
	if total > CONTENT_WIDTH:
		var factor := CONTENT_WIDTH / total
		for ci in range(widths.size()):
			widths[ci] = max(40.0, widths[ci] * factor)
		total = CONTENT_WIDTH

	var header_lines := 1
	for ci in range(cols):
		header_lines = max(header_lines, _wrap_plain(String(header[ci]), widths[ci] - 12, 13).size())
	var header_h := header_lines * 20 + 8.0

	var items: Array = []
	var chunk: Array = []
	var chunk_h := header_h
	for row in plain_rows:
		var row_lines := 1
		for ci in range(min(cols, row.size())):
			row_lines = max(row_lines, _wrap_plain(String(row[ci]), widths[ci] - 12, 13).size())
		var row_h := row_lines * 20 + 4.0
		if chunk_h + row_h > PAGE_BOTTOM - PAGE_TOP - 8.0 and not chunk.empty():
			items.append({"k": "table", "header": header, "rows": chunk, "widths": widths, "h": chunk_h})
			chunk = []
			chunk_h = header_h
		chunk.append({"cells": row, "lines": row_lines})
		chunk_h += row_h
	if not chunk.empty():
		items.append({"k": "table", "header": header, "rows": chunk, "widths": widths, "h": chunk_h})
	return items


# ----------------------------------------------- run wrapping --------------

func _is_cjk_char(ch: String) -> bool:
	var o := ch.ord_at(0)
	return (o >= 0x4E00 and o <= 0x9FFF) or (o >= 0x3000 and o <= 0x303F) or (o >= 0xFF00 and o <= 0xFFEF) or (o >= 0x2E80 and o <= 0x2EFF)


func _tokenize_runs(runs: Array, tokens: Array) -> void:
	for run in runs:
		var style := String(run.get("s", "t"))
		var text := String(run.get("t", ""))
		var buffer := ""
		for i in range(text.length()):
			var ch := text.substr(i, 1)
			if ch == " ":
				if buffer != "":
					tokens.append([style, buffer])
					buffer = ""
				tokens.append(["t", " "])
			elif _is_cjk_char(ch):
				if buffer != "":
					tokens.append([style, buffer])
					buffer = ""
				tokens.append([style, ch])
			else:
				buffer += ch
		if buffer != "":
			tokens.append([style, buffer])


func _wrap_runs(runs: Array, width: float, size: int) -> Array:
	var tokens: Array = []
	_tokenize_runs(runs, tokens)
	var lines: Array = []
	var line: Array = []
	var used := 0.0
	for token in tokens:
		var style := String(token[0])
		var text := String(token[1])
		var f := ui.font_for_style(style, size)
		var tw := f.get_string_size(text).x
		if text == " ":
			tw = ui.font(size).get_string_size(" ").x
		if used + tw > width and line.size() > 0:
			while line.size() > 0 and String(line[line.size() - 1][1]) == " ":
				line.pop_back()
			lines.append(line)
			line = []
			used = 0.0
			if text == " ":
				continue
		line.append([style, text])
		used += tw
	if line.size() > 0:
		lines.append(line)
	if lines.empty():
		lines.append([["t", ""]])
	return lines


func _wrap_plain(text: String, width: float, size: int) -> Array:
	return _wrap_runs([{"s": "t", "t": text}], width, size)


func _wrap_code(text: String) -> Array:
	var out: Array = []
	for line in text.split("\n"):
		var line_text := String(line)
		while line_text.length() > CODE_WRAP_CHARS:
			out.append(line_text.substr(0, CODE_WRAP_CHARS))
			line_text = "    " + line_text.substr(CODE_WRAP_CHARS)
		out.append(line_text)
	return out


func _runs_plain_list_runs(runs: Array) -> String:
	var out := ""
	for run in runs:
		out += String(run.get("t", ""))
	return out


func _runs_plain_list(lines: Array) -> String:
	var out := ""
	for line in lines:
		for seg in line:
			out += String(seg[1])
	return out


# ====================================================== page canvas ========

class PageCanvas extends Control:
	var app: Node
	var page: Array

	func _draw() -> void:
		if app != null and is_instance_valid(app):
			app.draw_page(self, page)


func draw_page(ci: CanvasItem, page: Array) -> void:
	var y := PAGE_TOP
	for item in page:
		var kind := String(item.get("k", ""))
		match kind:
			"h":
				for line in item.get("lines", []):
					_draw_run_line(ci, line, Vector2(0, y), int(item.get("size", 18)))
					y += 30 if int(item.get("size", 18)) >= 20 else 27
				y += 8.0 if int(item.get("size", 18)) >= 20 else 6.0
			"p":
				var indent: float = float(item.get("indent", 0.0))
				for line in item.get("lines", []):
					_draw_run_line(ci, line, Vector2(indent, y), 17)
					y += 25.0
				y += 4.0
			"tip":
				var tip_lines_count: int = item.get("lines", []).size()
				var tip_h: float = (tip_lines_count + (1 if String(item.get("title", "")) != "" else 0)) * 22 + 12.0
				ci.draw_style_box(ui.style(Color("152234"), ui.LINE, 8), Rect2(0, y, CONTENT_WIDTH, tip_h))
				var ty := y + 10.0
				if String(item.get("title", "")) != "":
					ci.draw_string(ui.font(15), Vector2(20, ty + 15), "Tips · " + String(item.get("title", "")), ui.GOLD)
					ty += 22.0
				for line in item.get("lines", []):
					_draw_run_line(ci, line, Vector2(20, ty), 15)
					ty += 22.0
				y += tip_h + 6.0
			"code":
				var c_lines: Array = item.get("lines", [])
				var c_h := c_lines.size() * 19.0 + 12.0
				ci.draw_style_box(ui.style(ui.CODE_BG, ui.LINE, 6), Rect2(0, y, CONTENT_WIDTH, c_h))
				var cy := y + 8.0
				for line_text in c_lines:
					var s := String(line_text)
					var f := ui.code_font(13) if not _line_has_cjk(s) else ui.font(12)
					ci.draw_string(f, Vector2(14, cy + 14), s, ui.BLUE)
					cy += 19.0
				y += c_h + 6.0
			"fig":
				var tex = fig_cache.get(String(item.get("img", "")), null)
				var img_h := 330.0
				if tex != null:
					var ratio: float = float(tex.get_width()) / float(tex.get_height())
					img_h = clamp(CONTENT_WIDTH / ratio, 120.0, 336.0)
					# figures are authored on white; back them with a white page panel
					ci.draw_style_box(ui.style(Color(1, 1, 1, 1), ui.LINE, 6), Rect2(-6, y - 6, CONTENT_WIDTH + 12, img_h + 12))
					ci.draw_texture_rect(tex, Rect2(0, y, CONTENT_WIDTH, img_h), false)
				if String(item.get("caption", "")) != "":
					ci.draw_string(ui.font(13), Vector2(0, y + img_h + 20), String(item.get("caption", "")), ui.MUTED, CONTENT_WIDTH)
				y += img_h + 28.0
			"steps":
				var card_y := y
				var steps_count: int = int(item.get("count", 0))
				ci.draw_style_box(ui.style(ui.PANEL, ui.GOLD, 10), Rect2(0, card_y, CONTENT_WIDTH, 164))
				var thumb = fig_cache.get(String(item.get("thumb", "")) + "_thumb", null)
				if thumb != null:
					ci.draw_style_box(ui.style(Color(1, 1, 1, 1), Color(0, 0, 0, 0), 4), Rect2(6, card_y + 6, 276, 152))
					ci.draw_texture_rect(thumb, Rect2(10, card_y + 10, 268, 144), false)
					# play badge (bottom-right of the thumb): universal "playable" cue
					var play_center := Vector2(250, card_y + 128)
					ci.draw_circle(play_center, 19.0, Color(0.05, 0.09, 0.15, 0.88))
					var triangle := PoolVector2Array([
						play_center + Vector2(-6, -10),
						play_center + Vector2(-6, 10),
						play_center + Vector2(12, 0),
					])
					ci.draw_colored_polygon(triangle, ui.GOLD)
					# step-count badge (top-left of the thumb), like a video length tag
					var badge_text := "共 %d 步" % steps_count
					var badge_w := ui.font(13).get_string_size(badge_text).x + 18
					ci.draw_style_box(ui.style(Color(0.05, 0.09, 0.15, 0.88), Color(0, 0, 0, 0), 5),
						Rect2(16, card_y + 16, badge_w, 24))
					ci.draw_string(ui.font(13), Vector2(26, card_y + 33), badge_text, Color(1, 1, 1, 0.95))
				ci.draw_string(ui.font(17), Vector2(292, card_y + 34), String(item.get("title", "")), ui.TEXT, 284)
				ci.draw_string(ui.font(13), Vector2(292, card_y + 58), "这不是一张静态图：每按一次前进一格动画", ui.MUTED)
				# call-to-action button
				ci.draw_style_box(ui.style(ui.GOLD, Color(0, 0, 0, 0), 17), Rect2(292, card_y + 76, 236, 36))
				ci.draw_string(ui.font(16), Vector2(312, card_y + 99), "按 X 进入播放", Color("13202e"))
				var btn_tri_center := Vector2(498, card_y + 94)
				var btn_triangle := PoolVector2Array([
					btn_tri_center + Vector2(-5, -8),
					btn_tri_center + Vector2(-5, 8),
					btn_tri_center + Vector2(9, 0),
				])
				ci.draw_colored_polygon(btn_triangle, Color("13202e"))
				ci.draw_string(ui.font(13), Vector2(292, card_y + 136), "打开后：左右键逐步 · A 下一步 · B 返回阅读", ui.MUTED)
				y += 172.0
			"qa":
				ci.draw_string(ui.font(14), Vector2(0, y + 14), "问", ui.GOLD)
				ci.draw_style_box(ui.style(Color(0, 0, 0, 0), ui.GOLD, 4), Rect2(-14, y + 2, 18, 18))
				for line in item.get("lines", []):
					_draw_run_line(ci, line, Vector2(0, y), 17)
					y += 25.0
				ci.draw_string(ui.font(13), Vector2(0, y + 2), "A/Y 显示答案", ui.MUTED)
				y += 26.0
			"table":
				y = _draw_table(ci, item, y)


func _line_has_cjk(s: String) -> bool:
	for i in range(s.length()):
		if _is_cjk_char(s.substr(i, 1)):
			return true
	return false


func _line_text(line: Array) -> String:
	var out := ""
	for seg in line:
		out += String(seg[1])
	return out


func _draw_run_line(ci: CanvasItem, line: Array, pos: Vector2, size: int) -> void:
	var x := pos.x
	for seg in line:
		var style := String(seg[0])
		var text := String(seg[1])
		if text == "":
			continue
		var f := ui.font_for_style(style, size)
		ci.draw_string(f, Vector2(x, pos.y + size), text, ui.color_for_style(style))
		x += f.get_string_size(text).x


func _draw_table(ci: CanvasItem, item: Dictionary, y: float) -> float:
	var header: Array = item.get("header", [])
	var widths: Array = item.get("widths", [])
	var x0 := 0.0
	var row_y := y
	# header band
	var header_lines := 1
	for ci2 in range(widths.size()):
		header_lines = max(header_lines, _wrap_plain(String(header[ci2]) if ci2 < header.size() else "", widths[ci2] - 12, 13).size())
	var header_h := header_lines * 20 + 8.0
	ci.draw_style_box(ui.style(Color("1d2a3d"), ui.LINE, 4), Rect2(x0, row_y, min(CONTENT_WIDTH, _array_sum(widths)), header_h))
	for ci3 in range(widths.size()):
		var text := String(header[ci3]) if ci3 < header.size() else ""
		var lines := _wrap_plain(text, widths[ci3] - 12, 13)
		var ly := row_y + 4.0
		for line in lines:
			ci.draw_string(ui.font(13), Vector2(_col_x(widths, ci3) + 6, ly + 14), _line_text(line), ui.GOLD)
			ly += 20.0
	row_y += header_h
	var alt := false
	for row in item.get("rows", []):
		var cells: Array = row.get("cells", [])
		var lines_count := int(row.get("lines", 1))
		var row_h := lines_count * 20 + 4.0
		if alt:
			ci.draw_style_box(ui.style(Color("151f2e"), Color(0, 0, 0, 0), 0), Rect2(x0, row_y, min(CONTENT_WIDTH, _array_sum(widths)), row_h))
		alt = not alt
		for ci4 in range(widths.size()):
			var text2 := String(cells[ci4]) if ci4 < cells.size() else ""
			var lines2 := _wrap_plain(text2, widths[ci4] - 12, 13)
			var ly2 := row_y + 2.0
			for line2 in lines2:
				ci.draw_string(ui.font(13), Vector2(_col_x(widths, ci4) + 6, ly2 + 14), _line_text(line2), ui.TEXT)
				ly2 += 20.0
		row_y += row_h
	return row_y + 6.0


func _col_x(widths: Array, index: int) -> float:
	var x := 0.0
	for i in range(min(index, widths.size())):
		x += float(widths[i])
	return x


func _array_sum(values: Array) -> float:
	var total := 0.0
	for v in values:
		total += float(v)
	return total


# ====================================================== steps viewer =======

func _open_steps(item: Dictionary) -> void:
	var section: Dictionary = repo.get_section(max(0, current_section_index))
	# resolve the full block again from the section for all steps
	var wanted := String(item.get("id", ""))
	var found: Dictionary = {}
	for block in section.get("blocks", []):
		if String(block.get("type", "")) == "figure_steps" and String(block.get("id", "")) == wanted:
			found = block
			break
	if found.empty():
		_show_toast("未找到步进图数据")
		return
	steps_block = found
	steps_idx = 0
	_show_steps()


func _show_steps() -> void:
	_clear_screen()
	_clear_steps_cache()
	screen = "steps"
	var steps: Array = steps_block.get("steps", [])
	var count: int = steps.size()
	var title := String(steps_block.get("title", "步进图解"))
	title_text = title
	footer_text = "左右键 步进   A 下一步   B 返回阅读"
	var safe := clamp(steps_idx, 0, count - 1)
	# preload current ± 1 to keep memory low on the 1 GB device
	for delta in range(-1, 2):
		var idx := safe + delta
		if idx >= 0 and idx < count:
			_ensure_texture(String(steps[idx].get("img", "")))
	var current_img: String = String(steps[safe].get("img", ""))
	var path: String = repo.figure_path(current_img)
	var tex = load(path) if ResourceLoader.exists(path) else null
	# figures are authored on white; put them on a white page panel
	ui.panel(screen_root, Rect2(14, 58, 612, 350), Color(1, 1, 1, 1), ui.LINE, 8)
	if tex != null:
		ui.texture(screen_root, path, Rect2(16, 62, 608, 342))
	else:
		ui.label(screen_root, "图片缺失", Rect2(16, 200, 608, 60), 20, ui.RED, 1)
	var dots := StepsDots.new()
	dots.app = self
	dots.rect_position = Vector2(0, 406)
	dots.rect_size = Vector2(640, 30)
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_root.add_child(dots)
	title_text = "%s · 第%d/%d步" % [title, safe + 1, count]


class StepsDots extends Control:
	var app: Node

	func _draw() -> void:
		if app == null or not is_instance_valid(app):
			return
		var steps: Array = app.steps_block.get("steps", [])
		var count: int = steps.size()
		if count == 0:
			return
		if count > 14:
			var text := ""
			for i in range(count):
				text += "● " if i == app.steps_idx else "○ "
			app.ui.font(13)
			draw_string(app.ui.font(14), Vector2((640 - app.ui.font(14).get_string_size(text).x) / 2, 20), text, app.ui.GOLD)
			return
		var spacing := min(30.0, 560.0 / count)
		var total_w := spacing * (count - 1)
		var x0 := (640.0 - total_w) / 2.0
		for i in range(count):
			var center := Vector2(x0 + i * spacing, 14)
			if i == app.steps_idx:
				draw_circle(center, 6.0, app.ui.GOLD)
			elif i < app.steps_idx:
				draw_circle(center, 4.0, Color(app.ui.GREEN.r, app.ui.GREEN.g, app.ui.GREEN.b, 0.8))
			else:
				draw_circle(center, 4.0, Color(app.ui.MUTED.r, app.ui.MUTED.g, app.ui.MUTED.b, 0.5))


func _steps_move(direction: int) -> void:
	var count: int = steps_block.get("steps", []).size()
	if count == 0:
		return
	var next := clamp(steps_idx + direction, 0, count - 1)
	if next == steps_idx and direction > 0:
		_close_steps()
		return
	steps_idx = next
	_show_steps()


func _ensure_texture(image_name: String) -> void:
	if image_name == "" or steps_cache.has(image_name):
		return
	var path: String = repo.figure_path(image_name)
	if ResourceLoader.exists(path):
		steps_cache[image_name] = load(path)


func _clear_steps_cache() -> void:
	steps_cache.clear()


func _close_steps() -> void:
	_clear_steps_cache()
	steps_block = {}
	_show_reader()


# ====================================================== figure viewer ======

func _close_figure() -> void:
	_show_reader()


# ====================================================== quiz ===============

func _start_quiz(items: Array, scope: String) -> void:
	var valid: Array = []
	for item in items:
		if item is Dictionary and String(item.get("question", "")) != "":
			var opts: Array = item.get("options", [])
			if String(item.get("type", "mcq")) == "mcq":
				if opts.size() >= 2:
					valid.append(item)
			else:
				valid.append(item)
	if valid.empty():
		_show_toast("本节没有测验题")
		return
	quiz_items = valid.duplicate(true)
	quiz_index = 0
	quiz_correct = 0
	quiz_state = "playing"
	quiz_selected = -1
	quiz_scope = scope
	quiz_result = {}
	_show_quiz()


func _show_quiz() -> void:
	_clear_screen()
	screen = "quiz"
	title_text = "测验"
	if quiz_state == "result":
		_build_quiz_result()
		return
	if quiz_index >= quiz_items.size():
		_finish_quiz()
		return
	footer_text = "上下键 选择   A 确认   B 返回"
	var item: Dictionary = quiz_items[quiz_index]
	var kind := String(item.get("type", "mcq"))
	ui.label(screen_root, "第 %d / %d 题 · %s" % [quiz_index + 1, quiz_items.size(), "选择" if kind == "mcq" else "问答"], Rect2(28, 62, 584, 24), 14, ui.GOLD, 2)
	if kind == "mcq":
		ui.label(screen_root, String(item.get("question", "")), Rect2(40, 92, 560, 84), 19, ui.TEXT, 0, true)
		var options: Array = item.get("options", [])
		var items := []
		for index in range(options.size()):
			items.append({"text": "%s. %s" % [OPTION_LETTERS.substr(index, 1), String(options[index])], "action": "answer", "index": index, "enabled": true})
		_build_menu(items, Rect2(44, 190, 552, 40), 44, 0)
	else:
		ui.label(screen_root, String(item.get("question", "")), Rect2(40, 92, 560, 110), 19, ui.TEXT, 0, true)
		if quiz_state == "reveal_answer":
			var a_lines := _wrap_plain(String(item.get("answer", "")), 560, 15)
			var shown := ""
			for i in range(min(7, a_lines.size())):
				shown += _line_text(a_lines[i]) + "\n"
			if a_lines.size() > 7:
				shown += "……"
			ui.panel(screen_root, Rect2(30, 214, 580, 180), Color("152234"), ui.GREEN, 10)
			ui.label(screen_root, shown, Rect2(46, 224, 548, 162), 15, ui.GREEN, 0, true)
			var items2 := [
				{"text": "答对了", "action": "self_ok", "enabled": true},
				{"text": "没答上来", "action": "self_bad", "enabled": true},
			]
			_build_menu(items2, Rect2(140, 396, 360, 34), 0, 0)
		else:
			ui.label(screen_root, "想一想，按 A 显示参考答案", Rect2(40, 240, 560, 30), 15, ui.MUTED)
			menu_panels.clear()
			menu_meta.clear()
	if quiz_state == "feedback":
		_show_feedback(item)


func _show_feedback(item: Dictionary) -> void:
	var answer := String(item.get("answer", ""))
	var ok := quiz_selected == 0   # quiz_selected stores 1 if right, 0 if wrong
	ui.panel(screen_root, Rect2(30, 380, 580, 56), Color("14241f") if ok else Color("2a2220"), ui.GREEN if ok else ui.RED, 10)
	ui.label(screen_root, "答对了！" if ok else "正确答案：%s" % answer, Rect2(46, 388, 548, 40), 18, ui.GREEN if ok else ui.RED, 0, true)


func _quiz_accept() -> void:
	var item: Dictionary = quiz_items[quiz_index] if quiz_index < quiz_items.size() else {}
	var kind := String(item.get("type", "mcq"))
	if quiz_state == "feedback":
		quiz_index += 1
		quiz_selected = -1
		quiz_state = "playing"
		_show_quiz()
		return
	if kind == "reveal" and quiz_state == "playing":
		quiz_state = "reveal_answer"
		_show_quiz()
		return
	if not menu_panels.empty():
		_activate_menu()


func _answer_question(index: int) -> void:
	if quiz_state != "playing" or quiz_index >= quiz_items.size():
		return
	var item: Dictionary = quiz_items[quiz_index]
	var options: Array = item.get("options", [])
	quiz_selected = 1 if (index >= 0 and index < options.size() and String(options[index]) == String(item.get("answer", ""))) else 0
	if quiz_selected == 1:
		quiz_correct += 1
	progress.record_srs(String(item.get("id", "")), String(item.get("section", "")), quiz_selected == 1)
	quiz_state = "feedback"
	_show_quiz()


func _self_assess(correct: bool) -> void:
	if quiz_index >= quiz_items.size():
		return
	var item: Dictionary = quiz_items[quiz_index]
	if correct:
		quiz_correct += 1
	progress.record_srs(String(item.get("id", "")), String(item.get("section", "")), correct)
	quiz_index += 1
	quiz_selected = -1
	quiz_state = "playing"
	_show_quiz()


func _finish_quiz() -> void:
	var total := quiz_items.size()
	var score := 0 if total == 0 else int(round(100.0 * float(quiz_correct) / float(total)))
	quiz_result = {"correct": quiz_correct, "total": total, "score": score}
	progress.record_quiz(quiz_scope, score)
	quiz_state = "result"
	_show_quiz()


func _build_quiz_result() -> void:
	var total := int(quiz_result.get("total", 0))
	var correct := int(quiz_result.get("correct", 0))
	var score := int(quiz_result.get("score", 0))
	footer_text = "A 确认   B 返回"
	var is_section := quiz_scope.count("_") > 0
	var scope_label := quiz_scope
	if quiz_scope == "review":
		scope_label = "错题复习"
	elif quiz_scope == "glossary":
		scope_label = "术语测验"
	elif is_section:
		scope_label = "本节测验"
	else:
		scope_label = "章节测验"
	ui.label(screen_root, "%s · %d%%" % [scope_label, score], Rect2(40, 96, 300, 60), 34, ui.GOLD if score >= 60 else ui.RED)
	ui.label(screen_root, "答对 %d / %d" % [correct, total], Rect2(340, 108, 260, 40), 22, ui.TEXT)
	var verdict := "通过！继续加油。" if score >= 60 else "未到 60 分，建议重读本文再试。"
	ui.label(screen_root, verdict, Rect2(40, 164, 560, 30), 16, ui.GREEN if score >= 60 else ui.MUTED)
	var items := [
		{"text": "重新测验", "action": "retry", "enabled": true},
		{"text": "回到首页", "action": "home", "enabled": true},
	]
	if quiz_scope.begins_with("ch"):
		items.insert(1, {"text": "继续阅读", "action": "reader_back", "enabled": true})
	_build_menu(items, Rect2(180, 240, 360, 42), 48, 0)


func _show_result(section_id: String, correct: int, total: int, reading_only: bool) -> void:
	_clear_screen()
	screen = "result"
	title_text = "本节完成"
	footer_text = "A 确认   B 返回"
	var detail := "已读完本节，进度已保存。"
	if not reading_only:
		detail = "测验完成。"
	ui.label(screen_root, detail, Rect2(50, 140, 540, 60), 23, ui.GREEN, 1, true)
	_build_menu([
		{"text": "下一节", "action": "next_section", "enabled": current_section_index + 1 < repo.section_count()},
		{"text": "回到小节列表", "action": "sections", "enabled": true},
		{"text": "回到首页", "action": "home", "enabled": true},
	], Rect2(180, 230, 360, 44), 50, 0)


# ====================================================== review / glossary ==

func _start_review() -> void:
	var due: Array = progress.due_quiz_ids()
	var items: Array = []
	for item in repo.quiz_items:
		if due.has(String(item.get("id", ""))):
			items.append(item)
	if items.empty():
		_show_toast("今天没有到期的复习题")
		return
	items.shuffle()
	_start_quiz(items.slice(0, min(12, items.size()) - 1), "review")


func _show_glossary() -> void:
	_clear_screen()
	screen = "glossary"
	glossary_index = -1
	title_text = "术语表"
	footer_text = "上下键 选择   A 查看   X 术语测验   B 返回   左右键 翻页"
	var gsize: int = repo.glossary.size()
	var start := glossary_page * PAGE_SIZE
	var items := []
	for index in range(start, min(start + PAGE_SIZE, gsize)):
		var entry: Dictionary = repo.glossary[index]
		items.append({
			"text": "%s  ·  %s" % [String(entry.get("en", "")), String(entry.get("cn", ""))],
			"action": "gloss", "index": index, "enabled": true,
		})
	_build_menu(items, Rect2(28, 68, 584, 40), 44, 0)
	var pages := max(1, int(ceil(float(gsize) / float(PAGE_SIZE))))
	ui.label(screen_root, "第 %d / %d 页" % [glossary_page + 1, pages], Rect2(420, 452, 192, 22), 13, ui.MUTED, 2)


func _show_glossary_detail(index: int) -> void:
	_clear_screen()
	screen = "glossary"
	glossary_index = index
	if index < 0 or index >= repo.glossary.size():
		_show_glossary()
		return
	var entry: Dictionary = repo.glossary[index]
	title_text = "术语"
	footer_text = "B 返回列表"
	ui.panel(screen_root, Rect2(60, 130, 520, 200), ui.PANEL, ui.LINE, 14)
	ui.label(screen_root, String(entry.get("en", "")), Rect2(80, 160, 480, 50), 30, ui.GOLD)
	ui.label(screen_root, String(entry.get("cn", "")), Rect2(80, 226, 480, 50), 26, ui.TEXT)
	ui.label(screen_root, "第 %d / %d 条" % [index + 1, repo.glossary.size()], Rect2(80, 286, 480, 30), 14, ui.MUTED)


func _start_glossary_quiz() -> void:
	var items: Array = repo.quiz_by_section.get("glossary", [])
	if items.empty():
		_show_toast("术语题库为空")
		return
	_start_quiz(items, "glossary")


# ====================================================== static screens =====

func _show_controls() -> void:
	_clear_screen()
	screen = "controls"
	title_text = "操作说明"
	footer_text = "B 返回首页"
	var rows := [
		["十字键 / 左摇杆", "上下选择，左右翻页 / 步进"],
		["A", "确认 / 下一页 / 显示问答"],
		["B", "返回上一级"],
		["X", "进入步进图解（PC 键盘 X 或 L 均可）"],
		["Y", "显示本页问答题答案"],
		["L1 / R1", "上一页 / 下一页"],
		["Select", "回到首页"],
		["Start", "退出到 PortMaster"],
	]
	for index in range(rows.size()):
		var y := 66 + index * 46
		ui.panel(screen_root, Rect2(48, y, 544, 38), ui.PANEL, ui.LINE, 8)
		ui.label(screen_root, rows[index][0], Rect2(64, y + 3, 220, 32), 17, ui.GOLD)
		ui.label(screen_root, rows[index][1], Rect2(290, y + 3, 290, 32), 17, ui.TEXT)


func _show_about() -> void:
	_clear_screen()
	screen = "about"
	title_text = "关于与版权"
	footer_text = "B 返回首页"
	var meta: Dictionary = repo.meta
	var lines := [
		["本应用", "Algo Buddy · R36S 离线算法学习"],
		["内容来源", "%s（%s）" % [String(meta.get("sourceTitle", "Hello 算法")), String(meta.get("source", "hello-algo"))]],
		["作者", String(meta.get("author", "krahets"))],
		["网址", String(meta.get("sourceUrl", "https://github.com/krahets/hello-algo"))],
		["授权", String(meta.get("license", "CC BY-NC-SA 4.0"))],
		["说明", "内容版权归原作者所有，本应用为个人学习用途的离线阅读器。"],
		["收录", "%d 章 %d 节 · 步进图 %d 组 · 术语 %d 条" % [repo.chapter_count(), repo.section_count(), _count_step_blocks(), repo.glossary.size()]],
	]
	for index in range(lines.size()):
		var y := 72 + index * 50
		ui.label(screen_root, lines[index][0], Rect2(40, y, 110, 44), 15, ui.GOLD)
		var label := ui.label(screen_root, lines[index][1], Rect2(158, y, 452, 46), 14, ui.TEXT, 0, true)
		label.autowrap = true


func _count_step_blocks() -> int:
	var count := 0
	for section in repo.sections:
		for block in section.get("blocks", []):
			if String(block.get("type", "")) == "figure_steps":
				count += 1
	return count


func _show_reset_confirm() -> void:
	_clear_screen()
	screen = "reset"
	title_text = "确认清除"
	footer_text = "A 确认清除   B 取消"
	ui.panel(screen_root, Rect2(100, 150, 440, 190), Color("2a2220"), ui.RED, 16)
	ui.label(screen_root, "确定清除全部学习记录？", Rect2(120, 178, 400, 50), 23, ui.TEXT, 1)
	ui.label(screen_root, "阅读进度、测验成绩与复习队列都会被删除", Rect2(120, 232, 400, 32), 15, ui.MUTED, 1)
	ui.label(screen_root, "A 确定    B 取消", Rect2(120, 288, 400, 32), 19, ui.GOLD, 1)


# ====================================================== dispatch ===========

func _activate_menu() -> void:
	if menu_index < 0 or menu_index >= menu_meta.size():
		return
	var item: Dictionary = menu_meta[menu_index]
	if not bool(item.get("enabled", true)):
		return
	match String(item.get("action", "")):
		"continue":
			var cont: Dictionary = repo.section_by_id(progress.current_section_id())
			if cont.empty():
				cont = repo.get_section(_first_unread_index())
			_open_section(String(cont.get("id", "")))
		"chapters":
			chapters_mode = "read"
			_show_chapters()
		"review": _start_review()
		"glossary": _show_glossary()
		"gloss": _show_glossary_detail(int(item.get("index", 0)))
		"gloss_quiz": _start_glossary_quiz()
		"controls": _show_controls()
		"about": _show_about()
		"reset": _show_reset_confirm()
		"chapter":
			current_chapter_index = int(item.get("index", 0))
			section_page = 0
			if chapters_mode == "quiz":
				var items: Array = repo.quiz_for_chapter(_current_chapter_id())
				if items.empty():
					_show_toast("本章暂无测验题")
					return
				_start_quiz(items.slice(0, min(12, items.size()) - 1), _current_chapter_id())
			else:
				_show_sections()
		"section": _open_section(String(item.get("section_id", "")))
		"answer": _answer_question(int(item.get("index", 0)))
		"self_ok": _self_assess(true)
		"self_bad": _self_assess(false)
		"retry":
			var scope := quiz_scope
			var items2: Array = []
			if scope == "review":
				_start_review()
				return
			elif scope == "glossary":
				items2 = repo.quiz_by_section.get("glossary", [])
			elif scope.begins_with("ch") and scope.count("_") == 0:
				items2 = repo.quiz_for_chapter(scope)
			else:
				items2 = repo.quiz_for_section(scope)
			if scope == "" or (scope.begins_with("ch") and scope.count("_") == 0) or scope == "review" or scope == "glossary":
				items2 = items2.slice(0, min(12, items2.size()) - 1)
			_start_quiz(items2, scope)
		"reader_back": _show_reader()
		"sections": _show_sections()
		"next_section":
			current_section_index = min(repo.section_count() - 1, current_section_index + 1)
			_open_section(String(repo.get_section(current_section_index).get("id", "")))
		"home": _show_home()
