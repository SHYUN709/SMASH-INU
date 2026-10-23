#!/usr/bin/env python3
"""인천대 송도캠퍼스와 미추홀캠퍼스(사범대학)의 건물과 길을 OpenStreetMap에서 받아
data/campus.json 하나로 저장합니다. 미추홀캠퍼스는 게임 지도에서 송도캠퍼스 바로 동쪽에 붙여 놓습니다.
(실제로는 2km 넘게 떨어져 있어요.)

사용법 (프로젝트 폴더에서):
  python tools/fetch_campus.py                        # 둘 다 자동으로 찾아서 받기
  python tools/fetch_campus.py --songdo way 123456     # 송도캠퍼스 OSM ID를 직접 지정 (relation도 가능)
  python tools/fetch_campus.py --michuhol way 654321   # 미추홀캠퍼스 OSM ID를 직접 지정
  python tools/fetch_campus.py --michuhol-at 37.38 126.65   # 미추홀캠퍼스 위치(위도 경도)로 주변 건물 받기
  python tools/fetch_campus.py --no-michuhol          # 송도캠퍼스만

필요한 것: 파이썬 3.8 이상. 추가 라이브러리는 없습니다.
지도 데이터 © OpenStreetMap 기여자 (ODbL)
"""
import json
import math
import pathlib
import sys
import time
import urllib.parse
import urllib.request

MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
UA = "SMASH-INU campus fetch (github.com/SHYUN709)"
BBOX = "37.355,126.600,37.400,126.680"  # 송도 일대 (남, 서, 북, 동)
LEVEL_H = 3.6        # 한 층 높이(m)
DEFAULT_LEVELS = 5   # 층수 정보가 없는 건물
MICHUHOL_RADIUS = 140  # 미추홀캠퍼스를 위치로 찾을 때 받을 반경(m)
GAP = 90             # 게임 지도에서 두 캠퍼스 사이 간격(m)
SKIP_BUILDINGS = {"roof", "no", "construction", "ruins"}
ROAD_W = {
    "motorway": 16, "trunk": 14, "primary": 12, "secondary": 11, "tertiary": 9,
    "residential": 7, "unclassified": 7, "service": 5, "living_street": 6,
    "pedestrian": 6, "footway": 3, "path": 2.5, "cycleway": 2.5,
}
OUT = pathlib.Path(__file__).resolve().parent.parent / "data" / "campus.json"


class OverpassDown(Exception):
    pass


def overpass(query, fatal=True):
    body = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for attempt in range(4):
        for url in MIRRORS:
            try:
                req = urllib.request.Request(url, data=body, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=200) as r:
                    raw = r.read()
                if raw[:1] == b"{":
                    return json.loads(raw)
                last = f"응답이 JSON이 아님: {raw[:120]!r}"
            except Exception as e:  # noqa: BLE001
                last = e
            print(f"  {url} 실패 ({last}), 다른 서버로 다시 시도합니다", file=sys.stderr)
        if attempt < 3:
            wait = 15 * (attempt + 1)
            print(f"  서버들이 붐벼요. {wait}초 쉬었다가 다시 해 봅니다...", file=sys.stderr)
            time.sleep(wait)
    if not fatal:
        raise OverpassDown(str(last))
    sys.exit(f"Overpass 서버에 연결하지 못했습니다: {last}\n잠시(10~30분) 뒤에 다시 실행해 보세요.")


def area_size(e):
    b = e.get("bounds") or {}
    return (b.get("maxlat", 0) - b.get("minlat", 0)) * (b.get("maxlon", 0) - b.get("minlon", 0))


def find_songdo():
    q = (f'[out:json][timeout:60];('
         f'way["amenity"="university"]["name"~"인천대학교"]({BBOX});'
         f'relation["amenity"="university"]["name"~"인천대학교"]({BBOX});'
         f');out tags bb;')
    els = [e for e in overpass(q).get("elements", []) if "미추홀" not in e.get("tags", {}).get("name", "")]
    if not els:
        sys.exit("송도에서 '인천대학교' 캠퍼스 영역을 찾지 못했습니다.\n"
                 "openstreetmap.org에서 캠퍼스를 클릭해 ID를 확인한 뒤\n"
                 "  python tools/fetch_campus.py --songdo way <ID>\n로 다시 실행하세요.")
    els.sort(key=area_size, reverse=True)
    best = els[0]
    print(f"송도캠퍼스: {best['type']} {best['id']} ({best.get('tags', {}).get('name', '')})")
    return best["type"], best["id"]


def find_michuhol():
    """미추홀캠퍼스를 찾습니다. ('area', type, id) 또는 ('point', lat, lon) 또는 None."""
    q = (f'[out:json][timeout:60];('
         f'nwr["amenity"="university"]["name"~"미추홀"]({BBOX});'
         f'nwr["name"~"미추홀캠퍼스|미추홀타워"]({BBOX});'
         f'nwr["addr:street"="갯벌로"]["addr:housenumber"="12"]({BBOX});'
         f');out tags center bb;')
    els = overpass(q).get("elements", [])
    if not els:
        return None
    print("미추홀캠퍼스 후보:")
    for e in els:
        print(f"  {e['type']} {e['id']}  {e.get('tags', {}).get('name', '(이름 없음)')}")
    areas = [e for e in els if e.get("tags", {}).get("amenity") == "university" and e["type"] != "node"]
    if areas:
        areas.sort(key=area_size, reverse=True)
        a = areas[0]
        print(f"캠퍼스 영역 {a['type']} {a['id']}을 씁니다.")
        return ("area", a["type"], a["id"])
    # 영역이 없으면 '별관'이 들어간 건물을 먼저, 없으면 첫 후보의 위치를 씀
    els.sort(key=lambda e: ("별관" not in e.get("tags", {}).get("name", ""), e["type"] == "node"))
    e = els[0]
    c = e.get("center") or {"lat": e.get("lat"), "lon": e.get("lon")}
    if c.get("lat") is None:
        return None
    print(f"캠퍼스 영역이 없어서 '{e.get('tags', {}).get('name', '')}' 주변 {MICHUHOL_RADIUS}m 건물을 받습니다.")
    return ("point", c["lat"], c["lon"])


def join_rings(segments):
    """열린 선 조각들을 이어서 닫힌 고리로 만듭니다."""
    rings, segs = [], [list(s) for s in segments if len(s) >= 2]
    while segs:
        cur = segs.pop(0)
        changed = True
        while cur[0] != cur[-1] and changed:
            changed = False
            for k, s in enumerate(segs):
                if s[0] == cur[-1]:
                    cur += s[1:]
                elif s[-1] == cur[-1]:
                    cur += s[::-1][1:]
                elif s[-1] == cur[0]:
                    cur = s[:-1] + cur
                elif s[0] == cur[0]:
                    cur = s[::-1][:-1] + cur
                else:
                    continue
                segs.pop(k)
                changed = True
                break
        if cur[0] == cur[-1] and len(cur) >= 4:
            rings.append(cur)
    return rings


def outer_rings(el):
    if el["type"] == "way":
        g = [(p["lat"], p["lon"]) for p in (el.get("geometry") or []) if p]
        return [g] if len(g) >= 4 and g[0] == g[-1] else []
    segs = [[(p["lat"], p["lon"]) for p in (m.get("geometry") or []) if p]
            for m in el.get("members", []) if m.get("role") in ("outer", "") and m.get("type") == "way"]
    return join_rings(segs)


def parse_num(v):
    try:
        return float(str(v).lower().replace("m", "").replace(",", ".").strip().split(";")[0])
    except ValueError:
        return None


def building_height(tags):
    for k in ("height", "building:height"):
        h = parse_num(tags.get(k, ""))
        if h and h > 0:
            return h, True
    lv = parse_num(tags.get("building:levels", ""))
    if lv and lv > 0:
        return lv * LEVEL_H, True
    return DEFAULT_LEVELS * LEVEL_H, False


def poly_area(pts):
    a = 0.0
    for i in range(len(pts)):
        x1, z1 = pts[i - 1]
        x2, z2 = pts[i]
        a += x1 * z2 - x2 * z1
    return abs(a) / 2


def split_elements(els, skip=None):
    """건물과 길을 위도/경도 그대로 골라냅니다."""
    buildings, roads = [], []
    for e in els:
        if e is skip:
            continue
        t = e.get("tags", {})
        if "building" in t:
            if t["building"] in SKIP_BUILDINGS:
                continue
            h, has = building_height(t)
            for ring in outer_rings(e):
                buildings.append({"name": t.get("name", ""), "h": round(h, 1), "levelsKnown": has, "ll": ring})
        elif "highway" in t and e["type"] == "way":
            w = ROAD_W.get(t["highway"])
            if w:
                pts = [(p["lat"], p["lon"]) for p in (e.get("geometry") or []) if p]
                if len(pts) >= 2:
                    roads.append({"w": w, "ll": pts})
    return buildings, roads


def fetch_area(otype, oid, fatal=True):
    short = "way" if otype == "way" else "rel"
    q = f"""[out:json][timeout:180];
{short}({oid})->.camp;
.camp map_to_area->.c;
.camp out geom;
(way["building"](area.c);relation["building"](area.c););
out geom;
way["highway"](area.c);
out geom;"""
    els = overpass(q, fatal).get("elements", [])
    camp = next((e for e in els if e["type"] == otype and e["id"] == oid), None)
    if not camp:
        sys.exit(f"{otype} {oid} 캠퍼스 경계를 받지 못했습니다. ID를 확인해 주세요.")
    rings = outer_rings(camp)
    if not rings:
        # 경계 선이 끊겨 있거나 multipolygon이 아닌 relation이면, 가진 좌표의 바깥 사각형을 경계로 씀
        roles = {}
        for m in camp.get("members", []):
            k = f"{m.get('type')}/{m.get('role') or '-'}"
            roles[k] = roles.get(k, 0) + 1
        print(f"  경계 선을 바로 잇지 못해서 사각형 경계로 대신합니다. (구성: {roles or '정보 없음'})")
        pts = [(p["lat"], p["lon"]) for m in camp.get("members", []) for p in (m.get("geometry") or []) if p]
        bb = camp.get("bounds")
        if not pts and bb:
            pts = [(bb["minlat"], bb["minlon"]), (bb["maxlat"], bb["maxlon"])]
        if not pts:
            sys.exit(f"{otype} {oid} 캠퍼스 위치를 알 수 없습니다. --michuhol-at 위도 경도로 지정해 보세요.")
        lats, lons = [p[0] for p in pts], [p[1] for p in pts]
        rings = [[(min(lats), min(lons)), (min(lats), max(lons)), (max(lats), max(lons)), (max(lats), min(lons)), (min(lats), min(lons))]]
        if not any("building" in e.get("tags", {}) for e in els):
            s_, w_, n_, e_ = min(lats), min(lons), max(lats), max(lons)
            print("  영역 안 건물을 못 받아서 사각형 범위로 다시 받습니다...")
            els += overpass(fatal=fatal, query=f"""[out:json][timeout:180];
(way["building"]({s_},{w_},{n_},{e_});relation["building"]({s_},{w_},{n_},{e_}););
out geom;
way["highway"]({s_},{w_},{n_},{e_});
out geom;""").get("elements", [])
    # 건물 ID를 넣었으면 그 건물도 부술 대상에 넣고, 경계는 건물 둘레에 여유를 둠
    is_bldg = "building" in camp.get("tags", {})
    b, r = split_elements(els, skip=None if is_bldg else camp)
    if is_bldg and not any(x["ll"] == max(rings, key=len) for x in b):
        b += split_elements([camp])[0]
    ring = max(rings, key=len)
    if is_bldg:
        lats, lons = [p[0] for p in ring], [p[1] for p in ring]
        m_lat, m_lon = 30 / 110540, 30 / (111320 * math.cos(math.radians(lats[0])))
        s_, n_, w_, e_ = min(lats) - m_lat, max(lats) + m_lat, min(lons) - m_lon, max(lons) + m_lon
        ring = [(s_, w_), (s_, e_), (n_, e_), (n_, w_), (s_, w_)]
    return {"boundary": ring, "buildings": b, "roads": r, "osm": {"type": otype, "id": oid}}


def fetch_around(lat, lon, radius, fatal=True):
    q = f"""[out:json][timeout:120];
(way["building"](around:{radius},{lat},{lon});relation["building"](around:{radius},{lat},{lon}););
out geom;
way["highway"](around:{radius},{lat},{lon});
out geom;"""
    b, r = split_elements(overpass(q, fatal).get("elements", []))
    if not b:
        return None
    lats = [p[0] for x in b for p in x["ll"]]
    lons = [p[1] for x in b for p in x["ll"]]
    m_lat, m_lon = 25 / 110540, 25 / (111320 * math.cos(math.radians(lat)))
    s, n, w, e = min(lats) - m_lat, max(lats) + m_lat, min(lons) - m_lon, max(lons) + m_lon
    return {"boundary": [(s, w), (s, e), (n, e), (n, w), (s, w)], "buildings": b, "roads": r,
            "osm": {"around": [round(lat, 6), round(lon, 6), radius]}}


def project(zone):
    """위도/경도를 그 구역 가운데 기준 미터 좌표로 바꿉니다. x는 동쪽, z는 남쪽."""
    bl = zone["boundary"]
    lat0 = sum(p[0] for p in bl) / len(bl)
    lon0 = sum(p[1] for p in bl) / len(bl)
    kx, kz = 111320 * math.cos(math.radians(lat0)), 110540

    def xz(p):
        return [(p[1] - lon0) * kx, -(p[0] - lat0) * kz]

    def ring(ll):
        pts = [xz(p) for p in ll]
        if pts and pts[0] == pts[-1]:
            pts = pts[:-1]
        out = []
        for p in pts:
            if not out or abs(p[0] - out[-1][0]) + abs(p[1] - out[-1][1]) > 0.3:
                out.append(p)
        return out

    zone["center"] = [round(lat0, 6), round(lon0, 6)]
    zone["boundary"] = ring(bl)
    zone["buildings"] = [dict({k: v for k, v in b.items() if k != "ll"}, pts=ring(b["ll"])) for b in zone["buildings"]]
    zone["buildings"] = [b for b in zone["buildings"] if len(b["pts"]) >= 3 and poly_area(b["pts"]) >= 15]
    zone["roads"] = [{"w": r["w"], "pts": [xz(p) for p in r["ll"]]} for r in zone["roads"]]


def shift(zone, dx, dz):
    mv = lambda pts: [[round(x + dx, 1), round(z + dz, 1)] for x, z in pts]  # noqa: E731
    zone["boundary"] = mv(zone["boundary"])
    for b in zone["buildings"]:
        b["pts"] = mv(b["pts"])
    for r in zone["roads"]:
        r["pts"] = mv(r["pts"])


def bounds(pts):
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), max(xs), min(zs), max(zs)


def parse_args(argv):
    opt = {"songdo": None, "michuhol": None, "michuhol_at": None, "no_michuhol": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--songdo":
            opt["songdo"] = (argv[i + 1], int(argv[i + 2])); i += 3
        elif a == "--michuhol":
            opt["michuhol"] = (argv[i + 1], int(argv[i + 2])); i += 3
        elif a == "--michuhol-at":
            opt["michuhol_at"] = (float(argv[i + 1]), float(argv[i + 2])); i += 3
        elif a == "--no-michuhol":
            opt["no_michuhol"] = True; i += 1
        elif a in ("way", "relation") and i + 1 < len(argv):  # 예전 사용법: fetch_campus.py way 123
            opt["songdo"] = (a, int(argv[i + 1])); i += 2
        else:
            sys.exit(f"모르는 옵션: {a}\n{__doc__}")
    return opt


def main():
    opt = parse_args(sys.argv[1:])

    otype, oid = opt["songdo"] or find_songdo()
    print("송도캠퍼스 건물과 길을 받는 중입니다 (1~2분 걸릴 수 있어요)...")
    songdo = fetch_area(otype, oid)
    project(songdo)
    for b in songdo["buildings"]:
        b["zone"] = "songdo"
    zones = [{"id": "songdo", "name": "송도캠퍼스", "boundary": songdo["boundary"]}]
    for p in songdo["boundary"]:
        p[0], p[1] = round(p[0], 1), round(p[1], 1)
    buildings = songdo["buildings"]
    roads = songdo["roads"]
    for x in buildings:
        x["pts"] = [[round(a, 1), round(b, 1)] for a, b in x["pts"]]
    for r in roads:
        r["pts"] = [[round(a, 1), round(b, 1)] for a, b in r["pts"]]

    mich = None
    if not opt["no_michuhol"]:
        time.sleep(2)
        if opt["michuhol"]:
            found = ("area",) + opt["michuhol"]
        elif opt["michuhol_at"]:
            found = ("point",) + opt["michuhol_at"]
        else:
            found = find_michuhol()
        if found is None:
            print("미추홀캠퍼스를 찾지 못해서 송도캠퍼스만 저장합니다.\n"
                  "  openstreetmap.org에서 사범대 건물을 클릭해 ID를 확인한 뒤 --michuhol way <ID>,\n"
                  "  또는 위치로 --michuhol-at <위도> <경도> 를 붙여 다시 실행하세요.")
        else:
            print("미추홀캠퍼스 건물과 길을 받는 중입니다...")
            time.sleep(2)
            try:
                mich = fetch_area(found[1], found[2], fatal=False) if found[0] == "area" else fetch_around(found[1], found[2], MICHUHOL_RADIUS, fatal=False)
            except OverpassDown:
                mich = None
                print("미추홀캠퍼스를 받는 동안 서버가 계속 붐벼서, 우선 송도캠퍼스만 저장합니다.\n"
                      "  나중에 같은 명령어를 다시 실행하면 미추홀까지 들어가요.")
            if mich is not None and not mich["buildings"]:
                print("미추홀캠퍼스 주변에서 건물을 받지 못해서 송도캠퍼스만 저장합니다.")
                mich = None

    if mich:
        project(mich)
        sx0, sx1, sz0, sz1 = bounds(songdo["boundary"])
        mx0, mx1, mz0, mz1 = bounds(mich["boundary"])
        shift(mich, sx1 + GAP - mx0, (sz0 + sz1) / 2 - (mz0 + mz1) / 2)
        for b in mich["buildings"]:
            b["zone"] = "michuhol"
        buildings += mich["buildings"]
        roads += mich["roads"]
        zones.append({"id": "michuhol", "name": "미추홀캠퍼스", "sub": "사범대학", "boundary": mich["boundary"]})
        print("미추홀캠퍼스 건물:")
        for b in mich["buildings"]:
            print(f"  {b['name'] or '(이름 없음)'}  높이 {b['h']}m")
        print("  학교 건물이 아닌 게 섞여 있으면 data/campus.json에서 그 건물을 지우면 됩니다.")

    data = {
        "name": "인천대학교",
        "osm": {"songdo": songdo["osm"], **({"michuhol": mich["osm"]} if mich else {})},
        "center": songdo["center"],
        "boundary": songdo["boundary"],
        "zones": zones,
        "buildings": buildings,
        "roads": roads,
        "attribution": "© OpenStreetMap contributors (ODbL)",
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    known = sum(1 for b in buildings if b["levelsKnown"])
    print(f"\n저장했습니다: {OUT}")
    print(f"  건물 {len(buildings)}동 (층수 정보 있음 {known}동, 나머지는 {DEFAULT_LEVELS}층으로 어림)")
    print(f"  구역: {', '.join(z['name'] for z in zones)}")
    print(f"  파일 크기 {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
