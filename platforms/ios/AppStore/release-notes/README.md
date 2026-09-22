Add `<version>.json` before pushing its release tag, for example `0.1.1.json`:

```json
{
  "en-US": "Describe the actual changes in this release.",
  "zh-Hans": "描述本次实际更新。",
  "zh-Hant": "描述本次實際更新。"
}
```

Each locale must contain nonempty text, at most 4000 characters. Do not tag a
placeholder change log. The pipeline changes update notes only; it preserves
existing screenshots, privacy disclosures, price, territories and review contact.
