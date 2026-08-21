# Exam paper ingestion

Turns a past-year question paper PDF into a playable mock test.

```bash
cp "JEE Main 2025 (22 Jan Shift 1) ... .pdf" tools/ingest/data/inbox/
python tools/ingest/ingest.py run --all
python tools/ingest/import_paper.py --all --publish
```

That is the whole workflow. Drop PDFs in `data/inbox`, run those two commands,
and the papers appear in the app under **Mock Tests**.

## What it does

| Stage | What happens | Model? |
|---|---|---|
| **Layout** | Finds every question's boundaries, the printable content band and the answer-key page from the PDF's own text geometry | no |
| **Answer key** | Parses the printed key. This is ground truth and nothing downstream may overrule it | no |
| **Profile** | Applies the exam's section structure and marking scheme (see `ingestlib/profiles.py`) | no |
| **Figures** | Extracts every diagram, content-addressed, with a dark variant baked for each | no |
| **Crops** | Renders each question to one image, stitching page breaks | no |
| **Extract** | Reads the crop and writes structured content blocks with LaTeX | **yes** |
| **Solve** | Solves each question *blind*, then compares against the key | **yes** |
| **Gates** | Blocks anything unanswerable; flags anything doubtful | no |
| **Emit** | Writes `data/out/<paper-key>/paper.json` plus its assets | no |
| **Normalise** | At *import*: canonicalises every maths delimiter (see below) | no |

Everything a PDF can answer deterministically is answered deterministically. A
model that never sees a question boundary can never get one wrong.

## Why a vision model reads the maths

The text layer is not usable for mathematics. Sources typeset formulae as
positioned glyph runs, so a fraction is two glyph rows and a drawn rule. The
text layer of the reference paper yields:

```
y2 dx + (x −1 y )dy = 0
```

for what is actually:

```latex
y^2\,dx + \left(x - \frac{1}{y}\right)dy = 0
```

Reconstructing that from glyph positions is a maths-OCR problem, and any
heuristic tuned to one publisher's renderer breaks on the next one. Reading the
rendered image is the only approach that survives an unfamiliar PDF — which is
the whole point of "drop any new PDF in the folder".

## Maths canonicalisation

Extraction records what the model wrote. Import canonicalises it, which is the
one choke point every question passes through — so there is a single
implementation rather than one in the pipeline, one in the importer and a third
in the client.

Three things get fixed, all of them seen on the first real paper:

| Problem | Example | Becomes |
|---|---|---|
| The other inline delimiters | `\( \text{CH}_3 \)` | `$\text{CH}_3$` |
| No delimiters at all | `\frac{2}{3}` | `$\frac{2}{3}$` |
| Display maths mid-sentence | `\[ x^2 \]`, `$$x^2$$` | `$x^2$` |

Each of those rendered as visible LaTeX source on a device. A fragment that is
maths end to end gets one span around the whole thing rather than a guess at
where the maths "starts" — guessing wrong puts the delimiters mid-formula,
which reads worse than the undelimited source it replaced.

Anything that cannot be transformed safely (unbalanced braces, an odd number of
`$`) is left exactly as it was and reported, because a question that renders
slightly wrong is recoverable and one that has been silently rewritten is not.

To re-canonicalise rows written before this existed:

```bash
python tools/ingest/normalize_latex.py --dry-run   # report
python tools/ingest/normalize_latex.py             # apply
```

Idempotent — running it twice changes nothing the second time.

## The answer-key cross-check

The solve stage never sees the official answer. It works the question out on its
own, and only then is its answer compared against the key. Every disagreement is
flagged for a human.

That single check is the highest-signal error detector in the pipeline, and it
is also a blunt measurement of how much the solutions can be trusted. On the
reference paper (JEE Main 2025, 22 Jan Shift 1) with `gpt-4o`:

```
75/75 questions extracted, 25 figures, 0 blocked
solutions: 33 verified, 35 need review, 7 withheld
```

**The questions and answers are fully reliable** — they come from the paper and
its printed key, not from a model. **The worked solutions are not**, and the
pipeline says so rather than pretending otherwise:

| Status | Meaning | Shown to students |
|---|---|---|
| `verified` | The blind solve reached the official answer on its own | yes |
| `needs_review` | The blind solve was wrong; the working was written afterwards, knowing the answer | **no** |
| `withheld` | The model could not reach the official answer and said so | **no** |

`needs_review` exists because of a failure observed on this very paper. Q74's
repaired solution states "moles of CO₂ are 0.004", then computes
`0.004 × 0.0821 × 273` and calls the result 45. It is 89.7. The right answer is
45, reached via 0.002 mol — so the solution has the correct conclusion and
invalid working. A plausible wrong method is worse than no method, so those are
held back until a person signs them off.

Use a stronger reasoning model for `INGEST_TEXT_MODEL` and the verified count
goes up. Nothing else about the pipeline changes.

## Commands

```bash
python tools/ingest/ingest.py run <file.pdf>    # one paper
python tools/ingest/ingest.py run --all         # every new PDF in data/inbox
python tools/ingest/ingest.py run --all --force # re-ingest even if unchanged
python tools/ingest/ingest.py watch             # keep watching data/inbox
python tools/ingest/ingest.py list              # what has been ingested
python tools/ingest/ingest.py review <key>      # what a human still needs to see
```

```bash
python tools/ingest/import_paper.py --all --dry-run   # report, write nothing
python tools/ingest/import_paper.py --all             # import as in_review
python tools/ingest/import_paper.py --all --publish   # import and go live
```

Without `--publish`, papers land as `in_review` and their questions as
`pending`, which the gameplay dealer already filters out. Nothing reaches
players until you say so.

Useful flags while iterating: `--limit 6` ingests only the first six questions,
and `--no-solutions` skips the solve stage entirely (much cheaper).

## Cost and time

Every model response is cached against a hash of the model, the prompt and the
image bytes, so a re-run after a prompt or gate change costs nothing for the
parts that did not change.

A 75-question paper is roughly 190 calls and about 15 minutes on a 30,000 TPM
tier. Raise `INGEST_TPM` to match your real limit and it goes proportionally
faster — the client-side limiter exists because retrying into a rate limit is
how a run silently loses a third of its questions.

## Configuration

Read from the repo `.env` (the same file the backend uses) or the environment:

| Variable | Default | Notes |
|---|---|---|
| `LLM_API_KEY` | — | Required. Already in the repo `.env`. |
| `INGEST_VISION_MODEL` | `gpt-4o` | Reads the crops and writes the LaTeX. Do not drop to a mini model — stacked fractions come back flattened. |
| `INGEST_TEXT_MODEL` | `gpt-4o` | Solving and worked solutions. A stronger model here directly raises the verified-solution count. |
| `INGEST_TPM` | `30000` | Client-side tokens-per-minute ceiling. Match your org's real tier. |
| `INGEST_CONCURRENCY` | `4` | Questions in flight. |
| `INGEST_ASSET_STORE` | `local` | `local` or `r2`. |
| `INGEST_ASSET_DIR` | `backend/static/figures` | Where `local` writes. |
| `INGEST_ASSET_BASE_URL` | `/static/figures` | URL prefix the app fetches from. |

For production figures, set `INGEST_ASSET_STORE=r2` plus `R2_BUCKET`,
`R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` and
`R2_PUBLIC_BASE_URL`. R2 rather than S3 because egress is the entire cost model
once figures are being pulled at scale, and R2 charges nothing for it. Keys are
content hashes, so every object is immutable and cacheable for a year.

## Adding an exam

Two edits, no pipeline changes:

1. **`ingestlib/naming.py`** — a filename pattern, so the exam, year and shift
   can be read off the file. Anything unparseable can be overridden with a
   `<same-name>.meta.json` sidecar.
2. **`ingestlib/profiles.py`** — the section layout and marking scheme.

JEE Main, NEET and GATE ship as profiles already. An exam with no profile falls
back to a single section with no negative marking, which is deliberately
conservative: inventing a penalty the real exam does not have would make every
score wrong.

## Human review

`ingest.py review <paper-key>` lists everything flagged, worst first.

The gate that matters most is `figure_missing`: a question whose text says "as
shown in the figure" with no figure attached is unanswerable. It is a **block**,
not a flag, so such a question never reaches a student. This is exactly the
failure that was sitting in the hand-written JSON this pipeline replaces — 14 of
75 questions there declared `diagram_required` and carried no image.

| Code | Severity | Meaning |
|---|---|---|
| `figure_missing` | block | Text refers to a figure; none attached |
| `no_answer_key` | block | No key entry for this number |
| `key_out_of_range` | block | Key names an option that does not exist |
| `duplicate_options` / `empty_option` | block | Malformed options |
| `unbalanced_math_delimiters` | block | Unpaired `$`, would render as garbage |
| `key_disagreement` | flag | Blind solve disagreed with the key |
| `solution_unreconciled` | flag | Model could not derive the official answer |
| `figure_partially_placed` | flag | Some extracted figures went unused |
| `transcription_note` | flag | The extractor flagged something itself |

## Layout

```
tools/ingest/
  ingest.py              # the pipeline CLI
  import_paper.py        # loads paper.json into the database
  ingestlib/
    segment.py           # question boundaries, content band, key page
    answerkey.py         # the printed key
    profiles.py          # per-exam sections and marking
    figures.py           # diagram extraction + dark variants
    render.py            # question crops
    vision.py            # crop -> structured content
    solutions.py         # blind solve, cross-check, worked solution
    gates.py             # what blocks and what flags
    paper.py             # the canonical document
    storage.py           # local / R2 asset stores
    llm.py, cache.py, ratelimit.py
  data/
    inbox/               # drop PDFs here
    work/<key>/          # crops and the response cache
    out/<key>/           # paper.json + assets/
```
