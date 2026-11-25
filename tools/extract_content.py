#!/usr/bin/env python3
"""Extract the Hello 算法 (hello-algo) book into a compact JSON pack for the
offline R36S handheld app.

Source: https://github.com/krahets/hello-algo (docs/, licensed CC BY-NC-SA 4.0)
Code corpus: a local checkout of the same repo's codes/python/ folder.

The generated data/content.json is what the Godot app consumes; no mkdocs /
Node.js / browser is needed on the device.

Usage:
  python tools/extract_content.py                 # build from the cached repo
  python tools/extract_content.py --chapters 11   # subset (prototyping)
  python tools/extract_content.py --fetch         # sparse-clone upstream first

Output schema (data/content.json):
  meta       provenance + license attribution
  chapters   ordered chapter list (nav order), each with section ids
  sections   one entry per article; blocks[] is the reading flow
  glossary   EN/CN terminology pairs
  quiz       reveal (Q&A) + generated MCQ items, keyed by section
Block types: h2 h3 para list figure figure_steps code tip qa table.
"""

from __future__ import annotations

import argparse
import html
import json
import random
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # algo-buddy/
WORKSPACE = ROOT.parent                                  # r36s-demo-main/
DEFAULT_REPO = WORKSPACE / ".build" / "hello-algo-src" / "repo"
DEFAULT_CODES = Path("D:/hello-algo-main/codes")
OUTPUT = ROOT / "data" / "content.json"
UPSTREAM_URL = "https://github.com/krahets/hello-algo.git"

SKIP_CHAPTERS = {"chapter_reference", "chapter_paperbook"}

# ----------------------------------------------------------------------------
# Math linearization: turn $...$ TeX snippets into plain readable text.
# ---------------------------------------------------------------------------

SUPERSCRIPTS = {
    # Only glyphs DengXian actually contains; everything else falls back to
    # ASCII (x^2 style) so the CJK subset never misses a glyph.
    "2": "²",
    "3": "³",
}
SUBSCRIPTS = {}

MATH_SYMBOLS = [
    (r"\dots", "…"), (r"\cdots", "⋯"), (r"\ldots", "…"),
    (r"\\", "；"),                                # LaTeX row separator (two chars)
    (r"\cdot", "·"), (r"\times", "×"), (r"\div", "÷"),
    (r"\log", "log"), (r"\ln", "ln"), (r"\lg", "lg"),
    (r"\min", "min"), (r"\max", "max"), (r"\gcd", "gcd"),
    (r"\sum", "Σ"), (r"\prod", "Π"),
    (r"\infty", "∞"), (r"\% ", "%"),
    (r"\leq", "≤"), (r"\le", "≤"), (r"\geq", "≥"), (r"\ge", "≥"),
    (r"\neq", "≠"), (r"\ne", "≠"), (r"\approx", "≈"), (r"\sim", "∼"),
    (r"\pm", "±"), (r"\to", "→"), (r"\rightarrow", "→"),
    (r"\leftarrow", "←"), (r"\Rightarrow", "→"),
    (r"\lfloor", "["), (r"\rfloor", "]"), (r"\lceil", "["), (r"\rceil", "]"),
    (r"\in", "∈"), (r"\forall", "∀"), (r"\exists", "∃"),
    (r"\Omega", "Ω"), (r"\omega", "ω"), (r"\Theta", "Θ"), (r"\theta", "θ"),
    (r"\Delta", "Δ"), (r"\delta", "δ"), (r"\alpha", "α"), (r"\beta", "β"),
    (r"\gamma", "γ"), (r"\pi", "π"), (r"\lambda", "λ"), (r"\mu", "μ"),
    (r"\sigma", "σ"), (r"\rho", "ρ"), (r"\tau", "τ"), (r"\phi", "φ"),
    (r"\varphi", "φ"), (r"\epsilon", "ε"), (r"\varepsilon", "ε"),
    (r"\eta", "η"), (r"\nu", "ν"), (r"\xi", "ξ"), (r"\kappa", "κ"),
    (r"\left", ""), (r"\right", ""), (r"\,", " "), (r"\;", " "), (r"\:", " "),
    (r"\!", ""), (r"\quad", " "), (r"\qquad", "  "),
    (r"\%", "%"), (r"\_", "_"), (r"\#", "#"), (r"\$", "$"),
    (r"\{", "{"), (r"\}", "}"),
]


class Extractor:
    def __init__(self, repo: Path, codes: Path):
        self.repo = repo
        self.codes = codes
        self.warnings: list[str] = []
        self.math_fallbacks: list[str] = []
        self.images: dict[str, str] = {}      # repo-relative svg path -> png name
        self.quiz_items: list[dict] = []

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    # ------------------------------------------------------------------ math
    def linearize_math(self, s: str) -> str:
        out = s.strip()
        # \frac{a}{b} -> (a / b)
        for _ in range(6):
            m = re.search(r"\\frac\{([^{}]*)\}\{([^{}]*)\}", out)
            if not m:
                break
            out = out[: m.start()] + f"({m.group(1)}/{m.group(2)})" + out[m.end():]
        # \sqrt{a} -> √(a)
        for _ in range(6):
            m = re.search(r"\\sqrt\{([^{}]*)\}", out)
            if not m:
                break
            out = out[: m.start()] + f"√({m.group(1)})" + out[m.end():]
        # \text{...} / \mathrm{...} keep content; cases env stripped
        out = re.sub(r"\\(?:text|mathrm|mathcal|mathbf|operatorname)\{([^{}]*)\}", r"\1", out)
        out = re.sub(r"\\(?:begin|end)\{[^{}]*\}", "", out)
        for cmd, rep in MATH_SYMBOLS:
            out = out.replace(cmd, rep)
        # superscripts / subscripts
        out = re.sub(r"\^\{([^{}]*)\}", lambda m: self._super_group(m.group(1)), out)
        out = re.sub(r"\^([0-9a-zA-Z])", lambda m: self._super_group(m.group(1)), out)
        out = re.sub(r"_\{([^{}]*)\}", lambda m: "_" + m.group(1), out)
        out = re.sub(r"_([0-9a-zA-Z])", lambda m: "_" + m.group(1), out)
        out = re.sub(r"\\[A-Za-z]+", " ", out)      # any unknown command
        out = out.replace("\u2061", "").replace("\u2062", "")
        out = re.sub(r"\s+", " ", out).strip()
        if "\\" in out:
            self.math_fallbacks.append(s)
        return out

    @staticmethod
    def _super_group(group: str) -> str:
        mapped = "".join(SUPERSCRIPTS.get(ch, "") for ch in group)
        if len(mapped) == len(group):
            return mapped
        return "^(" + group + ")"

    # ----------------------------------------------------------- inline runs
    def _mathify(self, s: str) -> str:
        """Linearize $...$ / $$...$$ inside an already-styled chunk; drop stray $."""
        s = re.sub(r"\$\$(.+?)\$\$", lambda m: self.linearize_math(m.group(1)), s, flags=re.S)
        s = re.sub(r"\$([^$]+?)\$", lambda m: self.linearize_math(m.group(1)), s)
        s = s.replace("$", "")
        # Safety net: bare LaTeX commands leaked by unbalanced delimiters.
        if "\\" in s:
            before = s
            out = re.sub(r"\\(?:begin|end)\{[^{}]*\}", "", s)
            for cmd, rep in MATH_SYMBOLS:
                out = out.replace(cmd, rep)
            out = re.sub(r"\\[A-Za-z]+", " ", out)
            out = out.replace("\u2061", "").replace("\u2062", "")
            s = out if "\\" not in out else before
        return s.replace("\u2061", "").replace("\u2062", "")

    def parse_inline(self, text: str) -> list[dict]:
        """Split inline markdown into styled runs: t=plain b=bold c=code m=math."""
        text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)          # stray images
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)      # links -> text
        text = re.sub(r"<u>(.*?)</u>", r"**\1**", text)           # underline -> bold
        text = re.sub(r"<[^>]+>", "", text)                       # other html tags
        text = html.unescape(text).replace("&nbsp;", " ")
        # Display math first so its delimiters cannot unbalance $ pairing.
        text = re.sub(r"\$\$(.+?)\$\$", lambda m: "\x00" + self.linearize_math(m.group(1)) + "\x00",
                      text, flags=re.S)
        runs: list[dict] = []
        pos = 0
        pattern = re.compile(r"(\*\*(.+?)\*\*|`([^`]+)`|\x00([^\x00]+)\x00|\$([^$]+)\$)")
        for m in pattern.finditer(text):
            if m.start() > pos:
                runs.append({"s": "t", "t": self._mathify(self._clean(text[pos:m.start()]))})
            if m.group(2) is not None:
                runs.append({"s": "b", "t": self._mathify(self._clean(m.group(2)))})
            elif m.group(3) is not None:
                runs.append({"s": "c", "t": m.group(3)})
            elif m.group(4) is not None:
                runs.append({"s": "m", "t": m.group(4)})
            else:
                runs.append({"s": "m", "t": self.linearize_math(m.group(5))})
            pos = m.end()
        if pos < len(text):
            runs.append({"s": "t", "t": self._mathify(self._clean(text[pos:]))})
        return [r for r in runs if r["t"]]

    @staticmethod
    def _clean(s: str) -> str:
        s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)                    # nested bold
        s = s.replace("`", "")
        return re.sub(r"  +", " ", s)

    def join_runs_plain(self, runs: list[dict]) -> str:
        return "".join(r["t"] for r in runs)

    # --------------------------------------------------------------- figures
    def figure_name(self, article_dir: Path, img_rel: str) -> str:
        """Map a markdown image path to a flat png name; register the svg."""
        if img_rel.startswith("../assets/"):
            repo_path = self.repo / "docs" / img_rel[3:]
        else:
            repo_path = (article_dir / img_rel).resolve()
        try:
            rel = str(repo_path.resolve().relative_to(self.repo)).replace("\\", "/")
        except ValueError:
            self.warn(f"image outside repo: {img_rel}")
            return ""
        stem = Path(rel).stem
        if rel.startswith("docs/assets/covers/"):
            name = f"cover_{stem}"
        else:
            chapter = rel.split("/")[1] if rel.count("/") >= 2 else "misc"
            name = f"fig_{chapter}_{stem}"
        if rel in self.images and self.images[rel] != name:
            self.warn(f"duplicate image name: {rel}")
        self.images[rel] = name
        return name

    # ------------------------------------------------------------------ code
    def extract_python(self, chapter_dir: str, file: str, cls: str, funcs: str) -> str:
        path = self.codes / "python" / chapter_dir / f"{file}.py"
        if not path.exists():
            self.warn(f"code file missing: {path}")
            return ""
        lines = path.read_text(encoding="utf-8").splitlines()
        # Drop the file header docstring.
        while lines and (lines[0].strip() == '"""' or lines[0].strip() == ""):
            if lines[0].strip() == '"""':
                lines = lines[1:]
                while lines and lines[0].strip() != '"""':
                    lines = lines[1:]
                lines = lines[1:]
            else:
                lines = lines[1:]
        # Docs markers use snake_case; Python classes are PascalCase.
        class_variants = [cls]
        if cls:
            pascal = "".join(w.capitalize() for w in cls.split("_"))
            if pascal not in class_variants:
                class_variants.append(pascal)
        names = [f.strip() for f in funcs.split(",") if f.strip()]
        if cls and not names:
            for variant in class_variants:
                code = self._extract_block(lines, rf"class {re.escape(variant)}\b", 0)
                if code:
                    return code
            self.warn(f"class not found: {cls} in {path.name}")
            return ""
        indent = 0 if not cls else 4
        parts = [self._extract_block(lines, rf"def {re.escape(n)}\b", indent) for n in names]
        if cls and any(not p for p in parts):
            # method inside a class not found under its stated name: retry variants
            for variant in class_variants[1:]:
                cls_lines = self._extract_block(lines, rf"class {re.escape(variant)}\b", 0)
                if not cls_lines:
                    continue
                cls_body = cls_lines.splitlines()
                parts = [self._extract_block(cls_body, rf"def {re.escape(n)}\b", 4) for n in names]
                break
        parts = [p for p in parts if p]
        return "\n\n".join(parts)

    @staticmethod
    def _extract_block(lines: list[str], pattern: str, indent: int) -> str:
        rx = re.compile(rf"^[ ]{{{indent}}}{pattern}")
        for i, line in enumerate(lines):
            if not rx.match(line):
                continue
            out = [line]
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
                    break
                if nxt.strip().startswith('"""Driver Code"""'):
                    break
                out.append(nxt)
                j += 1
            while out and not out[-1].strip():
                out.pop()
            return "\n".join(out)
        return ""

    def expand_src_marker(self, body: str, chapter_dir: str) -> str:
        codes_out = []
        for m in re.finditer(r"\[file\]\{([^}]*)\}-\[class\]\{([^}]*)\}-\[func\]\{([^}]*)\}", body):
            code = self.extract_python(chapter_dir, m.group(1), m.group(2), m.group(3))
            if code:
                codes_out.append(code)
            else:
                self.warn(f"empty code extraction: {m.group(0)} ({chapter_dir})")
        return "\n\n".join(codes_out)

    def expand_snippet(self, name: str, chapter_dir: str, article: str) -> str:
        path = self.codes / "snippets" / chapter_dir / f"{article}.md"
        if not path.exists():
            self.warn(f"snippet library missing: {path}")
            return ""
        text = path.read_text(encoding="utf-8")
        # Sections are delimited by <!-- [snippet]{name} --> comments.
        blocks = re.split(r"<!--\s*\[snippet\]\{([^}]*)\}\s*-->", text)
        # blocks: [pre, name0, body0, name1, body1, ...]
        body = ""
        for k in range(1, len(blocks) - 1, 2):
            if blocks[k].strip() == name:
                body = blocks[k + 1]
                break
        if not body:
            self.warn(f"snippet '{name}' not in {path.name}")
            return ""
        m = re.search(r"```python[^\n]*\n(.*?)```", body, re.S)
        if not m:
            self.warn(f"no python block in snippet {name}")
            return ""
        return m.group(1).rstrip()

    # ----------------------------------------------------------- markdown ---
    def _parse_lines(self, lines: list[str], md_path: Path, chapter_dir: str) -> tuple[list[dict], list[dict]]:
        """Parse article lines into (blocks, qa_items). qa_items also feed the quiz."""
        blocks: list[dict] = []
        qa_items: list[dict] = []
        para: list[str] = []
        pending_question: list[str] = []      # exercise question awaiting an answer

        def flush_para() -> None:
            if para:
                runs = self.parse_inline(self._join_soft(para))
                if runs:
                    blocks.append({"type": "para", "runs": runs})
                    pending_question.append(self.join_runs_plain(runs))
                para.clear()

        i = 0
        n = len(lines)
        while i < n:
            raw = lines[i]
            stripped = raw.strip()
            # ---- tab run (figure steps)
            m = re.match(r'^=== "(.+)"\s*$', raw)
            if m:
                flush_para()
                tabs, i = self._collect_tabs(lines, i)
                self._emit_tabs(tabs, blocks, md_path, chapter_dir, pending_question)
                continue
            # ---- fenced code
            if stripped.startswith("```"):
                flush_para()
                fence_kind = stripped[3:].strip()
                body: list[str] = []
                i += 1
                while i < n and not lines[i].strip().startswith("```"):
                    body.append(lines[i])
                    i += 1
                i += 1  # closing fence
                self._emit_fence(fence_kind, body, blocks, chapter_dir, pending_question,
                                 article=md_path.stem)
                continue
            # ---- collapsibles
            if stripped.startswith("???"):
                flush_para()
                body_lines, i = self._collect_indented(lines, i + 1)
                if "pythontutor" in stripped:
                    continue
                if "success" in stripped or "参考答案" in stripped:
                    self._emit_exercise_answer(body_lines, blocks, qa_items, md_path, pending_question)
                else:
                    self._emit_exercise_answer(body_lines, blocks, qa_items, md_path, pending_question)
                continue
            # ---- admonitions
            if stripped.startswith("!!!"):
                flush_para()
                tip_title = ""
                mm = re.match(r'!!!\s+\S+\s+"(.*)"', stripped)
                if mm:
                    tip_title = self._mathify(self._clean(mm.group(1)))
                body_lines, i = self._collect_indented(lines, i + 1)
                runs = self.parse_inline(self._join_soft(body_lines))
                if runs:
                    blocks.append({"type": "tip", "title": tip_title, "runs": runs})
                continue
            # ---- html comments
            if stripped.startswith("<!--"):
                while i < n and "-->" not in lines[i]:
                    i += 1
                i += 1
                continue
            # ---- headings
            mh = re.match(r"^(#{2,3})\s+(.*)$", stripped)
            if mh:
                flush_para()
                runs = self.parse_inline(mh.group(2))
                label = self.join_runs_plain(runs)
                blocks.append({"type": "h2" if len(mh.group(1)) == 2 else "h3", "runs": runs})
                pending_question.append("#" * len(mh.group(1)) + " " + label)
                i += 1
                continue
            if stripped.startswith("# "):
                # article H1 duplicates the chrome title; drop it
                flush_para()
                i += 1
                continue
            # ---- standalone image
            mi = re.match(r"^!\[([^\]]*)\]\(([^)\s]+)\)\s*$", stripped)
            if mi:
                flush_para()
                img = self.figure_name(md_path.parent, mi.group(2))
                alt = mi.group(1)
                stem = Path(mi.group(2)).stem
                caption = "" if alt == stem else alt
                if img:
                    blocks.append({"type": "figure", "img": img, "caption": caption})
                i += 1
                continue
            # ---- tables
            if stripped.startswith("|"):
                flush_para()
                tbl, i = self._collect_table(lines, i)
                if tbl:
                    blocks.append(tbl)
                    pending_question.append(json.dumps(tbl, ensure_ascii=False)[:200])
                continue
            # ---- lists
            ml = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", raw)
            if ml:
                flush_para()
                items, i = self._collect_list(lines, i, md_path)
                if items:
                    ordered = bool(re.match(r"\d+\.", ml.group(2)))
                    blocks.append({"type": "list", "ordered": ordered, "items": items})
                    for it in items:
                        pending_question.append(self.join_runs_plain(it))
                continue
            # ---- Q&A marker (summary pages)
            mq = re.match(r"^\*\*Q\*\*[：:]\s*(.*)$", stripped)
            if mq:
                flush_para()
                q_runs = self.parse_inline(mq.group(1))
                qa_items.append({"question": self.join_runs_plain(q_runs), "answer_runs": []})
                blocks.append({"type": "qa", "question_runs": q_runs, "answer_runs": [], "qindex": len(qa_items) - 1})
                pending_question.clear()
                i += 1
                continue
            # ---- blank
            if not stripped:
                flush_para()
                i += 1
                continue
            # ---- paragraph text (accumulate soft-wrapped lines)
            para.append(stripped)
            i += 1

        flush_para()
        # qa answers: everything recorded between qa markers belongs to the last qa
        self._resolve_qa_answers(blocks, qa_items)
        return blocks, qa_items

    @staticmethod
    def _join_soft(lines: list[str]) -> str:
        out = ""
        for ln in lines:
            ln = ln.strip()
            if not ln:
                continue
            if out:
                prev = out[-1]
                nxt = ln[0]
                sep = "" if _is_cjk(prev) and _is_cjk(nxt) else " "
                out += sep + ln
            else:
                out = ln
        return out

    def _collect_tabs(self, lines: list[str], i: int) -> tuple[list[tuple[str, list[str]]], int]:
        tabs = []
        n = len(lines)
        while i < n:
            m = re.match(r'^=== "(.+)"\s*$', lines[i])
            if not m:
                break
            i += 1
            body: list[str] = []
            while i < n and (lines[i].startswith("    ") or not lines[i].strip()):
                if lines[i].strip():
                    body.append(lines[i][4:])
                i += 1
            tabs.append((m.group(1), body))
        return tabs, i

    def _emit_tabs(self, tabs, blocks, md_path, chapter_dir, pending_question) -> None:
        # figure_steps: every tab holds exactly one image and nothing else.
        ok = bool(tabs) and len(tabs) >= 2
        parsed = []
        for label, body in tabs:
            nonempty = [b.strip() for b in body if b.strip()]
            imgs = [b for b in nonempty if b.startswith("![")]
            others = [b for b in nonempty if not b.startswith("![")]
            if len(imgs) != 1 or others:
                ok = False
                break
            m = re.match(r"^!\[([^\]]*)\]\(([^)\s]+)\)\s*$", imgs[0])
            if not m:
                ok = False
                break
            parsed.append((label, m))
        if ok and len(tabs) >= 2:
            steps = []
            first_alt = ""
            for label, im in parsed:
                img = self.figure_name(md_path.parent, im.group(2))
                if not img:
                    ok = False
                    break
                alt = im.group(1)
                if not first_alt and alt and alt != Path(im.group(2)).stem:
                    first_alt = alt
                num = re.sub(r"[^\d]", "", label)
                steps.append({"n": int(num) if num else len(steps) + 1, "img": img})
            if ok:
                nums = [s["n"] for s in steps]
                if nums == sorted(nums) and nums[0] >= 1 and len(nums) <= 20:
                    title = first_alt or "步进图解"
                    blocks.append({
                        "type": "figure_steps",
                        "id": f"fs_{len(blocks)}_{abs(hash(str(md_path))) % 9973}",
                        "title": title,
                        "steps": steps,
                        "count": len(steps),
                    })
                    pending_question.append(f"[步进图 {title} {len(steps)} 步]")
                    return
        # generic fallback: emit tabs as labelled sub-sections
        for label, body in tabs:
            blocks.append({"type": "h3", "runs": [{"s": "t", "t": label}]})
            sub, _ = self._parse_lines(body, md_path, chapter_dir)
            blocks.extend(sub)

    # small helper so tabs / indent blocks reuse the same line parser
    def parse_markdown(self, md_path: Path, chapter_dir: str):
        lines = md_path.read_text(encoding="utf-8").splitlines()
        return self._parse_lines(lines, md_path, chapter_dir)

    def _emit_fence(self, kind: str, body: list[str], blocks, chapter_dir, pending_question,
                    article: str = "") -> None:
        text = "\n".join(body)
        if kind == "src":
            code = self.expand_src_marker(text, chapter_dir)
            if code:
                blocks.append({"type": "code", "lang": "python", "text": code})
                pending_question.append("[代码]")
            return
        if kind == "snippet":
            name = text.strip()
            code = self.expand_snippet(name, chapter_dir, article)
            if code:
                blocks.append({"type": "code", "lang": "python", "text": code})
                pending_question.append("[代码]")
            return
        if kind in ("", "text", "shell", "bash", "plain"):
            if text.strip():
                blocks.append({"type": "code", "lang": "text", "text": text.rstrip()})
                pending_question.append("[代码]")
            return
        self.warn(f"unknown fence '{kind}' in {chapter_dir}")

    def _emit_exercise_answer(self, body_lines, blocks, qa_items, md_path, pending_question) -> None:
        """Turn a ??? success block into a qa reveal; question = accumulated text."""
        question = self._join_soft(pending_question).strip()
        pending_question.clear()
        body_text = self._join_soft(body_lines)
        answer_runs = self.parse_inline(body_text)
        if not answer_runs:
            return
        if not question:
            question = "参考答案"
        blocks.append({"type": "qa", "question_runs": self.parse_inline(question),
                       "answer_runs": answer_runs})
        qa_items.append({"question": question, "answer": self.join_runs_plain(answer_runs)})

    def _resolve_qa_answers(self, blocks, qa_items) -> None:
        """Summary-page Q&A: paragraphs after a qa block are its answer (absorbed)."""
        last = None
        absorbed: list[int] = []
        for bi, b in enumerate(blocks):
            if b.get("type") == "qa":
                last = b
            elif last is not None and b.get("type") == "para":
                last["answer_runs"].extend(b["runs"])
                last["answer_runs"].append({"s": "t", "t": " "})
                absorbed.append(bi)
        for bi in reversed(absorbed):
            blocks.pop(bi)
        for b in blocks:
            if b.get("type") != "qa":
                continue
            idx = b.pop("qindex", None)
            item = qa_items[idx] if idx is not None and idx < len(qa_items) else None
            if item is not None and not item.get("answer"):
                item["answer"] = self.join_runs_plain(b["answer_runs"])
            if b.get("question_runs") is None:
                b["question_runs"] = []
            if not b.get("answer_runs"):
                b["answer_runs"] = self.parse_inline(item["answer"]) if item and item.get("answer") else []

    def _collect_indented(self, lines: list[str], i: int) -> tuple[list[str], int]:
        body = []
        n = len(lines)
        while i < n:
            ln = lines[i]
            if ln.startswith("    ") or ln.startswith("\t"):
                body.append(ln[4:] if ln.startswith("    ") else ln[1:])
            elif not ln.strip():
                # blank line: continue only if the next line is still indented
                if i + 1 < n and (lines[i + 1].startswith("    ") or lines[i + 1].startswith("\t")):
                    body.append("")
                    i += 1
                    continue
                break
            else:
                break
            i += 1
        return body, i

    def _collect_table(self, lines: list[str], i: int) -> tuple[dict | None, int]:
        rows = []
        n = len(lines)
        while i < n and lines[i].strip().startswith("|"):
            rows.append(lines[i].strip())
            i += 1
        if len(rows) < 2:
            return None, i
        def cells(r: str) -> list[str]:
            return [c.strip() for c in r.strip("|").split("|")]
        header = [self.join_runs_plain(self.parse_inline(c)) for c in cells(rows[0])]
        body = []
        for r in rows[2:] if re.match(r"^[\s|:-]+$", rows[1]) else rows[1:]:
            body.append([self.parse_inline(c) for c in cells(r)])
        return {"type": "table", "header": header, "rows": body}, i

    def _collect_list(self, lines: list[str], i: int, md_path: Path) -> tuple[list, int]:
        items = []
        n = len(lines)
        cur: list[str] = []
        base_indent = None
        while i < n:
            raw = lines[i]
            m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", raw)
            if m:
                if cur:
                    items.append(self.parse_inline(self._join_soft(cur)))
                    cur = []
                if base_indent is None:
                    base_indent = len(m.group(1))
                if len(m.group(1)) <= base_indent:
                    cur.append(m.group(3))
                else:
                    # nested item: fold into current item text
                    cur.append(m.group(3))
                i += 1
                continue
            if raw.strip() and raw.startswith(" " * ((base_indent or 0) + 2)):
                cur.append(raw.strip())
                i += 1
                continue
            if not raw.strip():
                if i + 1 < n and re.match(r"^\s*([-*]|\d+\.)\s+", lines[i + 1]):
                    i += 1
                    continue
                break
            break
        if cur:
            items.append(self.parse_inline(self._join_soft(cur)))
        return items, i


def _is_cjk(ch: str) -> bool:
    o = ord(ch)
    return 0x4E00 <= o <= 0x9FFF or 0x3000 <= o <= 0x303F or 0xFF00 <= o <= 0xFFEF


# ----------------------------------------------------------------------------
# Nav parsing (small hand-rolled parser; the nav block is simple nested lists)
# ----------------------------------------------------------------------------

def parse_nav(mk_text: str) -> list[dict]:
    lines = mk_text.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip() == "nav:")
    nav_lines = []
    for ln in lines[start + 1:]:
        if re.match(r"^[A-Za-z#]", ln) and not ln.strip().startswith("#"):
            break
        nav_lines.append(ln)
    chapters: list[dict] = []
    current = None
    for ln in nav_lines:
        stripped = ln.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        m = re.match(r"^-\s+(.*)$", stripped)
        if not m:
            continue
        item = m.group(1).strip()
        ms = re.match(r"^(.*?):\s*(\S+\.md)\s*$", item)
        if ms:
            title = _clean_title(ms.group(1))
            path = ms.group(2)
            if current is not None:
                current["entries"].append((title, path))
            continue
        if item.endswith(":"):
            title = _clean_title(item[:-1])
            current = {"title": title, "entries": []}
            chapters.append(current)
            continue
        # bare path -> an entry (usually the chapter index page) of the current chapter
        if current is not None:
            current["entries"].append(("index", item))
        else:
            current = {"title": "", "entries": [("index", item)]}
            chapters.append(current)
    return chapters


def _clean_title(t: str) -> str:
    t = t.strip().strip('"')
    t = t.replace("&nbsp;", " ")
    return re.sub(r"\s+", " ", t).strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=Path, default=DEFAULT_REPO)
    ap.add_argument("--codes", type=Path, default=DEFAULT_CODES)
    ap.add_argument("--out", type=Path, default=OUTPUT)
    ap.add_argument("--chapters", type=str, default="", help="comma list of chapter numbers, e.g. 11")
    ap.add_argument("--fetch", action="store_true", help="sparse-clone the upstream repo first")
    args = ap.parse_args()

    repo: Path = args.repo
    codes_explicit = "--codes" in sys.argv
    if args.fetch or not (repo / "docs").exists():
        repo.parent.mkdir(parents=True, exist_ok=True)
        if not repo.exists():
            subprocess.run(
                ["git", "clone", "--depth", "1", "--filter=blob:none", "--sparse",
                 UPSTREAM_URL, str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "sparse-checkout", "set", "docs", "codes"], check=True)
        subprocess.run(["git", "-C", str(repo), "sparse-checkout", "add", "--skip-checks",
                        "mkdocs.yml"], check=True)
    # Prefer the repo's own code corpus (version-matched with the docs).
    if not codes_explicit and (repo / "codes" / "python").exists():
        args.codes = repo / "codes"

    mk_text = (repo / "mkdocs.yml").read_text(encoding="utf-8")
    nav = parse_nav(mk_text)

    wanted = set()
    if args.chapters:
        wanted = {c.strip() for c in args.chapters.split(",") if c.strip()}

    ex = Extractor(repo, args.codes)
    sections: list[dict] = []
    chapters_out: list[dict] = []
    rng = random.Random(20260301)     # deterministic quiz distractors

    for ch in nav:
        folder = ""
        for _, path in ch["entries"]:
            parts = Path(path).parts
            if parts and parts[0].startswith("chapter_"):
                folder = parts[0]
                break
        if folder in SKIP_CHAPTERS:
            continue
        cm = re.match(r"第 (\d+) 章\s*(.*)", ch["title"])
        if cm:
            ch_num = int(cm.group(1))
            ch_name = cm.group(2).strip()
        else:
            ch_num = -1
            ch_name = ch["title"] or folder
        if wanted and (ch_num == -1 or str(ch_num) not in wanted):
            continue
        ch_id = f"ch{ch_num:02d}" if ch_num >= 0 else "ch_intro"
        cover_stem = folder
        sections_out = []
        for seq, (title, path) in enumerate(ch["entries"]):
            md_path = repo / "docs" / path
            if not md_path.exists():
                ex.warn(f"nav file missing: {path}")
                continue
            num = ""
            is_intro = Path(path).name == "index.md"
            optional = False
            if not is_intro:
                mt = re.match(r"^(\d+\.\d+)\s+(.*)$", title)
                if mt:
                    num = mt.group(1)
                    t = mt.group(2)
                    if t.endswith(" *"):
                        optional = True
                        t = t[:-2]
                    title = t
            sec_id = f"{ch_id}_{seq:02d}"
            blocks, qa_items = ex.parse_markdown(md_path, folder)
            sec = {
                "id": sec_id,
                "chapter": ch_id,
                "num": num,
                "title": title if not is_intro else ch_name,
                "intro": is_intro,
                "optional": optional,
                "blocks": blocks,
                "source": str(Path(path).as_posix()),
            }
            sections_out.append(sec_id)
            sections.append(sec)
            for k, item in enumerate(qa_items):
                answer = item.get("answer", "")
                if not answer and item.get("answer_runs"):
                    answer = ex.join_runs_plain(item["answer_runs"])
                ex.quiz_items.append({
                    "id": f"q_{sec_id}_r{k}",
                    "section": sec_id,
                    "type": "reveal",
                    "question": item["question"],
                    "answer": answer,
                })
        chapters_out.append({
            "id": ch_id,
            "num": ch_num if ch_num >= 0 else None,
            "title": ch_name,
            "folder": folder,
            "cover": f"cover_{cover_stem}",
            "sections": sections_out,
        })

    # ---------------------------------------------------------------- quiz --
    quiz: list[dict] = ex.quiz_items

    def looks_complexity(cell: str) -> bool:
        return bool(re.match(r"^[OΘΩ]\s*[(（]", cell)) or cell.startswith("≤") or cell.startswith("<")

    COMMON_COMPLEXITIES = ["O(1)", "O(log n)", "O(n)", "O(n log n)", "O(n²)", "O(n³)", "O(2^n)"]

    def push_mcq(qid, sec_id, question, value, pool, tag) -> None:
        distractors = sorted({v for v in pool if v and v != value})
        if len(distractors) < 3:
            for cand in COMMON_COMPLEXITIES:      # top up from common answers
                if cand != value and cand not in distractors:
                    distractors.append(cand)
            distractors = distractors[:6]
        if len(distractors) < 3:
            return False
        rng.shuffle(distractors)
        opts = distractors[:3] + [value]
        rng.shuffle(opts)
        quiz.append({
            "id": qid,
            "section": sec_id,
            "type": "mcq",
            "question": question,
            "options": opts,
            "answer": value,
        })
        return True

    def header_label(header_cell: str) -> str:
        text = header_cell.strip()
        # "时间复杂度 O(f(n))" -> "时间复杂度"
        return re.sub(r"\s*[OΘΩ]\s*\(.*\)\s*$", "", text).strip() or "时间复杂度"

    # MCQs from complexity tables (two shapes: header=row label, or transposed)
    mcq_budget = 40
    for sec in sections:
        made = 0
        for b in sec["blocks"]:
            if b.get("type") != "table" or made >= 6 or mcq_budget <= 0:
                continue
            header = b["header"]
            comp_header = next((i for i, h in enumerate(header) if "复杂度" in h), -1)
            if comp_header > 0:
                # rows are algorithms: 「X」的时间复杂度是？
                rows = [(ex.join_runs_plain(r[0]) if r else "",
                         ex.join_runs_plain(r[comp_header]) if comp_header < len(r) else "")
                        for r in b["rows"]]
                pool = [v for _, v in rows]
                col_label = header_label(header[comp_header])
                for label, value in rows:
                    if not label or not value or not looks_complexity(value):
                        continue
                    question = f"「{label}」的{col_label}是？"
                    if label.isdigit():
                        question = f"当操作数量 T(n) = {label} 时，其{col_label}属于哪一类？"
                    if push_mcq(f"q_{sec['id']}_c{made}", sec["id"], question, value, pool, "c"):
                        made += 1
                        mcq_budget -= 1
                    if made >= 6 or mcq_budget <= 0:
                        break
            else:
                # transposed: columns are structures, rows are operations
                cols = header[1:]
                if not cols:
                    continue
                cells = []
                for r in b["rows"]:
                    if not r:
                        continue
                    op = ex.join_runs_plain(r[0])
                    for ci in range(1, min(len(r), len(header))):
                        v = ex.join_runs_plain(r[ci])
                        if op and looks_complexity(v):
                            cells.append((op, header[ci], v))
                pool = [v for _, _, v in cells]
                for op, colname, value in cells[:4]:
                    if mcq_budget <= 0 or made >= 6:
                        break
                    question = f"{colname}{op}的时间复杂度是？"
                    if push_mcq(f"q_{sec['id']}_c{made}", sec["id"], question, value, pool, "c"):
                        made += 1
                        mcq_budget -= 1

    # glossary from terminology table
    glossary = []
    term_path = repo / "docs" / "chapter_appendix" / "terminology.md"
    if term_path.exists():
        term_lines = term_path.read_text(encoding="utf-8").splitlines()
        table_at = next((i for i, ln in enumerate(term_lines) if ln.strip().startswith("|")), 0)
        tbl, _ = ex._collect_table(term_lines, table_at)
        if tbl:
            for r in tbl["rows"]:
                if len(r) >= 2:
                    en = ex.join_runs_plain(r[0])
                    cn = ex.join_runs_plain(r[1])
                    if en and cn:
                        glossary.append({"en": en, "cn": cn})
    for k in range(0, len(glossary), 4):
        subset = glossary[k:k + 4]
        if len(subset) < 4:
            break
        target = subset[0]
        others = [g["cn"] for g in subset[1:]]
        opts = others + [target["cn"]]
        rng.shuffle(opts)
        quiz.append({
            "id": f"q_gloss_{k}",
            "section": "glossary",
            "type": "mcq",
            "question": f"术语「{target['en']}」对应的中文是？",
            "options": opts,
            "answer": target["cn"],
        })

    # hand-curated items for the core chapters (tools/quizzes_core.yaml)
    curated_path = ROOT / "tools" / "quizzes_core.yaml"
    if curated_path.exists():
        import yaml
        curated = yaml.safe_load(curated_path.read_text(encoding="utf-8")) or []
        section_ids = {s["id"] for s in sections}
        for k, item in enumerate(curated):
            sec_id = str(item.get("section", ""))
            opts = [str(o) for o in item.get("options", [])]
            answer = str(item.get("answer", "")).strip()
            question = str(item.get("question", "")).strip()
            ok = (
                sec_id in section_ids
                and question != ""
                and len(opts) == 4
                and len({o for o in opts}) == 4
                and answer in opts
            )
            if not ok:
                ex.warn(f"curated quiz item {k} invalid (section={sec_id})")
                continue
            quiz.append({
                "id": f"q_{sec_id}_h{k}",
                "section": sec_id,
                "type": "mcq",
                "question": question,
                "options": opts,
                "answer": answer,
            })

    content = {
        "meta": {
            "title": "Algo Buddy",
            "source": "hello-algo",
            "sourceTitle": "Hello 算法",
            "sourceUrl": "https://github.com/krahets/hello-algo",
            "license": "CC BY-NC-SA 4.0",
            "author": "krahets",
            "generatedBy": "algo-buddy/tools/extract_content.py",
        },
        "chapters": chapters_out,
        "sections": sections,
        "glossary": glossary,
        "quiz": quiz,
        "images": ex.images,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(content, ensure_ascii=False, indent=1), encoding="utf-8")

    # -------------------------------------------------------------- report --
    n_steps = sum(1 for s in sections for b in s["blocks"] if b["type"] == "figure_steps")
    n_figs = sum(1 for s in sections for b in s["blocks"] if b["type"] == "figure")
    n_code = sum(1 for s in sections for b in s["blocks"] if b["type"] == "code")
    n_qa = sum(1 for s in sections for b in s["blocks"] if b["type"] == "qa")
    print(f"chapters={len(chapters_out)} sections={len(sections)} blocks="
          f"{sum(len(s['blocks']) for s in sections)}")
    print(f"figures={n_figs} figure_steps={n_steps} code={n_code} qa={n_qa}")
    print(f"quiz={len(quiz)} glossary={len(glossary)} images={len(ex.images)}")
    if ex.math_fallbacks:
        print(f"math fallbacks: {len(ex.math_fallbacks)}")
    if ex.warnings:
        print(f"warnings: {len(ex.warnings)}")
        for w in ex.warnings[:40]:
            print("  W:", w)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
