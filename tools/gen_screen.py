#!/usr/bin/env python3
"""포인트 리스트 → HMI 화면 JSON 자동 생성기.

설계 원칙
---------
작화 자동 생성을 통째로 LLM에 시키면 안 된다. 좌표를 LLM이 정하면 매 실행마다
결과가 달라지고 심볼이 겹친다. 역할을 이렇게 나눈다.

    포인트 리스트
        │
        ├─ [LLM]  태그 이름 해석 → 장비/역할 분류   ← 사람 말에 가까운 애매한 일
        │
        ├─ [규칙]  역할 → 심볼·애니메이션 매핑      ← 표 한 장이면 끝
        │
        └─ [코드]  템플릿 배치 → 좌표 계산          ← 결정론적이어야 하는 일
                                                      ↓
                                                  화면 JSON

LLM은 분류기 자리에만 들어간다. 그 자리는 7~14B급 로컬 모델로 충분하고,
장애가 나면 규칙 기반으로 자동 폴백된다.

사용법
------
    python3 tools/gen_screen.py points.csv -o screens/
    python3 tools/gen_screen.py points.csv -o screens/ --llm            # 로컬 LLM 사용
    python3 tools/gen_screen.py points.csv -o screens/ --llm \\
        --model qwen2.5-coder:7b --host http://localhost:11434

입력 CSV 컬럼: tag[, desc][, kind]
    tag  : 포인트 이름 (필수)
    desc : 설명 (선택, 있으면 분류 정확도가 크게 오른다)
    kind : bool / float / int (선택, 없으면 이름에서 추정)
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# 1. 역할 → 심볼 매핑. 작화 규칙의 전부가 이 표에 있다.
# --------------------------------------------------------------------------

ROLE_SYMBOL = {
    #  역할          심볼        애니메이션   기본 크기   흐름도 순서
    "damper":     ("damper",   "level", (80, 60),   10),
    "fan":        ("fan",      "rotate", (76, 76),  20),
    "pump":       ("pump",     "rotate", (70, 70),  20),
    "valve":      ("valve",    "level", (64, 52),   30),
    "tank":       ("tank",     "level", (90, 120),  40),
    "meter":      ("readout",  "text",  (110, 40),  50),
    "status":     ("led",      "color", (34, 34),   60),
    "alarm":      ("led",      "color", (34, 34),   70),
}

ALARM_COLOR  = "#ff5f56"
STATUS_COLOR = "#3ddc84"

UNIT_BY_HINT = [
    (re.compile(r"TEMP|TMP|온도|_T\b", re.I),      "℃"),
    (re.compile(r"RH|HUM|습도", re.I),             "%"),
    (re.compile(r"PRESS|PRS|압력", re.I),          "Pa"),
    (re.compile(r"FLOW|유량", re.I),               "㎥/h"),
    (re.compile(r"POWER|KW|전력", re.I),           "kW"),
    (re.compile(r"POS|개도|LEVEL|LVL|수위", re.I), "%"),
]


@dataclass
class Point:
    tag: str
    desc: str = ""
    kind: str = ""          # bool / float / int
    equip: str = ""         # 소속 장비 (예: AHU-1)
    role: str = "status"    # ROLE_SYMBOL 의 키
    label: str = ""         # 화면에 표시할 이름


# --------------------------------------------------------------------------
# 2. 분류기 — 규칙 기반과 LLM 기반 두 구현이 같은 인터페이스를 갖는다.
# --------------------------------------------------------------------------

ROLE_PATTERNS = [
    ("alarm",  re.compile(r"ALARM|ALM|FAULT|FLT|TRIP|ERR|고장|경보|이상|알람|트립", re.I)),
    ("damper", re.compile(r"DMP|DAMPER|댐퍼", re.I)),
    ("fan",    re.compile(r"\bSF\b|\bRF\b|\bEF\b|FAN|팬|송풍", re.I)),
    ("pump",   re.compile(r"PUMP|PMP|펌프", re.I)),
    ("valve",  re.compile(r"VLV|VALVE|밸브", re.I)),
    ("tank",   re.compile(r"TANK|수조|축열조|탱크", re.I)),
    ("meter",  re.compile(r"TEMP|TMP|온도|RH|HUM|습도|PRESS|PRS|압력|"
                          r"FLOW|유량|POWER|전력|KW|CO2", re.I)),
    ("status", re.compile(r"RUN|STS|STATUS|STATE|운전|상태|기동", re.I)),
]

# 숫자 뒤에 \b 를 쓰면 "AHU1_SF_RUN" 처럼 언더스코어가 이어질 때 경계가 성립하지
# 않아 매치에 실패한다. 후속 숫자만 배제하는 lookahead 를 쓴다.
EQUIP_PATTERN = re.compile(
    r"^\s*([A-Z]{2,4}|[가-힣]{2,4})\s*[-_ ]?\s*(\d{1,2})(?!\d)", re.I)

LEVEL_ROLES = {"valve", "damper", "tank"}


class RuleClassifier:
    """정규식 기반. 태그 이름이 규칙적이면 이것만으로 충분하다."""

    name = "rule"

    def classify(self, points: list[Point]) -> list[Point]:
        for p in points:
            text = f"{p.tag} {p.desc}"
            p.equip = self._equip(p.tag) or self._equip(p.desc) or "기타"
            p.role = self._role(text, p)
            p.label = p.desc or p.tag
        return points

    @staticmethod
    def _equip(s: str) -> str:
        m = EQUIP_PATTERN.match(s or "")
        return f"{m.group(1).upper()}-{int(m.group(2))}" if m else ""

    @staticmethod
    def _role(text: str, p: Point) -> str:
        pats = dict(ROLE_PATTERNS)

        # 경보가 최우선. "팬 트립"은 팬이 아니라 경보다.
        if pats["alarm"].search(text):
            return "alarm"

        # 계측값이 그 다음. "PUMP-1 압력"은 펌프 심볼이 아니라 수치 표시다.
        # 장비 이름이 태그 앞에 붙어 있어 장비 패턴이 먼저 걸리는 것을 막는다.
        if p.kind != "bool" and pats["meter"].search(text):
            return "meter"

        for role, pat in ROLE_PATTERNS:
            if role in ("alarm", "meter"):
                continue
            if pat.search(text):
                # 밸브/댐퍼/탱크라도 bool 이면 개도가 아니라 상태 표시등이다.
                if role in LEVEL_ROLES and p.kind == "bool":
                    return "status"
                return role

        return "meter" if p.kind in ("float", "int") else "status"


LLM_SYSTEM = """당신은 빌딩 자동제어 포인트 이름을 분류하는 도구입니다.
각 포인트에 대해 소속 장비와 역할을 판정하세요.

role 은 반드시 다음 중 하나입니다:
  damper : 댐퍼 개도
  fan    : 송풍기/팬 (급기, 환기, 배기)
  pump   : 펌프
  valve  : 밸브 개도
  tank   : 탱크/수조 수위
  meter  : 온도·습도·압력·유량·전력 등 계측값
  status : 운전 상태 등 일반 ON/OFF
  alarm  : 고장·경보·트립

equip 은 "AHU-1", "CH-2", "EF-3" 형식으로 정규화하세요.
장비를 알 수 없으면 "기타" 를 쓰세요.
label 은 사람이 읽을 짧은 한국어 이름입니다.

설명 없이 JSON 만 출력하세요."""

LLM_SCHEMA = {
    "type": "object",
    "properties": {
        "points": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "tag":   {"type": "string"},
                    "equip": {"type": "string"},
                    "role":  {"type": "string",
                              "enum": list(ROLE_SYMBOL.keys())},
                    "label": {"type": "string"},
                },
                "required": ["tag", "equip", "role", "label"],
            },
        }
    },
    "required": ["points"],
}


class OllamaClassifier:
    """로컬 LLM 분류기 (Ollama 호환 /api/chat).

    - 구조화 출력을 스키마로 강제하므로 파싱 실패가 거의 없다.
    - 배치로 나눠 보낸다. 한 번에 다 넣으면 컨텍스트가 길어져 품질이 떨어진다.
    - 응답이 이상하거나 서버가 죽어 있으면 규칙 기반으로 조용히 폴백한다.
      자동 생성 파이프라인이 LLM 때문에 멈추면 안 된다.
    """

    name = "llm"

    def __init__(self, model="qwen2.5-coder:7b", host="http://localhost:11434",
                 batch=25, timeout=120):
        self.model, self.host = model, host
        self.batch, self.timeout = batch, timeout
        self.fallback = RuleClassifier()
        self.stats = {"llm": 0, "fallback": 0}

    def classify(self, points: list[Point]) -> list[Point]:
        self.fallback.classify(points)          # 먼저 규칙으로 채워 기본값 확보
        by_tag = {p.tag: p for p in points}

        for i in range(0, len(points), self.batch):
            chunk = points[i:i + self.batch]
            try:
                result = self._ask(chunk)
            except Exception as e:                       # noqa: BLE001
                print(f"  ! LLM 호출 실패 ({e}) — 규칙 기반으로 대체", file=sys.stderr)
                self.stats["fallback"] += len(chunk)
                continue

            for item in result:
                p = by_tag.get(item.get("tag", ""))
                if not p or item.get("role") not in ROLE_SYMBOL:
                    continue
                p.equip = item.get("equip") or p.equip
                p.role  = item["role"]
                p.label = item.get("label") or p.label
                if p.role in LEVEL_ROLES and p.kind == "bool":
                    p.role = "status"                    # 모델이 놓치는 부분 보정
                self.stats["llm"] += 1
        return points

    def _ask(self, chunk: list[Point]) -> list[dict]:
        payload = {
            "model": self.model,
            "stream": False,
            "format": LLM_SCHEMA,
            "options": {"temperature": 0},
            "messages": [
                {"role": "system", "content": LLM_SYSTEM},
                {"role": "user", "content": json.dumps(
                    [{"tag": p.tag, "desc": p.desc, "kind": p.kind} for p in chunk],
                    ensure_ascii=False)},
            ],
        }
        req = urllib.request.Request(
            f"{self.host}/api/chat",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            body = json.loads(r.read().decode())
        return json.loads(body["message"]["content"])["points"]


# --------------------------------------------------------------------------
# 3. 배치 — 여기는 전적으로 결정론적이다. 같은 입력이면 항상 같은 화면.
# --------------------------------------------------------------------------

SHEET_W, SHEET_H = 1100, 680
BLOCK_W = 510
COLS = 2
MARGIN_X, MARGIN_Y = 40, 30
COL_GAP, BLOCK_GAP = 40, 34
FLOW_GAP = 20
LED_STEP = 44
LABEL_MAX_W = 150       # 라벨 슬롯 상한. 넘으면 말줄임.
LABEL_FONT = 14


def text_width(s: str, font: int = LABEL_FONT) -> float:
    """라벨 폭 추정. 한글·한자는 전각이라 영문의 두 배로 잡는다.

    브라우저 없이 좌표를 계산해야 해서 실측 대신 추정한다. 살짝 넉넉하게
    잡는 편이 안전하다 — 좁게 잡으면 라벨이 겹친다.
    """
    w = 0.0
    for ch in s:
        w += font if ord(ch) > 0x1100 else font * 0.55
    return w


def elide(s: str, max_w: float) -> str:
    if text_width(s) <= max_w:
        return s
    out = ""
    for ch in s:
        if text_width(out + ch + "…") > max_w:
            break
        out += ch
    return out + "…"


@dataclass
class Builder:
    nodes: list[dict] = field(default_factory=list)
    seq: int = 0

    def add(self, type_, x, y, w, h, **kw):
        self.seq += 1
        node = {"id": f"n{self.seq}", "type": type_,
                "x": int(x), "y": int(y), "w": int(w), "h": int(h),
                "tag": "", "mode": "none",
                "onColor": STATUS_COLOR, "offColor": "#5b6675",
                "text": "", "unit": ""}
        node.update(kw)
        self.nodes.append(node)
        return node


def unit_for(p: Point) -> str:
    for pat, unit in UNIT_BY_HINT:
        if pat.search(f"{p.tag} {p.desc}"):
            return unit
    return ""


def layout_block(equip: str, points: list[Point]) -> tuple[list[dict], int]:
    """장비 하나를 원점 기준으로 배치하고 (노드, 실제 높이)를 돌려준다.

    위쪽 = 흐름도(댐퍼→팬→밸브→탱크→계측), 아래쪽 = 상태/경보 표시등 목록.
    현장 계통도가 대체로 이 구조라 템플릿 하나로 상당수를 덮는다.

    블록 높이를 고정하지 않고 실측해서 돌려주는 것이 중요하다. 고정 높이로
    두면 포인트가 많은 장비의 표시등 목록이 아래 블록을 침범한다.
    """
    b = Builder()
    b.add("label", 0, 0, 200, 24, text=equip, mode="none")

    flow  = [p for p in points if p.role not in ("status", "alarm")]
    lamps = [p for p in points if p.role in ("status", "alarm")]
    flow.sort(key=lambda p: (ROLE_SYMBOL[p.role][3], p.tag))
    lamps.sort(key=lambda p: (p.role != "alarm", p.tag))   # 경보를 위로

    # --- 흐름도 행 ---
    # 각 항목은 심볼과 라벨 중 넓은 쪽을 슬롯 폭으로 잡고, 심볼을 슬롯 가운데 둔다.
    # 심볼 폭만 기준으로 잡으면 라벨이 옆 항목을 덮는다.
    # 첫 행 라벨은 row_y-24 에 놓이므로, 장비명(0~24)과 부딪히지 않게 여유를 둔다.
    x, row_y, row_h = 0, 56, 0
    for p in flow:
        sym, mode, (w, h), _ = ROLE_SYMBOL[p.role]
        label = elide(p.label, LABEL_MAX_W)
        slot_w = max(w, min(text_width(label), LABEL_MAX_W))
        if x and x + slot_w > BLOCK_W:          # 블록 폭을 넘으면 줄바꿈
            x, row_y, row_h = 0, row_y + row_h + 50, 0
        b.add("label", x, row_y - 24, slot_w, 24, text=label, mode="none")
        b.add(sym, x + (slot_w - w) / 2, row_y, w, h, tag=p.tag, mode=mode,
              text=label, unit=unit_for(p) if p.role == "meter" else "")
        x += slot_w + FLOW_GAP
        row_h = max(row_h, h)

    # --- 표시등 목록 ---
    lamp_y = row_y + row_h + (30 if flow else 0)
    for p in lamps:
        on = ALARM_COLOR if p.role == "alarm" else STATUS_COLOR
        b.add("led", 0, lamp_y, 34, 34, tag=p.tag, mode="color", onColor=on)
        b.add("label", 44, lamp_y + 8, BLOCK_W - 44, 24,
              text=elide(p.label, BLOCK_W - 44), mode="none")
        lamp_y += LED_STEP

    height = max((n["y"] + n["h"] for n in b.nodes), default=0)
    return b.nodes, height


def build_screens(points: list[Point]) -> list[dict]:
    groups: dict[str, list[Point]] = {}
    for p in points:
        groups.setdefault(p.equip, []).append(p)

    # 포인트가 많은 장비부터. 기타는 항상 마지막.
    order = sorted(groups, key=lambda k: (k == "기타", -len(groups[k]), k))

    screens: list[dict] = []
    page: list[dict] = []
    cursor = [MARGIN_Y] * COLS          # 열별 y 커서
    seq = 0

    def flush():
        nonlocal page, cursor
        if page:
            screens.append({"version": 1, "width": SHEET_W, "height": SHEET_H,
                            "nodes": page})
        page, cursor = [], [MARGIN_Y] * COLS

    for equip in order:
        nodes, h = layout_block(equip, groups[equip])
        col = cursor.index(min(cursor))                 # 더 비어 있는 열에
        if cursor[col] + h > SHEET_H - MARGIN_Y:        # 페이지를 넘으면 새 화면
            flush()
            col = 0
        bx = MARGIN_X + col * (BLOCK_W + COL_GAP)
        by = cursor[col]
        for n in nodes:
            seq += 1
            n["id"] = f"n{seq}"
            n["x"] += bx
            n["y"] += by
            page.append(n)
        cursor[col] = by + h + BLOCK_GAP

    flush()
    return screens


# --------------------------------------------------------------------------
# 4. 입출력
# --------------------------------------------------------------------------

def read_points(path: Path) -> list[Point]:
    points = []
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            tag = (row.get("tag") or "").strip()
            if not tag:
                continue
            kind = (row.get("kind") or "").strip().lower()
            if kind not in ("bool", "float", "int"):
                kind = guess_kind(tag, row.get("desc", ""))
            points.append(Point(tag=tag, desc=(row.get("desc") or "").strip(),
                                kind=kind))
    return points


def guess_kind(tag: str, desc: str) -> str:
    text = f"{tag} {desc}"
    if re.search(r"RUN|STS|STATUS|ALARM|ALM|FAULT|TRIP|운전|상태|고장|경보", text, re.I):
        return "bool"
    return "float"


def main(argv=None):
    ap = argparse.ArgumentParser(description="포인트 리스트 → HMI 화면 JSON")
    ap.add_argument("csv", type=Path, help="포인트 리스트 CSV")
    ap.add_argument("-o", "--out", type=Path, default=Path("screens"),
                    help="출력 디렉터리 (기본: screens)")
    ap.add_argument("--llm", action="store_true", help="로컬 LLM 분류기 사용")
    ap.add_argument("--model", default="qwen2.5-coder:7b")
    ap.add_argument("--host", default="http://localhost:11434")
    args = ap.parse_args(argv)

    points = read_points(args.csv)
    if not points:
        print("포인트가 없습니다.", file=sys.stderr)
        return 1

    clf = OllamaClassifier(args.model, args.host) if args.llm else RuleClassifier()
    print(f"포인트 {len(points)}개, 분류기: {clf.name}")
    clf.classify(points)
    if isinstance(clf, OllamaClassifier):
        print(f"  LLM 분류 {clf.stats['llm']}개 / 폴백 {clf.stats['fallback']}개")

    screens = build_screens(points)
    args.out.mkdir(parents=True, exist_ok=True)
    for i, sc in enumerate(screens, 1):
        path = args.out / f"screen{i:02d}.json"
        path.write_text(json.dumps(sc, ensure_ascii=False, indent=2),
                        encoding="utf-8")
        print(f"  {path}  심볼 {len(sc['nodes'])}개")

    equips = sorted({p.equip for p in points})
    print(f"화면 {len(screens)}장, 장비 {len(equips)}개: {', '.join(equips)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
