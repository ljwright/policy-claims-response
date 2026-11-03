# Policy claims: rerunning the classification with newer models

R code for the reply to Cartus, Handy & Swanson's letter on Bann et al. (2026),
*Science or advocacy?* (AJE, doi:10.1093/aje/kwag196). It:

1. rebuilds the paper's corpus from Scopus and **reproduces the published labels**
   with the paper's model (DeepSeek V3.1, same prompt and settings) on a pilot sample;
2. reclassifies every abstract with a **newer DeepSeek** (V4.1 Flash), prompt unchanged;
3. ports the prompt to a **decision model** (Perplexity Decider V1.2), which returns
   P(policy claim) instead of yes/no, and uses it three ways: a weighted claim
   rate, results with uncertain abstracts filtered out, and how far yes/no labels
   track certainty, including for the 115 Epidemiology abstracts the editors coded;
4. tests whether a **fuller prompt** helps more than a newer model: a revised
   prompt written on half of the human-coded abstracts, then tested on the other
   half and on the editors' 115.

Every model is scored against the three human-coded sets: the paper's gold
standard (n=204), its sample stratified by period (n=400), and the editors' 115.

## Results of the 27 October 2026 runs

The full tables are in `output/summary.md`. In brief:

- **The pipeline reproduces the published labels.** The V3.1 rerun agrees with
  them on 96.7% of the 1,681 pilot abstracts (kappa 0.92), about as closely as
  the repository's two earlier runs agree with each other.
- **The paper's conclusions hold for every model and prompt.** Newer models find
  2-6 points more claims in every period (overall 28.6-31.1%, against 25.6%
  published), so the rise from the 1990s to 2020-24 is the same (17-20 points).
  Epidemiology stays lowest and Lancet Public Health highest, and the design and
  keyword patterns hold. This also holds with claims weighted by P(claim), with
  only confident claims, and with uncertain abstracts excluded, except that the
  design pattern breaks under Decider's weighted rate.
- **Newer models agree better with the blind-coded stratified sample** (held-out
  half, kappa): 0.55 published, 0.66 V4.1 Flash, 0.74 Decider V1.2. On the gold
  standard these three score 0.80-0.83.
- **The revised prompt did not improve significantly on the paper's prompt.** On
  the held-out half it is right on 272 of 305 human labels, against 269 (McNemar
  p = 0.61): better on the stratified sample (kappa 0.73 against 0.66) and worse
  on the gold standard (0.74 against 0.80). On the editors' 115 it does best of
  all runs: 72% of its claims are ones the editors confirmed, against 62%
  published and 65% for the paper's prompt (80 of 112 right, against 72;
  p = 0.12). Every run still calls at least half of the editors' 43 rejections
  claims.

## Running it

Open `policy_claims.Rproj` in RStudio. Put your keys in `.Renviron`
(`OPENROUTER_API_KEY`, `SCOPUS_API_KEY`), then restart R. Source the scripts in order:

| Script | What it does | Cost | Time |
|---|---|---|---|
| `shared_functions.R` | Saves the functions several scripts use to `data/shared_functions.rds`. Run it again after editing it | free | seconds |
| `00_check_setup.R` | Confirms the prompt file is identical to the paper's, the keys work, Scopus returns abstracts, and every model answers two test abstracts | < $0.01 | 1 min |
| `01_download_scopus.R` | Downloads the 10 journals, 1990-2024 (about 2,400 requests). Needs the UCL network/VPN or `SCOPUS_INSTTOKEN`. Up to three copies can run at once, each given some of the journals (see the script) | free | 15 min with three copies |
| `02_build_corpus.R` | Applies the paper's filters, links the published labels and the human-coded sets, and draws the pilot sample | free | 1 min |
| `05_analysis.R` | Run it now, before paying for anything: with only the published labels it checks that the rebuilt corpus reproduces Table 1 | free | 1 min |
| `03_estimate_cost.R` | Cost and time of each run from OpenRouter's live prices | free | 1 min |
| `04_run_models.R`, `stage <- "pilot"` | Every model on the pilot sample: the human-coded abstracts plus 1,000 random ones (about 1,700) | $2-3 | 10 min |
| `04_run_models.R`, `stage <- "full"` | The runs set to `sample = "full"` in `config.R` | see below | 25-35 min each |
| `06_prompt_development.R` | Scores one candidate prompt on the development half of the human-coded abstracts (see "Revised prompt") | $0.02 a version | 30 s |
| `05_analysis.R` | Final tables, figures and `output/summary.md` | free | 1 min |

`04_run_models.R` prints each run's estimate and asks before starting. Results
are saved every 500 abstracts, so you can stop a run (Esc) and rerun the script
to resume. Each run stops at its `max_cost_usd` cap (checked between batches, so
it can go over by at most one batch). It also stops if every request in a batch
fails, for example once the OpenRouter key's credit limit is reached: fix the
cause and rerun to resume. Runs can go at the same time from separate
terminals, for example `Rscript 04_run_models.R full decider_v12`.

Each numbered script reads top to bottom and sources no other script's code:
- `config.R` for its settings, which is all that file holds;
- the shared functions it needs, loaded from the copy `shared_functions.R` saves;
- its own functions, under "Functions";
- its steps.

`shared_functions.R` saves a checksum of itself with the functions, and every
script stops if the file has changed since it was last run, so an edited shared
function can't be silently skipped.

`tests/test_functions.R` holds unit tests for the parsers, the prompt port,
filters, the development split and statistics:
`testthat::test_file("tests/test_functions.R")`. It reads each function from the
file it is written in, without running that file's steps.

## Cost and time

What the runs cost on 27 October 2026 (the OpenRouter key's own total: $6.96):

| Run | Abstracts | Cost | Time |
|---|---|---|---|
| DeepSeek V3.1 rerun (pilot sample) | 1,696 | $0.40 | 5 min |
| DeepSeek V4.1 Flash | 46,279 | $2.74 | 33 min |
| DeepSeek V4.1 Flash, revised prompt | 46,279 | $2.93 | 32 min |
| Perplexity Decider V1.2 | 46,279 | $0.85 | 25 min |
| Prompt development (4 runs on the development half) | 298 each | $0.08 | 2 min |

V4.1 Flash and Decider went at 25-35 abstracts a second with 16 requests in
flight (V3.1's hosts managed 6), with three runs at a time. V4.1 Flash's hosts
cache the fixed part of the prompt, so 62-74% of its
input tokens were billed at about 4% of the normal price. No host serving V3.1 at
its original FP8 precision discounts cached prompts.

Configured but not run: V4 Pro 0813 (see "Things to know"), and TypeSafe Jev 1.14
and GPT-6 Luna Decisions (pilot only; about $2 and $5 for the full corpus).

## Model choices

All three decision models named in the brief are live on OpenRouter's Decisions
API (30 decision-model listings on 27 October 2026), so one function calls them all.

- **Newer DeepSeek: V4.1 Flash 1017** (17 October 2026), in non-thinking mode
  like the paper's `deepseek-chat`. Staying in the paper's model family means a
  change in results reflects a newer model rather than another company's, and the
  weights are open (MIT), as the paper argued they should be. It also returns
  token probabilities, so P(claim) is available for it. Gemini 3.8 Flash scores
  about the same on general benchmarks (Artificial Analysis 41 against 39; LLM
  Stats 49 against 50) but costs about five times as much for this workload, is
  closed, and returns no token probabilities.
- **Decision model: Perplexity Decider V1.2** (16 October 2026). It has open
  weights (Apache 2.0), which suits the paper's reproducibility argument, and it
  is the cheapest. Rao & Callison-Burch (arXiv:2609.29769) found Decider the
  strongest single judge on most of their panels, and provider-reported
  comparisons of earlier versions also put it ahead (Decider V1.1 79%, Jev 1.13
  73% and GPT-6 Luna 69% accuracy on a JevBench subset). Most of these benchmarks
  are vendor-reported; the human-coded sets are the real test.

## How the models are called

- **Chat models** get the paper's prompt unchanged (`prompts/policy_claim_prompt.txt`,
  checked against `code/3_run_llm_classification.py` by `00_check_setup.R`), with
  the same system message, temperature (0.1), `max_tokens` (60) and JSON mode.
  Reasoning is switched off. V3.1 is pinned to hosts running its original FP8
  weights (SiliconFlow, falling back to CoreWeave), because DeepSeek's own API no
  longer serves it. This OpenRouter account's privacy settings exclude DeepSeek's
  own API (it may train on prompts), so V4.1 Flash runs on third-party hosts
  serving FP8 weights that return token probabilities (Makora, falling back to
  StreamLake or GMICloud).
- **Decision models** get the same prompt as one yes/no ("noul") question, with
  the abstract sent as the request's `state`. Only two edits were made, both
  forced by the API (Prompts in `shared_functions.R`, and a unit test proves
  nothing else changed):
  1. The JSON output-format section is dropped, and its two answers become the
     question's true/false criteria.
  2. `ABSTRACT: {abstract}` / `OUTPUT:` becomes ``ABSTRACT: `abstract` ``.

  A claim is P(claim) >= 0.5; the uncertain band is 0.2-0.8. Both are set in
  `config.R`.
- **The revised prompt** (`prompts/policy_claim_prompt_v2.txt`) is used by the
  `deepseek_v41_flash_prompt2` run through its `prompt_file` setting. Everything
  else matches the `deepseek_v41_flash` run.

## Revised prompt

The question is whether a fuller prompt, rather than a newer model, improves the
classification. The paper's definition was kept: the paper's human coders
applied the same definition as its prompt, and it deliberately includes vague
claims. A revised prompt was written to apply that definition more precisely.

1. **Split.** The gold-standard and stratified-400 abstracts were split at
   random, within each set and human label, into a development half (298) and a
   held-out half (304; one abstract is in both sets), with a fixed seed. The split is saved in
   `prompts/development_split.csv`. Abstracts among the editors' 115 were always
   held out, so the editors' coding never informed the prompt.
2. **Development.** `06_prompt_development.R` runs a candidate prompt
   (`prompts/development/`) on the development half with V4.1 Flash and writes
   its errors for review; only development abstracts were read. Scores for every
   version are in `output/tables/13_prompt_development.csv`.
   - v00 is the paper's prompt, run twice: its kappa moved by 0.015 between runs.
   - v01 counted endorsements of interventions as claims ("a promising
     strategy"). It fixed 8 false negatives but added 10 false positives, because
     the human coders labelled such statements both ways.
   - v02 keeps the paper's rules and examples and adds exclusions for
     recommendations to researchers about methods and data, for reported effects
     of modelled interventions, and for policies that are only the subject of a
     study. It also says that findings flagged as relevant to services count, and
     adds four invented examples. It scored kappa 0.844 against 0.828-0.843, and
     became the revised prompt.
3. **Test.** The revised prompt was run once on every abstract, and
   `05_analysis.R` compares it with the paper's prompt on the held-out half and
   the editors' 115, abstract by abstract (`14_revised_vs_original_prompt.csv`,
   exact McNemar tests).

The two halves differ by chance: every run, including those no prompt was tuned
for, scores lower on the held-out half (on the stratified sample the published
labels have kappa 0.76 on the development half and 0.55 on the held-out half).
So compare runs within a half, not across halves.

## Outputs

`output/summary.md` has the headline numbers. Tables in `output/tables/`:

- `02_table1_by_run*`: Table 1 for every run. Each row gives the yes/no rate,
  the weighted rate (mean P(claim)), the confident-claims rate (P >= 0.8) and the
  rate with uncertain abstracts excluded, plus the share that is uncertain.
- `03`, `04`: the time trend (odds ratio per decade), and whether each of the
  paper's qualitative conclusions holds, for each run and each of those four
  measures.
- `07`, `08`: agreement between runs, and accuracy against each human-coded set,
  separately for the development and held-out halves.
- `10`, `11`: certainty against the published yes/no labels, and the
  Epidemiology 115. The thresholds table answers: if only claims with
  P >= t count, how many of the 115 remain, and what share do the editors confirm?
- `12` and `fig6`: claim rates by period at thresholds from 0.1 to 0.9.
- `13`, `14`: the prompt-development scores, and the revised prompt against the
  paper's prompt on the same abstracts.
- `15`, `fig8`, `fig9`: the paper's Figure 1 (each year's share of abstracts
  labelled a claim, with the paper's LOWESS smooth) for each set of labels, and
  the cut-off against the weighted average (mean P(claim)) for the runs that give
  P(claim).
- `16`, `fig10`, `fig11`: Decider's P(claim) for the Epidemiology 115 by Cartus et
  al.'s coding, and for the stratified 400 by whether the paper's two coders
  agreed. The gold standard is left out of `fig11` because its second lead coder
  coded only 94 of its 204 abstracts.

## Things to know

- **The gold-standard sheet holds labels from an earlier run.** Its
  `llm_policy_claim` column disagrees with the published labels on 13 of 203
  abstracts. The paper's validation figures (kappa 0.80, and "sensitivity 76.8%,
  specificity 98.6%", which are PPV and NPV with the gold standard as truth) come
  from that column. Scored against the gold standard, the published labels do
  better: kappa 0.86, sensitivity 88.9%, specificity 96.8%, PPV 88.9%. The
  400-abstract sheet matches the published labels exactly. This code always uses
  the published labels.
- **Which V3.1 snapshot?** The paper's script called `deepseek-chat`, an alias that
  moved to V3.1-Terminus on 22 September 2025 and V3.2-Exp on 29 September 2025.
  The rerun of `deepseek/deepseek-chat-v3.1` reproduces the published labels
  (96.7% agreement), but labels slightly more claims (44 abstracts the other way
  round against 11). The gold sheet's earlier run differs from the published
  labels in the same direction.
- **The editors' 115 can only show precision.** All 115 are abstracts the
  published run called claims, so a run can be scored on how many it keeps and
  how many of those the editors confirm. New claims elsewhere in Epidemiology
  were never coded. The revised prompt labels 3.9% of all Epidemiology abstracts
  as claims (published 3.7%), so it adds about as many new Epidemiology claims as
  it drops.
- **V4 Pro is configured but blocked.** This OpenRouter account's privacy
  settings exclude DeepSeek's own API. To run V4 Pro, allow providers that may
  train on prompts, or route it to third-party FP8 hosts as for V4.1 Flash. On
  hosts that return token probabilities and cache the prompt, that would cost
  roughly $20 for the corpus.
- **Scopus changes over time.** The rebuilt corpus has 46,279 abstracts against
  the paper's 45,807; Scopus has added records since, mostly for 2010-2019.
  Published labels are matched by DOI (the public file has no Scopus IDs), so
  45,667 abstracts have one, and runs are compared on abstracts every run labelled.
- **Probabilities are not comparable across models.** Each model has its own
  calibration: V4.1 Flash's token probabilities are below 0.2 or above 0.8 for
  over 90% of abstracts, while Decider's are more spread out. Check thresholds against the
  human-coded sets (`fig7_calibration.png`) before relying on them.
- `data/` holds Scopus abstracts, which cannot be redistributed, so it is
  gitignored. So is `.Renviron`.
