#!/usr/bin/env python3
"""Validate the shipped catalogs without launching Balbis or changing preferences."""
import collections
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("ru", "en", "uk", "zh-Hans")
STRING = r'"(?:[^"\\]|\\.)*"'
ENTRY = re.compile(rf'({STRING})\s*=\s*({STRING});')
FORMAT = re.compile(r'%(?:[1-9][0-9]*\$)?(?:[-+ #0]*)(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp]')


def catalog(language):
    path = ROOT / "Resources" / (language + ".lproj") / "Localizable.strings"
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        match = ENTRY.fullmatch(line)
        if not match:
            raise AssertionError(f"{path}:{number}: invalid syntax or escape")
        key, value = (json.loads(item) for item in match.groups())
        if key in values:
            raise AssertionError(f"{path}:{number}: duplicate key {key!r}")
        values[key] = value
    return path, values


class LocalizationTests(unittest.TestCase):
    def test_catalogs_are_complete_and_parse_with_apple_tools(self):
        reference = catalog("ru")[1]
        self.assertGreater(len(reference), 200)
        for language in LANGUAGES:
            path, values = catalog(language)
            with self.subTest(language=language):
                subprocess.run(["/usr/bin/plutil", "-lint", str(path)], check=True, capture_output=True)
                self.assertEqual(set(reference), set(values))
                for key, value in values.items():
                    self.assertTrue(value, (language, key))
                    self.assertEqual(collections.Counter(FORMAT.findall(key)), collections.Counter(FORMAT.findall(value)), (language, key))
                    self.assertEqual(key.count("\n"), value.count("\n"), (language, key))
                    if language == "ru":
                        self.assertEqual(key, value)
                    elif language in ("en", "zh-Hans"):
                        self.assertIsNone(re.search("[А-Яа-яЁё]", value), (language, key))

    def test_every_source_key_including_raw_errors_is_cataloged(self):
        known = catalog("ru")[1]
        required = set()
        for path in (ROOT / "Sources").glob("*.swift"):
            source = path.read_text()
            for pattern in (rf'L\(\s*({STRING})', rf'BalbisError\(\s*({STRING})', rf'UserFacingError\(message:\s*({STRING})'):
                for match in re.finditer(pattern, source):
                    if "\\(" not in match[1] and re.search("[А-Яа-яЁё]", match[1]):
                        required.add(json.loads(match[1]))
        # These are intentionally kept as raw identifiers/input whitelist values.
        required.update(("Все", "Нейросети", "Видео", "Соцсети", "Другие", "неизвестно",
                         "Сегментация TCP + TLS", "Только сегментация TCP", "Только разделение TLS"))
        self.assertFalse(required - set(known), f"Missing keys: {sorted(required - set(known))}")

    def test_escaping_is_lossless(self):
        # The same escaping used by the catalogs must preserve quotes, paths and newlines.
        value = 'Example "quoted" \\path\nnext line'
        encoded = json.dumps(value, ensure_ascii=False)
        match = ENTRY.fullmatch(encoded + " = " + encoded + ";")
        self.assertIsNotNone(match)
        self.assertEqual(tuple(json.loads(item) for item in match.groups()), (value, value))

    def test_build_declares_and_copies_the_languages(self):
        build = (ROOT / "build.sh").read_text()
        self.assertIn("<key>CFBundleDevelopmentRegion</key><string>ru</string>", build)
        for language in LANGUAGES:
            self.assertIn("<string>" + language + "</string>", build)
        self.assertIn("Resources/*.lproj", build)
        self.assertIn('cp -R "$localization" "$APP/Contents/Resources/"', build)


if __name__ == "__main__":
    unittest.main(verbosity=2)
