#!/usr/bin/env python3
# render-run-evidence.py — render a REAL captured poc-run.txt into a dark-terminal-styled poc-run.png (#1550).
#
# HONESTY GUARD (see render-run-evidence.sh): this renders the VERBATIM text it is handed, verbatim. It never
# synthesizes a `[PASS]` — it only colourizes lines the captured log already contains. Call it only on a real
# captured run-log (deliver-submission.sh gates the invocation on the #1540 `--poc-run`-file-exists check).
#
# argv[1] = input .txt (a captured terminal run-log), argv[2] = output .png. Exit 0 rendered, 1 on any error
# (a render bug must degrade like "no renderer", never crash the caller — the whole body is try/except-wrapped).
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: render-run-evidence.py <input.txt> <output.png>\n")
        return 1
    in_path, out_path = sys.argv[1], sys.argv[2]

    from PIL import Image, ImageDraw, ImageFont

    with open(in_path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    # Strip ANSI CSI escapes so colour codes never render as literal garbage; we recolour by content below.
    text = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)
    lines = text.replace("\t", "    ").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        lines = [""]

    # Load a monospace TTF from a candidate list; each attempt is guarded so a missing font can never hard-fail.
    font = None
    font_size = 15
    for path in (
        "/usr/share/fonts/google-noto-vf/NotoSansMono[wght].ttf",
        "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Regular.ttf",
        "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
        "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    ):
        try:
            font = ImageFont.truetype(path, font_size)
            break
        except Exception:
            continue
    if font is None:
        font = ImageFont.load_default()

    # Dark terminal palette + mac-style titlebar.
    bg = (30, 30, 30)
    titlebar = (45, 45, 45)
    fg_default = (208, 208, 208)
    fg_pass = (87, 200, 110)
    fg_fail = (224, 96, 96)
    dots = ((255, 95, 86), (255, 189, 46), (39, 201, 63))

    pad = 16
    titlebar_h = 30
    tmp = Image.new("RGB", (1, 1))
    draw = ImageDraw.Draw(tmp)

    def line_size(s: str):
        box = draw.textbbox((0, 0), s if s else " ", font=font)
        return box[2] - box[0], box[3] - box[1]

    line_h = max(line_size("Ag")[1], font_size) + 6
    max_w = max((line_size(ln)[0] for ln in lines), default=0)
    width = max(max_w + pad * 2, 360)
    height = titlebar_h + pad * 2 + line_h * len(lines)

    img = Image.new("RGB", (width, height), bg)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, width, titlebar_h], fill=titlebar)
    for i, colour in enumerate(dots):
        cx = pad + i * 20
        cy = titlebar_h // 2
        d.ellipse([cx - 6, cy - 6, cx + 6, cy + 6], fill=colour)
    d.text((pad + 3 * 20 + 10, titlebar_h // 2 - font_size // 2), "poc-run.txt", font=font, fill=(150, 150, 150))

    y = titlebar_h + pad
    for ln in lines:
        if "[PASS]" in ln:
            colour = fg_pass
        elif "[FAIL]" in ln:
            colour = fg_fail
        else:
            colour = fg_default
        d.text((pad, y), ln, font=font, fill=colour)
        y += line_h

    img.save(out_path, "PNG")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # a render bug degrades like "no renderer" — never crash the caller.
        sys.stderr.write("render-run-evidence.py: render failed: %s\n" % exc)
        sys.exit(1)
