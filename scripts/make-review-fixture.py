#!/usr/bin/env python3
"""Create disposable, synthetic UI review data; never use the production data directory."""
import hashlib
import json
from pathlib import Path
from datetime import datetime, timezone
from uuid import uuid4

root = Path(__file__).resolve().parents[1]
destination = root / "build" / "review-fixture"
items = destination / "items"
items.mkdir(parents=True, exist_ok=True)
records = []
reference_date = datetime(2001, 1, 1, tzinfo=timezone.utc)
texts = [
    "会议备忘\n先确认交互流程，再完善视觉细节。",
    "常用回复\n收到，我稍后整理后回复你。",
    "快捷操作\n双击 F1 打开或隐藏剪贴板，按 Esc 关闭面板。",
]
for position, text in enumerate(texts):
    identifier = str(uuid4()).upper()
    data = text.encode()
    name = f"{identifier}.txt"
    (items / name).write_bytes(data)
    records.append(dict(id=identifier, createdAt=(datetime.now(timezone.utc)-reference_date).total_seconds()-position,
                        kind="text", preview=text[:240], filename=name, byteCount=len(data),
                        fingerprint=hashlib.sha256(b"text"+data).hexdigest()))
(destination / "index.json").write_text(json.dumps(dict(version=1, records=records), ensure_ascii=False))
print(destination)
