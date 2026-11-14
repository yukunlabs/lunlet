# Pet animation research

Evidence gathered on 2026-11-06 for the desktop pet (US-39) and the proposed pet import (US-40). It records what other desktop companions use for their animation, which runtimes were considered for Lunlet, and why the built-in dog stays code-drawn while imported pets follow the sprite-pack format Codex already uses. Reproducible acceptance evidence stays in [feasibility](feasibility.md); product rules stay in [requirements](requirements.md).

## What desktop companions use

| Product | Animation source | Custom pets | Notes |
|---|---|---|---|
| Codex pets (ChatGPT app, `/pet`) | One sprite atlas per pet, WebP or PNG, 8 columns of 192 × 208 cells; 9 rows (v1) or 11 rows with 16 look directions (v2) | `~/.codex/pets/<id>/pet.json` plus the sheet; the bundled `hatch-pet` skill generates packs from a description or reference art | The format is read from the skill bundled with the installed app (`ChatGPT.app/Contents/Resources/skills/skills/.curated/hatch-pet/references/`, Apache 2.0); the official settings page documents only Settings › Pets, Show/Hide pet and `/pet` |
| vscode-pets (VS Code extension) | GIF strips per state per pet | Pull requests to the project | Pets react to editor activity, not to agents |
| RunCat (macOS menu bar) | PNG frame sequences | A runner store of user-made runners | Speed follows CPU load |
| VPet (Windows) | PNG frame folders per state | Mod packs | Large community of pet packs |
| Shimeji | PNG frame folders with behavior XML | Fan-made mascots | Desktop mascots that walk on windows |
| BitTherapy (macOS) | PNG sprite frames with a JSON species file | Species folders | Open source, Swift |

Every product above ships frames in some sprite form; none of the surveyed companions uses a skeletal or vector-animation runtime for user content. A user who already made a pet for one of them has a sprite pack, and the Codex pack is the one most likely to exist on a Lunlet user's Mac.

## Codex pet contract, as bundled with the app

- Package: `${CODEX_HOME:-$HOME/.codex}/pets/<pet-name>/pet.json` beside the sheet named by `spritesheetPath` (typically `spritesheet.webp`).
- Manifest: `id`, `displayName`, `description`, `spritesheetPath`, and `spriteVersionNumber: 2` for a v2 pack; without it the pack is v1.
- Atlas: v1 is 1536 × 1872 (8 × 9 cells), v2 is 1536 × 2288 (8 × 11 cells); cells are 192 × 208 with a transparent background; unused cells after a row's last frame are fully transparent.
- Rows and frame timing (used columns, durations in ms): 0 idle (6; 280, 110, 110, 140, 140, 320), 1 running-right (8; 120 each, last 220), 2 running-left (8; same), 3 waving (4; 140 each, last 280), 4 jumping (5; 140 each, last 280), 5 failed (8; 140 each, last 240), 6 waiting (6; 150 each, last 260), 7 running (6; 120 each, last 220), 8 review (6; 150 each, last 280); v2 rows 9 and 10 hold 16 look directions clockwise from 000 (up) in 22.5° steps, with neutral/front falling back to idle.
- Meaning: idle is the calm baseline and its first frame is the reduced-motion still; running means task work, not locomotion; waiting is the asking pose for approval or input; review is inspection of finished output; failed is a blocked or failed reaction; waving and jumping are greeting and play.

Only the format is reused. Lunlet implements its own reader; it copies no code or art from the skill, and it never writes into `~/.codex`.

## Runtimes considered for Lunlet

| Runtime | License and cost | macOS fit | Verdict |
|---|---|---|---|
| Sprite sheets (frames in one image) | None; WebP and PNG decode with ImageIO | A `Canvas` or layer draws a cell; no dependency | Chosen for imported pets: the ecosystem standard and Codex-compatible |
| Code-drawn vectors (the dog) | None | SwiftUI `Canvas`, scales to any size, reacts to data (gaze, blink, pose blend) | Kept for the built-in dog; the drawing description is platform-free |
| Rive | MIT runtime (`RiveRuntime` SwiftPM binary 6.x, macOS 13.1 and later); the editor's free plan limits exports | Rich state machines; a new binary dependency and file format users cannot author without the editor | Later, after a spike, if users ask for state-machine pets |
| Spine | Editor license per developer (Essential 69 USD, Professional 379 USD); the runtime license requires an editor license | Runtime via spine-cpp; no official Swift package | Not planned: licensing cost for every contributor and user |
| Live2D | Cubism SDK license; free for small publishers with terms | Character models, mostly faces | Not planned: wrong register for a tiny companion |
| Lottie | MIT (`lottie-ios`) | Vector animation from After Effects or Figma; no state machine | Not planned for pets; possible for UI flourishes |

## Decisions this research supports

- The built-in dog stays code-drawn: its liveliness comes from data (where the pointer and the panel are, blinks and glances from the time), which a frame format cannot carry.
- User pets arrive as sprite packs in the Codex format, read from Lunlet's own pets folder and from `~/.codex/pets`, so a pet made for Codex works in Lunlet unchanged and a Lunlet user needs no new format (US-40, proposed).
- The dog's five poses map onto the Codex rows (idle, running, waiting, review; jumping on a click; running-left and running-right while dragged; v2 look directions for the gaze), which keeps one pose rule for every pet.
- A skeletal or vector runtime is a later, separate decision taken only after a spike shows a user-facing gain that sprite packs cannot give.
