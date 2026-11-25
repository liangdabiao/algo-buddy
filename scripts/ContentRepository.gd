extends Node

# Loads data/content.json (generated from the hello-algo book by
# tools/extract_content.py) and exposes chapters / sections / quiz / glossary.

var content: Dictionary = {}
var chapters: Array = []
var sections: Array = []
var sections_by_id: Dictionary = {}
var sections_by_chapter: Dictionary = {}
var quiz_by_section: Dictionary = {}
var quiz_items: Array = []
var glossary: Array = []
var meta: Dictionary = {}


func _ready() -> void:
	var file := File.new()
	if file.open("res://data/content.json", File.READ) != OK:
		push_error("Could not open bundled book content")
		return
	content = JSON.parse(file.get_as_text()).result
	file.close()
	meta = content.get("meta", {})
	chapters = content.get("chapters", [])
	glossary = content.get("glossary", [])
	quiz_items = content.get("quiz", [])
	for chapter in chapters:
		sections_by_chapter[String(chapter.get("id", ""))] = []
	for section in content.get("sections", []):
		var section_id := String(section.get("id", ""))
		sections.append(section)
		sections_by_id[section_id] = section
		var chapter_id := String(section.get("chapter", ""))
		if sections_by_chapter.has(chapter_id):
			sections_by_chapter[chapter_id].append(section)
	for item in quiz_items:
		var key := String(item.get("section", ""))
		if not quiz_by_section.has(key):
			quiz_by_section[key] = []
		quiz_by_section[key].append(item)


func chapter_count() -> int:
	return chapters.size()


func get_chapter(index: int) -> Dictionary:
	if index < 0 or index >= chapters.size():
		return {}
	return chapters[index]


func section_count() -> int:
	return sections.size()


func get_section(index: int) -> Dictionary:
	if index < 0 or index >= sections.size():
		return {}
	return sections[index]


func section_by_id(section_id: String) -> Dictionary:
	return sections_by_id.get(section_id, {})


func sections_for_chapter(chapter_id: String) -> Array:
	return sections_by_chapter.get(chapter_id, [])


func quiz_for_section(section_id: String) -> Array:
	return quiz_by_section.get(section_id, [])


func quiz_for_chapter(chapter_id: String) -> Array:
	var result: Array = []
	for section_id in sections_by_chapter.get(chapter_id, []):
		for item in quiz_for_section(String(section_id.get("id", ""))):
			result.append(item)
	return result


func figure_path(image_name: String) -> String:
	return "res://assets/figures/%s.png" % image_name


func thumb_path(image_name: String) -> String:
	return "res://assets/figures/%s_thumb.png" % image_name


func cover_path(chapter: Dictionary) -> String:
	return "res://assets/covers/%s.png" % String(chapter.get("cover", ""))
