# Policy claims: reclassifying abstracts with newer LLMs

R code for the reply to Cartus, Handy & Swanson's letter on Bann et al. (2026),
*Science or advocacy?* (AJE, doi:10.1093/aje/kwag196). The paper used DeepSeek
V3.1 to classify whether 45,807 epidemiology and public health abstracts make a
policy claim. This code:

1. rebuilds the paper's corpus from Scopus, with the paper's exclusions;
2. classifies every abstract with three models and two prompts:
   - **DeepSeek V3.1**, the paper's model, to replicate it;
   - **DeepSeek V4.1 Flash**, a newer model from the same family, which also
     returns token probabilities, giving P(claim);
   - **Jev 1.14**, a decision model on OpenRouter's Decisions API, which returns
     P(claim) directly;
   - with the **original** prompt (the paper's, unchanged) and a **new**, more
     detailed prompt written from the response authors' arguments;
3. plots claim rates over time, and Jev's P(claim) for the Epidemiology
   abstracts the response authors coded.

## Folder structure

```
code/
  01_make_scopus_corpus.R   Downloads the 10 journals (1990-2024) and applies the paper's exclusions
  02_classify_abstracts.R   Sends every abstract to each model and prompt, then parses the replies
  03_analysis.R             Figures
prompts/
  original_chat.txt         The paper's prompt, unchanged
  new_chat.txt              The new prompt
  *_decision.txt            The same prompts adapted for the Decisions API (see below)
output/step_03/             Figures
data/                       Not shared (see below)
```

Each script is self-contained: it sources no other script, and reads the files
earlier scripts saved in `data/` (plus, for `03_analysis.R`, the coding file
described under "Data not included"). Each is split into numbered
sections. The sections that download or classify save their results before the
next section starts, so later sections can be rerun on their own.

## Running it

Open `Policy Claims Response.Rproj` in RStudio; all paths are relative to this
folder. Put your keys in `.Renviron` (`SCOPUS_API_KEY`, `OPENROUTER_API_KEY`) and
restart R. Packages: tidyverse, httr2, glue, fs, tictoc, readxl, patchwork,
stringi, jsonlite, systemfonts and ragg.

The figures use Open Sans, which `03_analysis.R` downloads from Google Fonts on
its first run. To preview them in RStudio, set Tools > Global Options > General >
Graphics > Backend to AGG; the default backend can't use downloaded fonts.

| Script | What it does | Cost | Time |
|---|---|---|---|
| `01_make_scopus_corpus.R` | About 2,200 Scopus requests in parallel, at Scopus's limit of 9 a second. Abstracts need an institutional network (UCL VPN, with all traffic through it). Saves `data/step_01/scopus_corpus.Rds`: 46,279 abstracts | free | 5 min |
| `02_classify_abstracts.R` | 6 specifications × 46,279 abstracts through OpenRouter, 30 requests at a time. Saves `data/step_02/classifications.Rds` | about $38 | 30-60 min per specification |
| `03_analysis.R` | Saves the figures in `output/step_03/` | free | 1 min |

`02_classify_abstracts.R` saves the replies in batches of 1,000 and skips
abstracts that already have a successful reply, so a stopped run resumes where it
left off. It stops if every request in a batch fails (for example, when the
OpenRouter credit runs out). Specifications can run at the same time from
separate terminals, by passing their numbers:

```
Rscript code/02_classify_abstracts.R 3 4
```

Set `n_abstracts` at the top of the script to try every specification on a few
abstracts first.

## How the models are called

- **Chat models (DeepSeek)** get the paper's system message, temperature (0.1),
  `max_tokens` (60) and JSON mode, with reasoning switched off. They run on hosts
  serving the original FP8 weights, cheapest first; this OpenRouter account's
  privacy settings exclude DeepSeek's own API. V4.1 Flash is limited to hosts that
  return token probabilities for the whole answer, and P(claim) is the
  probability of `true` against `false` at the answer token.
- **Jev 1.14** gets each prompt as one yes/no question on the Decisions API, with
  the abstract sent separately. Two edits make the prompt fit the API: the JSON
  output-format section is removed (its two answers become the question's
  criteria), and `ABSTRACT: {abstract}` / `OUTPUT:` becomes
  ``ABSTRACT: `abstract` ``. A claim is P(claim) >= 0.5.

## The new prompt

`prompts/new_chat.txt` keeps the paper's structure and examples but narrows what
counts as a policy claim, following the response's arguments:

- a claim calls on those who make or fund policy to act;
- methodological recommendations are not claims;
- nor are improvements to research, data collection or measurement that follow
  from the study's own work;
- nor is advice on routine practice that asks for no change in policy,
  programmes or resources.

It adds three invented examples: a multiple-comparisons recommendation (not a
claim), a questionnaire validation study (not a claim), and minimum unit pricing
(a claim). It was written without looking at the response authors' coding.

## Results of the November 2026 runs

Share of the 46,279 abstracts classified as making a policy claim:

| Model | Original prompt | New prompt | Cost (both prompts) |
|---|---|---|---|
| DeepSeek V3.1 | 27.6% | 13.2% | $26.62 |
| DeepSeek V4.1 Flash | 29.5% | 17.1% | $6.05 |
| Jev 1.14 | 33.9% | 25.8% | $5.29 |

Every abstract got a parseable answer in every specification. V4.1 Flash's hosts
cache the fixed part of the prompt (about 63% of input tokens were cached);
V3.1's hosts don't discount cached prompts.

Figures in `output/step_03/`:

- `trends.png`: LOESS smooth of each year's share of abstracts classified as a
  claim, by model and prompt.
- `epidemiology_probabilities.png`: Jev's P(claim) for the Epidemiology abstracts
  the response authors coded, by their coding.
- `figure_01.png`: the two combined.

## Data not included

- `data/` holds Scopus abstracts, which can't be redistributed, so it is
  gitignored; rerun `01_make_scopus_corpus.R` to rebuild it. Scopus adds records
  over time, so the rebuilt corpus (46,279) is larger than the paper's (45,807).
- `03_analysis.R` reads the response authors' coding of the Epidemiology
  abstracts from `../Notes/epidemiology_policy_claims_review.csv`, which is
  outside this folder and not included.
- `.Renviron` holds the API keys and is gitignored.
