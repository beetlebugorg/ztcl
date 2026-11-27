#!/usr/bin/env python3
"""Writes the texts of bench/text/run.sh to OUT_DIR, from a fixed seed."""
import os
import random
import sys

out = sys.argv[1]
r = random.Random(511)
words = {
    "english": ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "printer", "nozzle", "it's", "3.14", "e.g.", "layer"],
    "french": ["l'été", "à", "côté", "naïve", "façade", "école", "très", "où", "Noël", "déjà"],
    "chinese": ["打印", "机", "的", "喷嘴", "温度", "层", "我们", "。", "，"],
    "hindi": ["नमस्ते", "क्ष", "हिन्दी", "प्रिंटर", "।"],
    "emoji": ["\U0001F44D\U0001F3FD", "\U0001F468‍\U0001F469‍\U0001F467", "\U0001F1FA\U0001F1F8", "❤️", "ok", "\U0001F600"],
}
for name, ws in words.items():
    parts = []
    size = 0
    while size < 1_000_000:
        n = r.randint(5, 14)
        sent = " ".join(r.choice(ws) for _ in range(n))
        sent = sent[:1].upper() + sent[1:] + (". " if name != "chinese" else "。")
        if r.random() < 0.1:
            sent += "\n"
        parts.append(sent)
        size += len(sent.encode("utf-8"))
    with open(os.path.join(out, name + ".txt"), "w", encoding="utf-8") as f:
        f.write("".join(parts))
