# Zelio Soft 2 `.zm2` ladder format — what is known

Worked out 2026-11-14 for interoperability (opening Zelio ladder programs in BuildWire), by saving small programs in
Zelio Soft 2 V5.4.0 and comparing the files. No Zelio code was decompiled or copied. Samples (made on an SR3B261FU):
`Documents/YTTA/zelio/contoh/*.zm2` (01 empty, 02 I1→Q1, 04 I2→Q3, 05 NC i2→Q3, 06 series, 07 parallel/self-hold,
08 set/reset, 09/10 timer A 5 s/7 s, 10b timer C 7 s, 11 counter preset 3, 12 memory, 13 row comment, 14 toggle coil).
Probe script: `tools/zm2_probe.py`.

## File
- Starts with `SCHNEIDER_Z2`, then the module reference as text (e.g. `SR3B261FU`).
- An object stream in the MFC style: objects carry ids (`xx 00 00 20 <id:u32>`) that Zelio renumbers on every save, so
  compare samples saved in the same session.

## Ladder grid (the program)
A run of named parameters, each record `len:u32, name (len bytes, no NUL counted), NUL, value:u32`:
`P1`, `P2`, `P3` … `P1550`.
- `P1` = 240 (rows), `P2` = 0x0E.
- `P3 + (row-1)*6 + col` for row 1..240, col 0..4 = contact columns 1..5, col 5 = coil. Value 0 = empty cell.
- After the 240 rows (P1443 on) comes the element-type table below.

Cell value (16 bit):
- `& 0x03FF` element code (see table), `0x0001` = plain horizontal link.
- `0x0400` contact is normally closed.
- `0x4000` vertical link down from this cell's right edge to the row below.
- `0x8000` set on the cell that receives a vertical link from above (seen on row 2 col 1 in the parallel sample).

## Element codes
The file carries its own table (P1443…): per type `upper letter, lower letter, count, ?, first code, coil kinds…`.
On an SR3B261FU:

| Type | First code | Codes per item | Item codes |
|---|---|---|---|
| I inputs (I1…IG, IH…IR on extensions) | 0x02 | 1 | contact |
| Z keys (Z1…Z4) | 0x1A | 1 | contact |
| M aux relays (M1…MV) | 0x1E | 5 | contact, coil `[`, toggle, S, R |
| N aux relays (N1…NV) | 0xAA | 5 | same |
| Q outputs (Q1…QA, more on extensions) | 0x136 | 5 | contact, coil `[`, toggle, S, R |
| T timers (T1…TV) | 0x186 | 3 | contact, TT trigger, RT reset |
| C counters (C1…CV) | 0x1DA | 4 | contact, CC count, DC direction, RC reset |
| V comparators … | 0x24A | | (not sampled yet) |

Index letters run 1-9 then A, B, C … (no I, O… check against the lists: M list goes … MH, MJ, MK …, skipping I and O).

## Function block parameters
Every file (even an empty one) has 28 timer blocks and 28 counter blocks, in item order (block k = T(k+1), C(k+1)).
Record names (match them with their length prefix; PRESELECTION alone also matches P2_SENS_PRESELECTION):
- Timer: `P2_MODE` (1 A, 3 C confirmed; assumed 2 a, 4 B, 5 W, 6 D, 7 PD, 8 T, 9 AC, 10 L, 11 I),
  `O2R_VALEUR CONSIGNE_T` (time 1, tenths of a second), `O4R_VALEUR CONSIGNE_T` (time 2), `O6R_UNITE_CONSIGNE` (2 = s).
- Counter: `O2R_VALEUR DE PRESELECTION` (preset), `P2_SENS_PRESELECTION` (0 = output at the preset).

Writing (lib/sim/zm2.dart writeZm2): copy an empty file saved by Zelio Soft for the module (assets/zelio/<id>.zm2),
patch the grid values and these block values. Verified 2026-11-15: Zelio Soft opens such a file and runs it in its
simulator (I1·I2·I3 → Q1 lit Q1).

### Older notes
Elsewhere in the file, as named records of the same `len, name, NUL, value` shape:
- Timer: `P2_MODE` (1 = A, 3 = C; other functions to sample), `CONSIGNE_T` (preset in 0.1 s: 50 = 5.0 s),
  `O6R_UNITE_CONSIGNE` (unit, 2 = s), `P1_RECUP_COUPURE_SECT` (retentive), `P3_LOCKIHM` (locking).
- Outputs: `P2_N0_SORTIE_PHYSIQUE` (physical output number).

## Row comments
Right after a `0xF0` (240) count: 240 entries starting with a NUL-terminated string per row (`tes\0` in sample 13).
Exact entry layout still to confirm.

## Still to do
- Counter preset storage (sample 11, preset 3), timer functions other than A/C, clock/analog/text blocks.
- Writing: patching the P table of a real file keeps its size; whether Zelio accepts a file whose other objects
  (usage objects, blocks) don't match the grid must be tested in Zelio Soft.
