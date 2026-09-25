#!/usr/bin/env python3
"""dossier-pdf.py - render a handoff dossier (Markdown, briefs/handoff-dossier.md shape) as a PDF for the human auditor.

Usage:  python3 scripts/dossier-pdf.py <DOSSIER.md> [<out.pdf>]
Needs:  python3 and the `reportlab` package (pip install reportlab). Without it the script exits 2 with one line and
        writes nothing: a dossier that could not be rendered is still the Markdown, never a half PDF.
Exit:   0 written; 1 the Markdown is not a dossier (no title line); 2 nothing written: reportlab missing, the file
        unreadable, or the layout failed (the PDF is built under a temporary name and renamed only when it is complete;
        a PDF already at the output path is left alone, and the same line says it is from an earlier render).

What it renders, and nothing else: `#` title, `##`-`######` headings, paragraphs, `**bold**`, `inline code`, bullet and
numbered lists (nested by indentation), fenced code blocks (the language tag is printed above the block), and pipe
tables (wrapped cells, long tokens broken, header repeated across pages, a row taller than a page split; a `|` inside
`inline code` or written `\\|` stays in its cell). The first bold lines under the title (the "Not deployed" and the
status line) are set apart in a box, because the auditor reads them first; a `## Start here` section after them (the
dossier's entry page, briefs/handoff-dossier.md) ends with a page break, so the body starts on the next page. Anything the parser does not understand is
printed as plain text, not dropped: a dossier must never lose a line on the way to paper. A character none of the PDF's
built-in fonts can draw is printed as its code point, [U+XXXX], never as a blank box.
"""
import html
import os
import re
import sys
from pathlib import Path


def fail(code, msg):
    print(msg)
    sys.exit(code)


def code_spans(s):
    """Split a line into (is_code, text) pieces on `inline code` spans; an unmatched backtick is text."""
    out, pos = [], 0
    for m in re.finditer(r"(`+)(.+?)\1", s):
        if m.start() > pos:
            out.append((False, s[pos:m.start()]))
        out.append((True, m.group(2)))
        pos = m.end()
    if pos < len(s):
        out.append((False, s[pos:]))
    return out


def inline(s, code_size=8):
    """Markdown inline -> reportlab paragraph markup. Code spans are escaped and kept verbatim (a `*` in a glob is not
    emphasis); bold, italics and links are read only outside them."""
    parts = []
    for is_code, piece in code_spans(s):
        piece = html.escape(piece, quote=False)
        if is_code:
            parts.append('<font face="Courier" size="%s">%s</font>' % (code_size, piece))
            continue
        piece = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", piece)
        piece = re.sub(r"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])", r"<i>\1</i>", piece)  # not "a * b * c"
        piece = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (<font face='Courier' size='%s'>\2</font>)" % code_size, piece)
        parts.append(piece)
    return "".join(parts)


def split_row(line):
    """A table row -> cells. A `|` inside `inline code`, or escaped as `\\|`, belongs to its cell."""
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    cells, cur, in_code, k = [], "", None, 0
    while k < len(line):
        ch = line[k]
        if ch == "\\" and k + 1 < len(line) and line[k + 1] == "|":
            cur += "|"
            k += 2
            continue
        if ch == "`":
            run = re.match(r"`+", line[k:]).group(0)
            if in_code is None and line.find(run, k + len(run)) != -1:
                in_code = run
            elif in_code == run:
                in_code = None
            cur += run
            k += len(run)
            continue
        if ch == "|" and in_code is None:
            cells.append(cur.strip())
            cur = ""
        else:
            cur += ch
        k += 1
    cells.append(cur.strip())
    return cells


def is_sep(line):
    return bool(re.match(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$", line))


FENCE = re.compile(r"^(\s*)(```+|~~~+)\s*(.*)$")
# "- " and "* " bullets, "1." and "1)" numbers; not "+ ", which starts a wrapped line of prose ("a\n+ b") as often as a list
ITEM = re.compile(r"^(\s*)([-*]|\d{1,3}[.)])\s+(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")


def main():
    if len(sys.argv) < 2:
        fail(2, "usage: dossier-pdf.py <DOSSIER.md> [<out.pdf>]")
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".pdf")
    # nothing written means the PDF already there, if any, is from an earlier render: said on the same line, not removed
    stale = "; %s is from an earlier render, not this Markdown" % out if out.exists() else ""
    try:
        text = src.read_text(encoding="utf-8").replace("\r\n", "\n")
    except (OSError, UnicodeDecodeError) as e:
        fail(2, "dossier-pdf: cannot read %s (%s); nothing written%s" % (src, e.__class__.__name__, stale))
    lines = text.split("\n")
    # the title is the first '# ' line within the first ten lines; leading blank lines and HTML comments (a header
    # the orchestrator adds when it saves a report for a subagent) are skipped and printed after the box as plain text.
    # Decided before reportlab is imported: "not a dossier" does not depend on what is installed.
    start = next((k for k in range(min(10, len(lines))) if lines[k].startswith("# ")), None)
    if start is None:
        fail(1, "dossier-pdf: %s has no '# ' title line in its first ten lines: not a dossier" % src)
    try:
        from reportlab.lib import colors
        from reportlab.lib.enums import TA_LEFT
        from reportlab.lib.pagesizes import A4
        from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
        from reportlab.lib.units import mm
        from reportlab.pdfbase import pdfmetrics
        from reportlab.platypus import PageBreak, Paragraph, Preformatted, SimpleDocTemplate, Spacer, Table, TableStyle
        from reportlab.platypus.doctemplate import LayoutError
    except ImportError:
        fail(2, "dossier-pdf: the reportlab package is not installed (pip install reportlab); nothing written - hand over the Markdown%s" % stale)

    # a character that neither the text font nor its substitutes (Symbol, ZapfDingbats) can draw comes out as a black
    # box, which a reader cannot tell from a real one: print its code point instead
    fonts = [pdfmetrics.getFont("Helvetica")] + list(pdfmetrics.getFont("Helvetica").substitutionFonts)
    nodraw = pdfmetrics.unicode2T1("\U0010FFFD", fonts)
    seen = {}

    def drawable(ch):
        if ch not in seen:
            seen[ch] = ord(ch) < 0x80 or ch == "\u25a0" or pdfmetrics.unicode2T1(ch, fonts) != nodraw
        return seen[ch]

    lines = ["".join(c if drawable(c) else "[U+%04X]" % ord(c) for c in l) for l in lines]
    preamble = [l for l in lines[:start] if l.strip()]
    lines = lines[start:]

    ss = getSampleStyleSheet()
    body = ParagraphStyle("body", parent=ss["Normal"], fontName="Helvetica", fontSize=9.2, leading=12.5, spaceAfter=4,
                          splitLongWords=1)
    small = ParagraphStyle("small", parent=body, fontSize=8, leading=10)
    caption = ParagraphStyle("caption", parent=body, fontName="Courier", fontSize=6.8, leading=8, spaceBefore=3,
                             spaceAfter=0, textColor=colors.HexColor("#777777"))
    cell = ParagraphStyle("cell", parent=body, fontSize=7.8, leading=9.8, spaceAfter=0)
    cellh = ParagraphStyle("cellh", parent=cell, fontName="Helvetica-Bold")
    # a table with many columns is set smaller, so that its narrow columns still hold whole words
    cell_s = ParagraphStyle("cell_s", parent=cell, fontSize=6.6, leading=8.2)
    cellh_s = ParagraphStyle("cellh_s", parent=cell_s, fontName="Helvetica-Bold")
    h1 = ParagraphStyle("h1", parent=ss["Title"], fontName="Helvetica-Bold", fontSize=17, leading=21, alignment=TA_LEFT, spaceAfter=6)
    h2 = ParagraphStyle("h2", parent=ss["Heading2"], fontName="Helvetica-Bold", fontSize=12.5, leading=16, spaceBefore=12, spaceAfter=5,
                        textColor=colors.HexColor("#1a1a1a"))
    h3 = ParagraphStyle("h3", parent=ss["Heading3"], fontName="Helvetica-Bold", fontSize=10.5, leading=13, spaceBefore=8, spaceAfter=3)
    code = ParagraphStyle("code", parent=ss["Code"], fontName="Courier", fontSize=7.3, leading=9, leftIndent=6,
                          backColor=colors.HexColor("#f4f4f4"), borderPadding=4, spaceBefore=3, spaceAfter=6)
    boxed = ParagraphStyle("boxed", parent=body, fontSize=8.8, leading=11.5, backColor=colors.HexColor("#fff6e5"),
                           borderColor=colors.HexColor("#d9a441"), borderWidth=0.8, borderPadding=6, spaceBefore=4, spaceAfter=8)
    bullets = {}

    def bullet_style(level):
        if level not in bullets:
            bullets[level] = ParagraphStyle("bullet%d" % level, parent=body, leftIndent=12 + 12 * level,
                                            bulletIndent=2 + 12 * level, spaceAfter=2)
        return bullets[level]

    margin = 15 * mm
    # the frame's usable width: the page less both margins, less the frame's own 6 pt padding on each side
    page_w = A4[0] - 2 * margin - 12
    # a code line longer than the frame is wrapped, never drawn past the page edge (Courier: 0.6 em per character)
    code_chars = int((page_w - code.leftIndent - 2 * code.borderPadding) / (0.6 * code.fontSize))

    def para(texts, style, code_size=8, **kw):
        # one or more Markdown lines as one paragraph (joined by a blank line). Emphasis the inline reader nests wrongly
        # ("**a *b** c*") is markup reportlab refuses: then the same lines are set as plain text, never dropped
        texts = [texts] if isinstance(texts, str) else texts
        try:
            return Paragraph("<br/><br/>".join(inline(x, code_size) for x in texts), style, **kw)
        except ValueError:
            return Paragraph("<br/><br/>".join(html.escape(x, quote=False) for x in texts), style, **kw)

    def build_story(split_rows):
        # split_rows: 0 keeps every table row whole (a row that does not fit moves to the next page); 1 lets a row
        # split across pages, used only when a row is taller than a whole page and the first layout was refused
        story = []

        def flush_para(buf):
            if buf:
                story.append(para(" ".join(buf), body))
                buf.clear()

        def col_widths(rows, size, code_size):
            # every column first gets the width of its longest word (so that words are not cut), capped at a third of
            # the frame so that one hash or path cannot starve the others - a longer token is broken inside its cell;
            # what is left is shared in proportion to how much more each column's longest cell would like to have.
            # When the words alone do not fit, the widest columns are narrowed first and only their long words break.
            def width(text, bold):
                w = 0.0
                for is_code, piece in code_spans(text.replace("**", "")):
                    if is_code:
                        w += pdfmetrics.stringWidth(piece, "Courier", code_size)
                    else:
                        w += pdfmetrics.stringWidth(piece, "Helvetica-Bold" if bold else "Helvetica", size)
                return w
            pad = 6 + 2
            mins, nats = [], []
            for c in range(len(rows[0])):
                words = [(w, k == 0) for k, r in enumerate(rows) for w in r[c].split()]
                mins.append(min(max([width(w, b) for w, b in words] or [0.0]) + pad, page_w / 3.0))
                nats.append(max(max(width(r[c], k == 0) for k, r in enumerate(rows)) + pad, mins[-1]))
            if sum(mins) >= page_w:
                # the widest columns give way first: one cap C for all, the largest with sum(min(m, C)) <= the frame,
                # so a column of short words keeps them whole and the long tokens break where they are
                lo, hi = 0.0, max(mins)
                for _ in range(40):
                    mid = (lo + hi) / 2
                    lo, hi = (mid, hi) if sum(min(m, mid) for m in mins) <= page_w else (lo, mid)
                capped = [min(m, lo) for m in mins]
                return [c * page_w / sum(capped) for c in capped]
            want = [n - m for n, m in zip(nats, mins)]
            spare = page_w - sum(mins)
            if sum(want) <= 0:
                return [m + spare / len(mins) for m in mins]
            return [m + spare * w / sum(want) for m, w in zip(mins, want)]

        def render_table(rows):
            if not rows:
                return
            ncol = len(rows[0])
            # the header decides the columns: a row with more cells keeps the extra ones in its last cell, never drops them
            rows = [r[:ncol - 1] + [" | ".join(r[ncol - 1:])] if len(r) > ncol else r + [""] * (ncol - len(r)) for r in rows]
            many = ncol >= 7
            cs, ch, csize = (cell_s, cellh_s, 6.6) if many else (cell, cellh, 7.2)
            data = [[para(c, ch, csize) for c in rows[0]]] + [[para(c, cs, csize) for c in r] for r in rows[1:]]
            widths = col_widths(rows, cs.fontSize, csize)
            t = Table(data, colWidths=widths, repeatRows=1, splitInRow=split_rows)
            t.setStyle(TableStyle([
                ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#bbbbbb")),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e9e9e9")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 3), ("RIGHTPADDING", (0, 0), (-1, -1), 3),
                ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ]))
            story.append(t)
            story.append(Spacer(1, 6))

        i = 0
        buf = []
        in_head_box = True   # the bold lines right under the title go into the box
        box_lines = []
        entry_page = False   # inside a "## Start here" section: the next heading of its level starts a new page
        while i < len(lines):
            line = lines[i]
            s = line.rstrip()
            if i == 0:
                story.append(para(s[2:].strip(), h1))
                i += 1
                continue
            if in_head_box:
                if s.strip() == "":
                    i += 1
                    continue
                if s.startswith("**"):
                    # gather a bold paragraph: it may wrap onto following lines, until a blank line or the next bold line
                    bold = [s]
                    i += 1
                    while (i < len(lines) and lines[i].strip() != "" and not lines[i].startswith("#")
                           and not lines[i].startswith("**")):
                        bold.append(lines[i].rstrip())
                        i += 1
                    box_lines.append(" ".join(bold))
                    continue
                in_head_box = False
                if box_lines:
                    story.append(para(box_lines, boxed))
                # fall through to normal handling of this line
            fm = FENCE.match(s)
            if fm:
                flush_para(buf)
                indent, mark, lang = len(fm.group(1)), fm.group(2), fm.group(3).strip()
                i += 1
                block = []
                while i < len(lines):
                    cm = FENCE.match(lines[i].rstrip())
                    if cm and cm.group(2)[0] == mark[0] and len(cm.group(2)) >= len(mark) and not cm.group(3).strip():
                        break
                    raw = lines[i].rstrip()
                    # a block opened inside an indented list item: its lines lose that indentation, and only that
                    block.append((raw[indent:] if raw[:indent].strip() == "" else raw).expandtabs(4))
                    i += 1
                i += 1
                if lang:
                    story.append(Paragraph(html.escape(lang, quote=False), caption))
                story.append(Preformatted("\n".join(block), code, maxLineLength=code_chars))
                continue
            hm = HEADING.match(s)
            if hm:
                flush_para(buf)
                level, head = len(hm.group(1)), hm.group(2).strip()
                if level <= 2 and entry_page:
                    story.append(PageBreak())   # the entry page ends here: the body starts on the next page
                    entry_page = False
                story.append(para(head, h2 if level <= 2 else h3))
                if level <= 2 and re.match(r"(?i)start here\b", head):
                    entry_page = True
                i += 1
                continue
            if s.strip().startswith("|") and i + 1 < len(lines) and is_sep(lines[i + 1]):
                flush_para(buf)
                rows = [split_row(s)]
                i += 2
                while i < len(lines) and lines[i].strip().startswith("|"):
                    rows.append(split_row(lines[i]))
                    i += 1
                render_table(rows)
                continue
            im = ITEM.match(s)
            if im and not s.lstrip().startswith("**"):
                flush_para(buf)
                level = min(len(im.group(1).expandtabs(4)) // 2, 4)
                marker = im.group(2)
                item = im.group(3)
                i += 1
                # continuation lines: indented, not blank, not a new item, not a fence
                while (i < len(lines) and lines[i].startswith("  ") and lines[i].strip() and not ITEM.match(lines[i])
                       and not FENCE.match(lines[i])):
                    item += " " + lines[i].strip()
                    i += 1
                if marker[0].isdigit():
                    label = marker
                else:
                    label = "\u2022" if level == 0 else "-"
                story.append(para(item, bullet_style(level), bulletText=label))
                continue
            if s.strip() == "":
                flush_para(buf)
                i += 1
                continue
            if s.strip() == "---":
                flush_para(buf)
                story.append(Spacer(1, 6))
                i += 1
                continue
            buf.append(s.strip())
            i += 1
        flush_para(buf)
        if in_head_box and box_lines:
            story.append(para(box_lines, boxed))
        if preamble:
            story.append(para(" ".join(preamble), small))
        return story

    title = lines[0][2:].strip()

    def shown(head):
        return head if head == title else head.rstrip() + "\u2026"

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7.5)
        canvas.setFillColor(colors.HexColor("#666666"))
        right = "page %d" % doc.page
        tail = " - rendered from %s by hook-gauntlet; the Markdown is the record" % src.name
        room = A4[0] - 2 * margin - pdfmetrics.stringWidth(right, "Helvetica", 7.5) - 12
        # the title is shortened until the line fits beside the page number; the "Markdown is the record" part stays
        head = title
        while head and pdfmetrics.stringWidth(shown(head) + tail, "Helvetica", 7.5) > room:
            head = head[:-1]
        canvas.drawString(margin, 10 * mm, shown(head) + tail)
        canvas.drawRightString(A4[0] - margin, 10 * mm, right)
        canvas.restoreState()

    tmp = out.with_name(out.name + ".part")
    try:
        for split_rows in (0, 1):
            doc = SimpleDocTemplate(str(tmp), pagesize=A4, leftMargin=margin, rightMargin=margin, topMargin=16 * mm,
                                    bottomMargin=16 * mm, title=title, author="hook-gauntlet", subject="handoff dossier")
            try:
                doc.build(build_story(split_rows), onFirstPage=footer, onLaterPages=footer)
                break
            except LayoutError:
                if split_rows:
                    raise
        os.replace(str(tmp), str(out))
    except Exception as e:  # a layout reportlab refuses, a directory we cannot write: no PDF rather than half of one
        try:
            tmp.unlink()
        except OSError:
            pass
        first = (str(e).splitlines() or [""])[0][:160]
        fail(2, "dossier-pdf: could not render %s (%s: %s); nothing written - hand over the Markdown%s" % (src, e.__class__.__name__, first, stale))
    print("dossier-pdf: wrote %s (%d page%s, %d lines of Markdown)" % (out, doc.page, "" if doc.page == 1 else "s", len(lines)))


if __name__ == "__main__":
    main()
