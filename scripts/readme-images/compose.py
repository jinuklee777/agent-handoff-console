#!/usr/bin/env python3
"""README 소개 이미지 합성 (make.sh 가 부른다).

사용법: python3 compose.py <캡처 폴더> <출력 폴더> [이름...]
실제 앱 캡처(2배율, 1440×900pt 창 — hero 는 1440×920, changes 는 1440×720)에서 필요한 부분을 잘라 흰 바탕 · 옅은 색 번짐 · 큰 문구의 페이지로 만들고
헤드리스 Chrome 으로 2배율 PNG 를 뽑는다. 색 · 그림자는 앱의 라이트 팔레트(`UI/Design/Theme.swift`)를 따른다.
자르는 영역은 지금 창 배치(사이드바 · 인스펙터 폭) 기준이다 — 배치가 바뀌면 아래 좌표를 확인한다 (2026-10-11: 직접 그린 사이드바
248pt 와 구분선 뒤 대화 칸은 x 498px 부터, 인스펙터는 2040px 부터). 글줄 한가운데 · 단추 · 줄 번호에 걸리지 않게 빈 자리에서 자른다.
인계 카드는 미리보기 앱이 적어 둔 자리로 자른다 (`-preview.cardFrameFile` — `UI/HandoffCardView.swift` 의 `PreviewCardFrame`,
없으면 멈춘다). 페이지마다 한국어판(<이름>.png)과 영어 제목판(<이름>-en.png)을 만든다 — 문구는 아래 `TEXT`.
"""
import json
import os
import shutil
import subprocess
import sys
import time

from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHOTS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else None
OUT = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
ONLY = sys.argv[3:]
if not SHOTS or not OUT:
    sys.exit("사용법: python3 compose.py <캡처 폴더> <출력 폴더> [이름...]")
WORK = os.path.join(os.path.dirname(SHOTS), "compose")
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
os.makedirs(os.path.join(WORK, "crops"), exist_ok=True)
os.makedirs(OUT, exist_ok=True)

# 글꼴 — 환경 변수 PRETENDARD_FONT 에 Pretendard 파일(PretendardVariable.woff2) 경로를 주면 쓴다. 없으면 시스템 글꼴로 대신한다.
FONT = os.environ.get("PRETENDARD_FONT") or None
if FONT and not os.path.exists(FONT):
    print(f"PRETENDARD_FONT 의 파일이 없습니다: {FONT}")
    FONT = None
if FONT:
    shutil.copy(FONT, os.path.join(WORK, "PretendardVariable.woff2"))
else:
    print("Pretendard 를 찾지 못해 시스템 글꼴(Apple SD Gothic Neo)로 합성합니다.")
shutil.copy(os.path.join(ROOT, "AgentHandoffConsole", "Resources", "Assets.xcassets", "AppIcon.appiconset",
                         "icon_512x512@2x.png"), os.path.join(WORK, "app-icon.png"))

# 글자 · 그림자의 검정은 앱 `Theme.swift` 의 ink 와 같은 #0B0B0B (2026-10-09 Claude 의 회색 단계로 바꿨다 — 그 전에는 영상
# theme.ts 와 같은 #0F172A). 회색은 영상 theme.ts 와 같은 값.
INK, SLATE, SLATE2 = "#0B0B0B", "#64748B", "#94A3B8"
FLOAT = "0 50px 110px rgba(11,11,11,.16), 0 14px 34px rgba(11,11,11,.08), 0 0 0 1px rgba(11,11,11,.06)"


def wash(a, b, base="#fff"):
    return (f"radial-gradient(70% 80% at 8% 10%, {a} 0%, rgba(255,255,255,0) 62%), "
            f"radial-gradient(70% 80% at 96% 96%, {b} 0%, rgba(255,255,255,0) 62%), {base}")


def shot(name):
    return os.path.join(SHOTS, name + ".png")


def crop(name, src, box, radius=0):
    """캡처(픽셀 좌표)에서 box 를 잘라 crops/<name>.png 로. radius 가 있으면 그 둥근 사각형 밖을 투명하게.
    돌려주는 값 = (페이지 기준 경로, 폭pt, 높이pt)."""
    im = Image.open(shot(src)).convert("RGBA").crop(box)
    if radius:
        k = 4
        mask = Image.new("L", (im.width * k, im.height * k), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width * k - 1, im.height * k - 1), radius=radius * k, fill=255)
        im.putalpha(Image.composite(im.split()[3], Image.new("L", im.size, 0),
                                    mask.resize(im.size, Image.LANCZOS)))
    im.save(os.path.join(WORK, "crops", name + ".png"))
    return f"crops/{name}.png", im.width / 2, im.height / 2


# 인계 카드의 모서리 반지름 (pt — `HandoffCardView` 의 RoundedRectangle).
CARD_RADIUS_PT = 12


def card_box(src):
    """대화 끝의 인계 카드 경계 (픽셀). 미리보기 앱이 찍기 전에 적어 둔 `<캡처 이름>.card.json`(포인트 · 창의 왼쪽 위 기준,
    창 크기와 함께)을 캡처의 배율로 옮긴다. 기록이 없거나 캡처 밖이면 멈춘다 — 엉뚱한 곳을 자른 그림을 만들지 않는다."""
    path = os.path.join(SHOTS, src + ".card.json")
    if not os.path.exists(path):
        raise SystemExit(f"{src}: 인계 카드의 자리 기록이 없습니다 ({path}) — make.sh 의 -preview.cardFrameFile 을 확인하세요")
    with open(path, encoding="utf-8") as f:
        frame = json.load(f)
    im = Image.open(shot(src))
    scale = im.width / frame["windowWidth"]
    box = (round(frame["x"] * scale), round(frame["y"] * scale),
           round((frame["x"] + frame["width"]) * scale), round((frame["y"] + frame["height"]) * scale))
    if box[0] < 0 or box[1] < 0 or box[2] > im.width or box[3] > im.height or box[2] - box[0] < 200 or box[3] - box[1] < 100:
        raise SystemExit(f"{src}: 인계 카드가 캡처 안에 다 보이지 않습니다 {box} (캡처 {im.width}×{im.height})")
    return box, round(CARD_RADIUS_PT * scale)


BASE_CSS = """
@font-face { font-family: "Pretendard Variable"; src: url("PretendardVariable.woff2") format("woff2-variations");
             font-weight: 45 920; font-style: normal; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: "Pretendard Variable", -apple-system, "Apple SD Gothic Neo", sans-serif;
       -webkit-font-smoothing: antialiased; overflow: hidden; position: relative; }
"""


def feature_page(lang, title, sub, img, w_pt, h_pt, bg, shaped=False, width=1200, height=900, stage_top=262, max_w=1080):
    """문구(가운데) + 떠 있는 UI 카드(아래). shaped = 이미지가 자기 모양(투명 모서리)을 가져 그림자를 모양대로 준다.
    영어 부제는 한 줄이 한국어보다 길어 더 넓게 둔다 (줄은 문구의 <br> 로 나눈다 — 저절로 꺾이지 않게)."""
    sub_w = 1000 if lang == "en" else 860
    max_h = height - stage_top - 56
    scale = min(max_w / w_pt, max_h / h_pt)
    cw, ch = round(w_pt * scale), round(h_pt * scale)
    card = ("filter: drop-shadow(0 40px 60px rgba(11,11,11,.16)) drop-shadow(0 12px 24px rgba(11,11,11,.08)) "
            "drop-shadow(0 0 1px rgba(11,11,11,.25));") if shaped else \
        f"border-radius: 16px; overflow: hidden; box-shadow: {FLOAT}; background: #fff;"
    return f"""<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width: {width}px; height: {height}px; background: {bg}; }}
.head {{ position: absolute; top: 70px; left: 0; right: 0; text-align: center; }}
h1 {{ margin: 0; font-size: 56px; font-weight: 720; letter-spacing: -0.035em; line-height: 1.16; color: {INK}; }}
.sub {{ margin: 18px auto 0; max-width: {sub_w}px; font-size: 20.5px; line-height: 1.6; font-weight: 500;
        letter-spacing: -0.012em; color: {SLATE}; }}
.card {{ position: absolute; left: {(width - cw) // 2}px; top: {stage_top}px; width: {cw}px; height: {ch}px; {card} }}
.card img {{ display: block; width: 100%; height: 100%; }}
</style></head><body>
<div class="head"><h1>{title}</h1><div class="sub">{sub}</div></div>
<div class="card"><img src="{img}"></div>
</body></html>""", (width, height)


# 문구 — 한국어(README.ko.md)와 영어(README.md, 파일 이름 끝에 "-en"). 앱 화면은 v0.1 의 한국어 그대로다.
TEXT = {
    "ko": {
        "tagline": "<b>Claude Code · Codex · Antigravity</b>를 한 대화에서.<br>"
                   "다른 에이전트에게 맥락째 넘기고, 넘긴 문서 · 전달 상태까지 확인합니다.",
        "social": "<b>Claude Code · Codex · Antigravity</b>를<br>한 대화에서. 다른 에이전트에게<br>맥락째 넘겨 이어 갑니다.",
        "agents": ("세 에이전트를 한 대화로.",
                   "Claude Code · Codex · Antigravity를 한 대화에서 번갈아 씁니다.<br>"
                   "모델과 추론 강도는 대화마다, 사용량과 API 환산 비용은 턴마다 남습니다."),
        "handoff": ("넘기기 전에, 카드로 확인.",
                    "목표 · 바뀐 파일 · 다음 행동을 인계 문서로 묶어 다른 에이전트에게 넘깁니다.<br>"
                    "앱이 확인하지 못한 내용은 지어내지 않고 따로 표시합니다."),
        "relay": ("맥락은 그대로.",
                  "받은 에이전트는 인계 문서로 바로 이어서 일합니다.<br>"
                  "대화에는 누가 누구에게 넘겼는지, 실행마다 어떤 파일이 바뀌었는지 남습니다."),
        "changes": ("검토하고, 커밋까지.",
                    "바뀐 파일을 diff 로 확인하고, 골라서 커밋 · 업로드합니다.<br>"
                    "에이전트가 실행 중일 때는 앱의 Git 쓰기를 막습니다."),
    },
    "en": {
        "tagline": "<b>Claude Code · Codex · Antigravity</b> in one conversation.<br>"
                   "Hand off to another agent with full context, and see what was sent and whether it arrived.",
        "social": "<b>Claude Code · Codex · Antigravity</b><br>in one conversation. Hand off to<br>"
                  "another agent with full context.",
        "agents": ("Three agents, one conversation.",
                   "Use Claude Code, Codex and Antigravity in turn, in the same conversation.<br>"
                   "Model and effort are set per conversation; each turn records usage and API-equivalent cost."),
        "handoff": ("Check the card before you hand off.",
                    "The goal, changed files and next action go into a handoff document for the next agent.<br>"
                    "Anything the app couldn't confirm is flagged as such, never made up."),
        "relay": ("The context carries over.",
                  "The receiving agent picks up from the handoff document right away.<br>"
                  "The conversation records who handed off to whom, and which files each run changed."),
        "changes": ("Review, then commit.",
                    "Check the changed files as diffs, choose what to commit, and push.<br>"
                    "Git writes from the app wait while an agent is running."),
    },
}


def hero_page(src, dark=False, lang="ko", width=1200):
    bg = ("radial-gradient(60% 70% at 6% 4%, rgba(217,119,87,.22) 0%, rgba(11,17,32,0) 60%), "
          "radial-gradient(60% 70% at 96% 100%, rgba(45,108,223,.22) 0%, rgba(11,17,32,0) 60%), #0B1120") if dark \
        else wash("#FBE9E1", "#E3EAF8")
    ink, sub = ("#F8FAFC", "#94A3B8") if dark else (INK, SLATE)
    size = Image.open(shot(src)).size
    win_w = 1088
    win_h = round(win_w * size[1] / size[0])
    # 창 아래 여백은 창 높이와 상관없이 같게 (1440×900 창일 때 980).
    height = 262 + win_h + 38
    shadow = ("drop-shadow(0 40px 60px rgba(0,0,0,.55)) drop-shadow(0 0 1px rgba(255,255,255,.18))" if dark else
              "drop-shadow(0 40px 70px rgba(11,11,11,.18)) drop-shadow(0 10px 22px rgba(11,11,11,.08)) "
              "drop-shadow(0 0 1px rgba(11,11,11,.22))")
    return f"""<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width: {width}px; height: {height}px; background: {bg}; }}
.head {{ position: absolute; top: 58px; left: 0; right: 0; display: flex; flex-direction: column; align-items: center; }}
.brand {{ display: flex; align-items: center; gap: 18px; }}
.brand img {{ width: 76px; height: 76px; margin: -8px -4px -8px -8px; }}
h1 {{ margin: 0; font-size: 50px; font-weight: 740; letter-spacing: -0.035em; color: {ink}; }}
.tag {{ margin-top: 16px; font-size: 22px; font-weight: 520; letter-spacing: -0.015em; color: {sub}; text-align: center;
        line-height: 1.55; }}
.tag b {{ color: {ink}; font-weight: 640; }}
.win {{ position: absolute; left: {(width - win_w) // 2}px; top: 262px; width: {win_w}px; height: {win_h}px;
        filter: {shadow}; }}
.win img {{ display: block; width: 100%; height: 100%; }}
</style></head><body>
<div class="head">
  <div class="brand"><img src="app-icon.png"><h1>Agent Handoff Console</h1></div>
  <div class="tag">{TEXT[lang]["tagline"]}</div>
</div>
<div class="win"><img src="{shot(src)}"></div>
</body></html>""", (width, height)


def social_page(src, lang="ko"):
    """GitHub 저장소 소셜 미리보기 (1280×640, 1배율 — 1MB 제한)."""
    width, height = 1280, 640
    return f"""<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width: {width}px; height: {height}px; background: {wash("#FBE9E1", "#E3EAF8")}; }}
.left {{ position: absolute; left: 72px; top: 0; bottom: 0; width: 520px; display: flex; flex-direction: column;
         justify-content: center; }}
.left img {{ width: 104px; height: 104px; margin: 0 0 14px -12px; }}
h1 {{ margin: 0; font-size: 50px; font-weight: 740; letter-spacing: -0.035em; line-height: 1.08; color: {INK}; }}
.tag {{ margin-top: 20px; font-size: 23px; font-weight: 520; letter-spacing: -0.015em; line-height: 1.5; color: {SLATE}; }}
.tag b {{ color: {INK}; font-weight: 640; }}
.win {{ position: absolute; left: 560px; top: 92px; width: 900px;
        filter: drop-shadow(0 30px 60px rgba(11,11,11,.18)) drop-shadow(0 0 1px rgba(11,11,11,.22)); }}
.win img {{ display: block; width: 100%; }}
</style></head><body>
<div class="left"><img src="app-icon.png"><h1>Agent Handoff<br>Console</h1>
<div class="tag">{TEXT[lang]["social"]}</div></div>
<div class="win"><img src="{shot(src)}"></div>
</body></html>""", (width, height)


def render(name, html, size, scale=2):
    page = os.path.join(WORK, f"{name}.html")
    with open(page, "w") as f:
        f.write(html)
    out = os.path.join(OUT, name + ".png")
    if os.path.exists(out):
        os.remove(out)
    profile = os.path.join(WORK, f".chrome-{name}")
    # 헤드리스 Chrome 은 스크린샷을 쓰고도 스스로 끝나지 않을 때가 있어, 파일이 생기면 끈다.
    proc = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
                             f"--user-data-dir={profile}", f"--force-device-scale-factor={scale}",
                             f"--window-size={size[0]},{size[1]}", "--virtual-time-budget=4000",
                             "--allow-file-access-from-files", f"--screenshot={out}", "file://" + page],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        if os.path.exists(out) and os.path.getsize(out) > 0:
            time.sleep(0.6)
            break
        time.sleep(0.25)
    proc.kill()
    shutil.rmtree(profile, ignore_errors=True)
    im = Image.open(out)
    print(f"{name}.png  {im.size[0]}×{im.size[1]}  {os.path.getsize(out) // 1024}KB")


PEACH_BLUE = wash("#FBE9E1", "#E3EAF8")


def pages(lang):
    """한 언어의 페이지들 — 이름 → (html, 크기) 를 만드는 함수. 자르는 영역은 두 언어가 같다."""
    t = TEXT[lang]
    return {
        "hero": lambda: hero_page("hero", lang=lang),
        "hero-dark": lambda: hero_page("hero-dark", dark=True, lang=lang),
        # 세 에이전트 대화 칸 (사이드바 · 인스펙터 제외, 빈 윗부분 제외)
        "agents": lambda: feature_page(lang, *t["agents"],
                                       *crop("agents", "agents", (520, 436, 2010, 1778)), PEACH_BLUE),
        # 대화 끝의 인계 카드 (앱이 적어 둔 카드 자리 · 카드의 모서리 반지름으로)
        "handoff": lambda: feature_page(lang, *t["handoff"],
                                        *crop("handoff", "handoff", *card_box("handoff")), PEACH_BLUE, shaped=True),
        # 한도 도달 → 인계 줄 → Codex 가 이어받아 끝냄 (대화 칸). 위아래는 줄과 줄 사이의 빈 자리에서 자른다.
        "relay": lambda: feature_page(lang, *t["relay"], *crop("relay", "hero", RELAY_BOX), PEACH_BLUE),
        # 크게 보기 diff + 변경사항 탭 (사이드바 · 툴바 제외, 1440×720 창)
        "changes": lambda: feature_page(lang, *t["changes"], *crop("changes", "changes", CHANGES_BOX),
                                        wash("#E6F4EC", "#E3EAF8")),
        "social-preview": lambda: social_page("hero", lang=lang),
    }


# 자르는 영역 (캡처의 픽셀 — 2배율). relay 는 hero 캡처(make.sh 의 HERO_SIZE 창, 1440×920)에서 Claude 의 "재시도 로직과 테스트…"
# 문단 위 빈 자리부터 Codex 의 바닥글 아래 빈 자리까지. changes 는 1440×720 창에서 사이드바 구분선(x 496–497px) 바로 뒤부터 —
# "대화로 돌아가기" 단추와 줄 번호가 잘리지 않게. 위는 툴바 제목 아래 빈 자리, 아래는 인스펙터의 업로드 줄 아래 빈 자리.
RELAY_BOX = (530, 425, 1970, 1594)
CHANGES_BOX = (498, 100, 2870, 1425)

# 이름 → 페이지. 영어판은 이름 끝에 "-en" (hero-en · hero-dark-en · agents-en …).
PAGES = {}
for lang, suffix in (("ko", ""), ("en", "-en")):
    for base, make in pages(lang).items():
        PAGES[base + suffix] = make

for name in ONLY or PAGES:
    html, size = PAGES[name]()
    render(name, html, size, scale=1 if name.startswith("social-preview") else 2)
