# 🐄 Boma: Pastoralist Language Strategy — MVP Scaffold

A collaborative, crowdsourced language-learning game where **vocabulary manifests as
livestock** inside a traditional pastoralist homestead (*Boma*).

- **Contribute** words/phrases + native audio → the **Council of Elders** (peer consensus)
  verifies them → validated phrases **hatch into calves/goats** in your herd.
- **Maintain** the herd with daily **Grazing Runs** (Modified SM-2 spaced repetition).
  Healthy cattle produce passive **Milk/Energy**; lapsed words make cattle sick.
- **Raid** rival Bomas asynchronously by solving their slotted **Defense Phrases**
  (timed sentence-reassembly decryption) before the watchtower timer expires to
  capture 10% of their herd.

## Repository Layout

```
/workspace
├── pubspec.yaml                  # Flutter client deps (Riverpod, supabase_flutter, Flame-ready)
├── analysis_options.yaml
├── supabase/
│   ├── config.toml               # Local dev project config
│   ├── migrations/
│   │   └── 20260927000000_init.sql   # ✦ Full DDL: tables, enums, indexes, RLS, RPCs
│   └── functions/
│       ├── _shared/cors.ts           # CORS helpers for all Edge Functions
│       ├── review_submission/index.ts # ✦ Consensus engine (verify + calf mint + rewards)
│       └── raid_manager/index.ts      # ✦ Raid begin/resolve orchestrator (anti-cheat grading)
├── lib/                          # Flutter client (clean architecture)
│   ├── main.dart                 # Root shell: Boma · Council · Raid tabs
│   ├── domain/                   # Business logic (framework-light)
│   │   ├── srs/sm2_engine.dart   # ✦ Pure Modified SM-2 scheduler (+ livestock lifecycle rules)
│   │   ├── srs/herd_controller.dart # Riverpod: grazing runs, milk economy, realtime herd
│   │   └── raids/raid_controller.dart # Riverpod raid state machine + watchtower timer
│   ├── data/
│   │   ├── models/               # HerdAnimal, VocabularyCard row models
│   │   └── repositories/         # Supabase data access (queue, submissions, audio upload)
│   └── presentation/
│       ├── boma/boma_screen.dart        # ✦ Isometric homestead (CustomPaint MVP → Flame later)
│       ├── boma/grazing_drill_sheet.dart# Daily SM-2 flashcard drill (Again/Hard/Good/Easy)
│       ├── council/council_screen.dart  # ✦ Card-swipe elder review queue w/ audio playback
│       └── raid/raid_screen.dart        # ✦ Scouting board + timed token-reassembly minigame
├── assets/sprites/               # Future Flame atlas home
├── supabase/migrations/20260927000001_inventory.sql  # Shield-token inventory + consume_shield()
└── test/sm2_engine_test.dart     # Unit tests for the SRS math
```

## Security Model (server-authoritative)

| Action | Path | Why |
|---|---|---|
| Contribute phrase | direct INSERT (RLS: own rows, `status='pending'` only) | cheap, safe |
| Elder verdict | Edge fn `review_submission` (service role) | consensus transition must bypass RLS atomically |
| Grazing grade | RPC `apply_srs_review` (SECURITY DEFINER) | server recomputes SM-2; clients can't forge intervals |
| Milk claim | RPC `claim_milk` | currency minting locked to healthy animals |
| Defense slots | direct CRUD (RLS: own boma, **verified phrases only**) | trap cards are player agency |
| Raid begin/settle | Edge fn `raid_manager` → RPCs `begin_raid`/`resolve_raid` | escrow, shield checks, 10% transfer & 12h immunity under row locks |

Consensus rule implemented in `review_submission`: **≥3 approvals AND ≥75% approval
ratio** ⇒ phrase `verified`, calf minted with SM-2 defaults (`interval_days=1`,
`ease_factor=2.5`, `next_review_at=NOW()+1d`), reviewer earns reputation + shield item.

## Getting Started

```bash
# 1. Backend
supabase start && supabase db push          # applies migrations/*.sql (DDL + RLS + RPCs)
supabase functions deploy review_submission
supabase functions deploy raid_manager

# 2. Client
flutter pub get
flutter test                                 # SM-2 engine unit tests
flutter run -d chrome                        # web MVP target
```

Optional nightly decay cron (healthy→hungry→sick for overdue animals):
```sql
select cron.schedule('graze-decay', '17 3 * * *', $$select public.graze_decay_tick()$$);
```

## UI Screens (scaffolded)

1. **Boma View** — savanna gradient, thorn-fence ring (posts scale with `fence_level`),
   central kraal, animal sprites on a deterministic iso-squashed ring; red **“!”**
   badges over animals with `next_review_at <= NOW()`; tapping starts the Grazing Drill.
2. **Council of Elders** — Tinder-style `Dismissible` card stack: category/language
   chips, live vote tally, “Hear the herder’s voice” audio button, swipe right = approve,
   left = reject (each swipe calls the consensus Edge Function).
3. **Raid Minigame** — scouting leaderboard (shielded clans greyed out), then the
   decryption gauntlet: fence-post countdown bar tied to remaining time, translation
   hint + audio per gate, tap scrambled syntax tokens into grammatical order,
   “SOLVE GATE” → “BREACH THE KRAAL”; victory/repelled outcome screen settles spoils.
