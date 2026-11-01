# Custom skins

Lunlet includes Vine and Red lanterns. Choose one in Settings → Appearance. Every official skin supports the same continuous color spectrum and native full-RGB picker beside the skin selector. A compact Restore button restores its original color treatment; imported skins keep their file-defined colors.

Both use the actual display geometry and the same account-level weekly remaining allowance; neither grants session input authority.

A lantern represents 20 percentage points. At 70% remaining, three lanterns are fully lit, one is half lit, and one is extinguished. An unavailable allowance is outlined rather than displayed as a confirmed zero. The expanded panel retains its own weekly allowance bar.

Use Export template to save an editable JSON file, change its ID/name and appearance, then Import it. Import does not rebuild Lunlet or upload the file to a service. The application owns layout, click targets, quota mapping, and lifecycle; skins contain no scripts, credentials, URLs, external resources, or executable plugins.

```json
{
  "schemaVersion": 1,
  "id": "aurora",
  "title": "Aurora",
  "kind": "vine",
  "accentHex": "#88AAEE",
  "strokeWidth": 3,
  "foliage": false
}
```

The required fields are schemaVersion, id, title, and kind. IDs contain lowercase ASCII letters, digits, underscores, or hyphens, start with a letter/digit, and contain at most 64 characters. The IDs vine and lantern are reserved. kind is vine or lantern. A title contains 1–48 characters without control characters. Files are limited to 64 KiB; up to 64 custom skins are loaded.

Optional fields:

| Field | Meaning |
|---|---|
| accentHex | RGB color in #RRGGBB form. Imported skins own this color and do not expose the built-in palette. All official catalog skins accept the Settings color preference, including future official additions. Imported lantern scenes use their package accent, red by default. Low-allowance warnings remain application-controlled. |
| strokeWidth | Vine width from 0.75 to 5 points; default 2.6. |
| foliage | Show vine foliage; default true. |
| leftWord / rightWord | Replacement letter strokes in a 40 × 26 point local coordinate space. Omit to retain the readable built-in lun / let. |
| bodyPath | Optional vine path in the reference coordinate space described below. A custom path does not use the built-in morph animation. |

Paths accept explicit uppercase M x y, L x y, C x1 y1 x2 y2 x y, and Z commands, separated by whitespace or commas. They must begin with M, include a line or curve, and have finite nonnegative coordinates within their drawing bounds. Implicit commands, exponents, unsupported commands, and extra syntax are rejected. A path is limited to 16 KiB and 256 commands.

The reference vine body spans x = 0…273 and y = 0…44. Its central x = 44…229 span scales to the actual notch width; outer letter clearance remains in points. The reference notch height is 32 points. Prefer exporting a template and retaining the built-in route unless creating custom vectors. Check different notch sizes and Reduce Motion before sharing a skin.

Invalid imports preserve the current skin. Invalid saved files are skipped, missing selections fall back to Vine, and Settings remains accessible. Custom skins are stored in the application's local support directory. Only non-secret preferences are included in settings export; authorization remains separate.

A custom `bodyPath` must be one continuous subpath with a single `M`. This keeps the 20/40/60/80% markers on the actual allowance stroke. Letter paths may contain multiple subpaths.
